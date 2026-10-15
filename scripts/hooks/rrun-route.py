#!/usr/bin/env python3
"""
PreToolUse rewrite (Bash) - send known heavy test commands to the Mac mini via `rrun`.

Why: a DB test run with the runner on the laptop and its Postgres on the mini took 673 s and
timed out (every query crosses the ~70 ms link); the same run entirely on the mini took 12 s.
Agents will not remember to type `rrun`, so this rewrites `npm run test:db ...` into
`rrun npm run test:db ...`. The rdocker shim's safety net catches whatever this misses
(it keeps such a DB on the laptop instead of splitting it).

Behavior:
  * Patterns: `rr_route_patterns` from rdocker's config (rd_common.DEFAULTS deep-merged with
    ~/.config/rdocker/config.json) - the one list the shim's safety net also uses. rd_common is
    found next to the real file behind ~/.local/bin/rrun, and only imported after the prefilter.
  * Prefilter: a substring test (test:db / rehearse:migrations / test-with-db) so every other
    Bash call exits at once. A config that sets its own rr_route_patterns skips the prefilter.
  * No-op when: rrun is not installed (~/.local/bin/rrun missing, or no rrun on PATH); we are on
    the mini (RRUN_REMOTE set, or ~/<rr_root>/git exists); the command already mentions rrun;
    a skip marker is present: RRUN=0, real-od/, doctor-drive, --approve=browser.
  * Segment-safe: splits on unquoted && || ; | & and newlines with a quote/comment-aware
    scanner. A matching segment is rewritten only when the match is in unquoted text, its head is
    a node package runner (npm/node/npx/pnpm/yarn/bun) after plain NAME=value assignments, it is
    not a pipe target, and it has no parens / braces / input redirect. Any $( / backtick (a
    substitution can hide its own segments), heredoc or unbalanced quote, or ANY matching segment
    that is not safe, leaves the whole command alone.
  * Leading NAME=value assignments stay where they are (an env prefix, so values never enter
    rrun's argv) and each non-RRUN_/RDOCKER_ name gets `rrun -e NAME`, which forwards the value
    from rrun's own environment: `FOO=1 npm run test:db` -> `FOO=1 rrun -e FOO npm run test:db`.
    RDOCKER_MODE=local is dropped; RRUN_* / RDOCKER_* only configure the laptop side. A value
    must match [A-Za-z0-9_./:@%+,=-]* (no globs, ~, $, quotes...), else the command is left alone.
  * Words split only on space/tab: any other whitespace or invisible format char (\\v \\f \\r,
    NBSP, U+2000.., U+200B, ...) leaves the command alone. So does shell state set by an EARLIER
    segment that would not reach the mini: export, declare/typeset, set -a / allexport,
    source / `.`, or a bare assignment (`FOO=1; npm run test:db`).
  * Returns ONLY updatedInput (never a permission decision), so normal permission prompts still
    apply to the rewritten command. Every other tool_input key is preserved.
  * FAILS OPEN: any parse error or unexpected input -> exit 0 with no output (call unchanged).
"""
import json
import os
import re
import sys
import unicodedata

PREFILTER = ("test:db", "rehearse:migrations", "test-with-db")
SKIP_MARKERS = ("rrun", "RRUN=0", "real-od/", "doctor-drive", "--approve=browser")
HEADS = {"npm", "node", "npx", "pnpm", "yarn", "bun"}
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
VALUE_RE = re.compile(r"[A-Za-z0-9_./:@%+,=-]*")   # fullmatch
UNSAFE_IN_SEGMENT = re.compile(r"\$\(|`|[(){}<]")
WORD_RE = re.compile(r"[^ \t]+")                 # the only separators we accept: space, tab
STATE_WORDS = {"export", "declare", "typeset", "source"}
KEYWORDS = {"then", "do", "else", "elif", "!", "{", "("}
# Wrappers between the assignments and the node runner. heavy-slot.sh (a LAPTOP concurrency gate)
# is dropped: the job no longer runs on the laptop and the mini has its own slots. The others stay
# in front of rrun, which then runs under them: `timeout 600 npm ...` -> `timeout 600 rrun npm ...`.
DROP_WRAPPERS = {"heavy-slot.sh"}
KEEP_WRAPPERS = {"timeout": 1, "gtimeout": 1, "time": 0, "nice": 0, "caffeinate": 0}
WRAP_ARG_RE = re.compile(r"-[A-Za-z]+|[0-9]+(\.[0-9]+)?[smhd]?")      # flags / durations only
SHELLS = {"bash", "sh", "zsh"}
SIMPLE_FILE_RE = re.compile(r"[A-Za-z0-9_./~@%+,=-]+")
REDIR_RE = re.compile(r"[0-9]?(>>?|>&)([0-9]|[A-Za-z0-9_./~@%+,=-]+)")


def home():
    return os.path.abspath(os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~"))


def rrun_installed(h):
    """-> realpath of ~/.local/bin/rrun when it exists and an rrun is on PATH, else None."""
    link = os.path.join(h, ".local", "bin", "rrun")
    if not os.access(link, os.X_OK):
        return None
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.access(os.path.join(d, "rrun"), os.X_OK):
            return os.path.realpath(link)
    return None


def user_cfg(h):
    try:
        with open(os.path.join(h, ".config", "rdocker", "config.json")) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def load_cfg(rrun_real, user):
    """rdocker's merged config (DEFAULTS + user keys) via the rd_common shipped beside rrun."""
    sys.path.insert(0, os.path.dirname(rrun_real))
    import rd_common
    return rd_common.merge_cfg(user)


def scan(cmd):
    """-> (segments, masked) or None when the quoting is unbalanced or a heredoc is present.
    segments: [(start, end, op_before)]; masked: cmd with quoted/escaped text and comments
    blanked; shape: the same but quoted/escaped text kept as non-space, so words split where the
    shell splits them. Both have cmd's length, so indexes line up with the original."""
    segs, masked, shape = [], list(cmd), list(cmd)
    i, n, start, op = 0, len(cmd), 0, ""
    word_start = True
    while i < n:
        c = cmd[i]
        if c == "\\":
            for k in range(i, min(i + 2, n)):
                masked[k], shape[k] = " ", "Q"
            i += 2
            word_start = False
            continue
        if c in "'\"":
            j = i + 1
            while j < n and cmd[j] != c:
                j += 2 if (c == '"' and cmd[j] == "\\") else 1
            if j >= n:
                return None                                   # unbalanced quote
            for k in range(i, j + 1):
                masked[k], shape[k] = " ", "Q"
            i = j + 1
            word_start = False
            continue
        if c == "#" and word_start:
            j = cmd.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                masked[k], shape[k] = " ", " "
            i = j
            continue
        if c == "<" and cmd.startswith("<<", i):
            return None                                       # heredoc / herestring
        two = cmd[i:i + 2]
        if two in ("&&", "||", "|&"):
            segs.append((start, i, op))
            op, i, start, word_start = two, i + 2, i + 2, True
            continue
        if c in ";|\n" or (c == "&" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != ">"):
            segs.append((start, i, op))
            op, i, start, word_start = c, i + 1, i + 1, True
            continue
        word_start = c in " \t"
        i += 1
    segs.append((start, n, op))
    return segs, "".join(masked), "".join(shape)


def shell_c(cmd, shape, toks, k):
    """toks[k:] is `bash|sh|zsh -c '<script>'` (one single-quoted script, then only output
    redirects like `2>&1` / `> file`) -> (script_start, script_end) inside the quotes, else None."""
    if len(toks) - k < 3:
        return None
    rest = [cmd[a:b] for a, b in toks[k + 3:]]
    while rest:
        if rest[0] in (">", ">>", "2>", "2>>") and len(rest) > 1 and SIMPLE_FILE_RE.fullmatch(rest[1]):
            rest = rest[2:]
        elif REDIR_RE.fullmatch(rest[0]):
            rest = rest[1:]
        else:
            return None
    (hs, he), (fs, fe), (qs, qe) = toks[k:k + 3]
    if os.path.basename(cmd[hs:he]) not in SHELLS or cmd[fs:fe] != "-c":
        return None
    if cmd[qs] != "'" or cmd[qe - 1] != "'" or qe - qs < 2 or "'" in cmd[qs + 1:qe - 1]:
        return None
    return qs + 1, qe - 1


def rewrite_segment(cmd, shape, s, e, op, patterns=None, depth=0):
    """-> replacement text for cmd[s:e], or None when the segment is not fully understood."""
    if op in ("|", "|&"):
        return None
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    front, names, head, wraps = [], [], None, []
    k = 0
    while k < len(toks):
        ts, te = toks[k]
        word = cmd[ts:te]
        if shape[ts:te] != word:                              # quoting in env/head: not simple
            if head is None and wraps is not None:
                break                                         # maybe `bash -c '...'`: checked below
            return None
        m = ASSIGN_RE.match(word) if not wraps else None
        if m and not wraps:
            pass
        else:
            base = os.path.basename(word)
            if base in DROP_WRAPPERS:
                wraps.append((False, word))
                k += 1
                continue
            if base in KEEP_WRAPPERS:
                j = k + 1
                while j < len(toks) and WRAP_ARG_RE.fullmatch(cmd[toks[j][0]:toks[j][1]]):
                    j += 1
                if j - k - 1 < KEEP_WRAPPERS[base]:
                    return None                               # e.g. `timeout` with no duration
                wraps.append((True, cmd[ts:toks[j - 1][1]]))
                k = j
                continue
            head = (ts, word)
            break
        if not VALUE_RE.fullmatch(m.group(2)):
            return None                                       # glob, ~, $, ... : not simple
        k += 1
        if word == "RDOCKER_MODE=local":
            continue
        front.append(word)
        if not m.group(1).startswith(("RRUN_", "RDOCKER_")):
            names.append(m.group(1))
    if not toks:
        return None
    lead = cmd[s:toks[0][0]]
    env = "".join(w + " " for w in front)
    kept = "".join(w + " " for keep, w in wraps if keep)
    sc = shell_c(cmd, shape, toks, k) if depth == 0 and patterns is not None else None
    if sc:                                                    # bash -c '<script>': rewrite inside
        inner = route(cmd[sc[0]:sc[1]], patterns, depth + 1)
        if inner is None:
            return None
        allw = "".join(w + " " for _, w in wraps)            # heavy-slot still gates the laptop part
        return lead + env + allw + cmd[toks[k][0]:sc[0]] + inner + cmd[sc[1]:e]
    if head is None or os.path.basename(head[1]) not in HEADS:
        return None
    if UNSAFE_IN_SEGMENT.search(cmd[s:e]):
        return None
    flags = "".join("-e %s " % n for n in dict.fromkeys(names))
    return lead + env + kept + "rrun " + flags + cmd[head[0]:e]


def shell_c_script(cmd, shape, s, e):
    """The script text when the segment runs `bash|sh|zsh -c '<script>'`, else ""."""
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    for k in range(len(toks)):
        sc = shell_c(cmd, shape, toks, k)
        if sc:
            return cmd[sc[0]:sc[1]]
    return ""


def sets_state(masked, s, e):
    """True when segment masked[s:e] may change shell state a later `rrun` (a child process on
    another machine) would not inherit: export/declare/typeset/source, `.`, set -a/allexport,
    or a bare assignment. Quoted text is blanked in `masked`, so `echo "export"` is fine."""
    words = WORD_RE.findall(masked[s:e])
    while words and words[0] in KEYWORDS:
        words = words[1:]
    if not words:
        return False
    if words[0] == "." or STATE_WORDS.intersection(words):
        return True
    if "set" in words and any(w == "allexport" or re.match(r"^[-+][A-Za-z]*a", w) for w in words):
        return True
    return all(ASSIGN_RE.match(w) for w in words)


def route(cmd, patterns, depth=0):
    """-> rewritten command, or None to leave it unchanged."""
    if "$(" in cmd or "`" in cmd:
        return None                                           # a substitution can hide segments
    if any(c not in " \t\n" and unicodedata.category(c) in ("Zs", "Zl", "Zp", "Cc", "Cf")
           for c in cmd):
        return None                                           # odd whitespace: words unclear
    scanned = scan(cmd)
    if scanned is None:
        return None
    segs, masked, shape = scanned
    regs = [re.compile(p) for p in patterns]
    hits = [(s, e, op) for s, e, op in segs if any(r.search(masked[s:e]) for r in regs)
            or (depth == 0 and any(r.search(shell_c_script(cmd, shape, s, e)) for r in regs))]
    if not hits:
        return None
    if any(sets_state(masked, s, e) for s, e, _ in segs if s < hits[-1][0]):
        return None                                           # earlier state would not reach the mini
    out = cmd
    for s, e, op in reversed(hits):
        new = rewrite_segment(cmd, shape, s, e, op, patterns, depth)
        if new is None:
            return None                                       # unsure about one -> touch none
        out = out[:s] + new + out[e:]
    return out


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input") or {}
        cmd = tool_input.get("command")
    except Exception:
        return
    if data.get("tool_name") != "Bash" or not isinstance(cmd, str) or not cmd.strip():
        return
    if any(m in cmd for m in SKIP_MARKERS) or os.environ.get("RRUN_REMOTE"):
        return
    h = home()
    rrun_real = rrun_installed(h)
    if not rrun_real:
        return
    user = None
    if not any(t in cmd for t in PREFILTER):
        user = user_cfg(h)
        if "rr_route_patterns" not in user:
            return
    cfg = load_cfg(rrun_real, user_cfg(h) if user is None else user)
    if os.path.isdir(os.path.join(h, cfg.get("rr_root") or "rr", "git")):
        return                                                # this is the mini
    new = route(cmd, cfg.get("rr_route_patterns") or [])
    if not new or new == cmd:
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {**tool_input, "command": new},
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
