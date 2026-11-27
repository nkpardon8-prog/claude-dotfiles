#!/usr/bin/env python3
"""rules-in-force.py - every Claude window and subagent follows the CURRENT rule files.

Why it exists (2026-11-17): a project's CLAUDE.md lives in git, so each worktree carries the copy from
whatever commit it is parked on. On that day 294 of 309 dentall worktrees were 500+ commits behind
origin/dev, and the main folder (where most windows start) was on a June branch: every window opened
there ran on June rules. Claude Code also reads CLAUDE.md only at window start (and after compaction),
so an edit never reaches a window that is already open. A rule in a doc cannot fix either; this does.

Modes (argv[1]); each reads the hook's JSON on stdin:
  session-start  SessionStart startup|resume|clear|compact. Fetches the base branch (throttled), and
                 when this checkout's CLAUDE.md differs from the base branch's, injects the base
                 branch's copy as "RULES IN FORCE". Always prints one "Rules loaded" line.
                 startup/clear/compact load the rule files fresh from disk, so they set the baseline.
                 resume may not: it is judged like a prompt (diff against the saved baseline).
                 Also prepends scripts/settings-drift-check.py's report (silent unless this Mac's
                 settings.json drifted from the template's _sync_required keys).
                 A worker's compaction (agent_id present, the PARENT's session_id) gets the subagent
                 note only: the parent's saved state is never loaded, written or collected.
  prompt         UserPromptSubmit. No network wait (fetch runs in the background, throttled).
                 When the global rules or the base branch's CLAUDE.md changed since this session
                 loaded them, injects only the changed lines as "RULES CHANGED": a small diff, never
                 a reload, so the prompt cache survives. A session with no saved baseline (opened
                 before this hook existed) is given the current global rules once, and the base copy
                 of CLAUDE.md when its checkout is stale.
  subagent       SubagentStart. A subagent loads CLAUDE.md from disk, so in a stale checkout it gets
                 the stale copy: inject the base branch's copy. Explore and Plan load no CLAUDE.md by
                 Claude Code's design (read-only searchers) and are skipped.

"Base branch" = what refs/remotes/origin/HEAD points at (origin/dev for dentall). "Global rules" =
~/.claude/CLAUDE.md plus ~/.claude/rules/*.md. Whenever the global rules no longer match the hash in
~/.codex/AGENTS.md, Codex's copy is regenerated in the background (install-codex.sh --rules-only).

Claude Code replaces hook text over 10,000 characters with a 2,000-character preview, so the WHOLE
output stays under CAP: anything larger is written to a file and the note says to read it in full.
Each mode works inside one deadline, below its registered hook timeout.

Fail-open: any error exits 0 with no output (logged), so a session start can never break.
Env overrides (tests): RIF_STATE_DIR RIF_GLOBAL_FILE RIF_RULES_DIR RIF_LOG RIF_NO_CODEX=1 RIF_NO_FETCH=1
"""
from __future__ import annotations

import difflib
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
STATE_DIR = Path(os.environ.get("RIF_STATE_DIR", HOME / ".claude/progress/rules-state"))
GLOBAL_FILE = Path(os.environ.get("RIF_GLOBAL_FILE", HOME / ".claude/CLAUDE.md"))
RULES_DIR = Path(os.environ.get("RIF_RULES_DIR", HOME / ".claude/rules"))
LOG = Path(os.environ.get("RIF_LOG", HOME / ".claude/logs/rules-in-force.log"))
CODEX_AGENTS = HOME / ".codex/AGENTS.md"
CODEX_INSTALL = HOME / ".claude-dotfiles/scripts/install-codex.sh"

CAP = 9800                 # Claude Code's per-string hook limit is 10,000 characters
BUDGET = {"session-start": 13.0, "prompt": 4.0, "subagent": 4.0}   # registered timeouts: 15 / 5 / 5
FETCH_EVERY_START = 120    # seconds between blocking fetches at session start, per repo
FETCH_EVERY_PROMPT = 600   # seconds between background fetches on prompts, per repo
FETCH_SYNC_MAX = 8         # a blocking fetch never takes longer than this
FETCH_BG_MAX = 60          # a background fetch is killed after this
STATE_TTL_DAYS = 14
NO_CLAUDE_MD_AGENTS = {"Explore", "Plan"}
_DEADLINE = time.monotonic() + 4.0


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > 65536:
            LOG.write_bytes(LOG.read_bytes()[-32768:])
        with open(LOG, "a") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n")
    except Exception:
        pass


def remaining() -> float:
    return _DEADLINE - time.monotonic()


def git(args: list[str], cwd: str, limit: float = 5.0) -> tuple[int, str]:
    """Run git inside the mode's deadline. On timeout the whole process group is killed, so a stuck
    credential helper or transport cannot outlive the hook."""
    budget = min(limit, remaining() - 0.3)
    if budget <= 0:
        return 1, ""
    try:
        p = subprocess.Popen(["git", *args], cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True,
                             env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    except Exception as e:
        log(f"git {' '.join(args)} could not start: {e}")
        return 1, ""
    try:
        out, _ = p.communicate(timeout=budget)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:   # a helper in its own session may still hold the pipe: never wait on it unbounded
            p.communicate(timeout=0.5)
        except Exception:
            for pipe in (p.stdout,):
                try:
                    pipe.close()
                except Exception:
                    pass
        log(f"git {' '.join(args)} timed out after {budget:.1f}s in {cwd}")
        return 1, ""


def sha(text: str | None) -> str:
    return hashlib.sha256((text or "").encode()).hexdigest()[:16]


def version(text: str | None) -> str:
    m = re.search(r"Rules version:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", text or "")
    return m.group(1) if m else "unversioned"


def global_files() -> list[Path]:
    files = [GLOBAL_FILE]
    try:
        files += sorted(RULES_DIR.glob("*.md"))
    except OSError:
        pass
    return files


def global_rules() -> str:
    """Joined EXACTLY as scripts/generate-codex-layer.py joins them (the rules-source hash must match)."""
    parts = []
    for i, f in enumerate(global_files()):
        try:
            text = f.read_text()
        except OSError:
            text = ""
        parts.append(text if i == 0 else f"\n=== rules/{f.name} ===\n" + text)
    return "".join(parts)


class Repo:
    def __init__(self, cwd: str):
        self.ok = False
        rc, top = git(["rev-parse", "--show-toplevel"], cwd)
        if rc != 0 or not top.strip():
            return
        self.top = top.strip()
        rc, ref = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], self.top)
        self.base = ref.strip() if rc == 0 and ref.strip() else ""
        if not self.base:
            for cand in ("origin/dev", "origin/main", "origin/master"):
                if git(["rev-parse", "--verify", "-q", cand], self.top)[0] == 0:
                    self.base = cand
                    break
        if not self.base or "/" not in self.base:
            return
        self.remote, self.branch = self.base.split("/", 1)
        rc, common = git(["rev-parse", "--git-common-dir"], self.top)
        self.key = sha(os.path.realpath(os.path.join(self.top, common.strip())) if rc == 0 else self.top)
        self.ok = True

    def claim_fetch(self, min_age: int) -> bool:
        """At most one fetch per repo per min_age, across every window: the throttle check and the
        stamp update happen under one OS lock (released automatically if this process dies)."""
        stamp = STATE_DIR / f"fetch-{self.key}"
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            with open(STATE_DIR / f"fetch-{self.key}.lock", "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if stamp.exists() and time.time() - stamp.stat().st_mtime < min_age:
                    return False
                stamp.touch()
                return True
        except OSError:   # includes "another window holds the lock": it is fetching right now
            return False

    def fetch(self, min_age: int, background: bool) -> None:
        if os.environ.get("RIF_NO_FETCH") == "1" or not self.claim_fetch(min_age):
            return
        if not background:
            git(["fetch", "-q", self.remote, self.branch], self.top, limit=FETCH_SYNC_MAX)
            return
        try:   # a detached copy of this script runs the fetch through git(), whose timeout kills the
               # fetch's whole process group (transport and credential helpers included)
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "bg-fetch", self.top, self.remote,
                              self.branch], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except Exception as e:
            log(f"background fetch failed to start: {e}")

    def base_rules(self) -> str | None:
        rc, out = git(["show", f"{self.base}:CLAUDE.md"], self.top)
        return out if rc == 0 else None

    def base_sha(self) -> str:
        return git(["rev-parse", "--short", self.base], self.top)[1].strip()

    def local_rules(self) -> str | None:
        try:
            return (Path(self.top) / "CLAUDE.md").read_text()
        except OSError:
            return None

    def behind(self) -> str:
        rc, n = git(["rev-list", "--count", f"HEAD..{self.base}"], self.top, limit=2.0)
        return n.strip() if rc == 0 and n.strip() else "some"


KC_LOCK = "claude-keep-current.lock"
KC_LOCK_STALE = 120        # seconds before another window may take over an abandoned lock
KC_CHECKOUT_MAX = 30       # the checkout helper kills git after this
IN_PROGRESS = ("MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG")


def take_lock(path: Path) -> bool:
    """Non-blocking: mkdir is atomic. A lock older than KC_LOCK_STALE was abandoned and is taken over."""
    try:
        path.mkdir()
        return True
    except FileExistsError:
        try:
            if time.time() - path.stat().st_mtime < KC_LOCK_STALE:
                return False
            path.rmdir()
            path.mkdir()
            return True
        except OSError:
            return False
    except OSError:
        return False


def keep_current(repo: Repo) -> tuple[str, bool]:
    """Main folder only: fast-forward a clean, behind main worktree to the base branch, so windows that
    start there load current rules and project hooks. Returns (one line for the user or "", updated).
    Acts only when HEAD is detached or on the base branch, has no tracked changes, no merge/rebase is in
    progress, and HEAD is an ancestor of the base (no local-only commits). Linked worktrees (agents'
    task branches) are never touched. The checkout runs in a detached helper with its own time limit,
    so the hook's own timeout can never kill git mid-checkout; if it is still running when this hook
    must finish, the hook goes on and the checkout completes on its own."""
    if os.environ.get("RIF_NO_KEEP_CURRENT") == "1":
        return "", False
    rc, common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], repo.top)
    if rc != 0 or not common.strip():
        return "", False
    common_dir = Path(os.path.realpath(common.strip()))
    if common_dir.parent != Path(os.path.realpath(repo.top)):
        return "", False                                   # a linked worktree, or an unusual layout
    rc, n = git(["rev-list", "--count", f"HEAD..{repo.base}"], repo.top, limit=2.0)
    behind = int(n.strip()) if rc == 0 and n.strip().isdigit() else 0
    if behind <= 0:
        return "", False
    lock = common_dir / KC_LOCK
    if not take_lock(lock):
        return "", False                                   # another window is on it
    handed_off = False
    try:
        if any((common_dir / f).exists() for f in IN_PROGRESS):
            log(f"keep-current: {repo.top} has a merge/rebase/bisect in progress; not updated")
            return "", False
        rc, br = git(["symbolic-ref", "-q", "--short", "HEAD"], repo.top, limit=2.0)
        branch = br.strip() if rc == 0 else ""
        reason = ""
        if branch and branch != repo.branch:
            reason = f"is on branch {branch}"
        else:
            rc, st = git(["status", "--porcelain", "--untracked-files=no"], repo.top, limit=4.0)
            if rc != 0:
                log(f"keep-current: git status failed in {repo.top}")
                return "", False
            if st.strip():
                reason = "has local changes"
            elif git(["merge-base", "--is-ancestor", "HEAD", repo.base], repo.top, limit=2.0)[0] != 0:
                reason = "has local commits"
        if reason:
            return (f"Main folder {repo.top} is {behind} commits behind {repo.base} and {reason}; it was "
                    f"not updated. Work in a worktree off {repo.base}."), False
        wait = min(KC_CHECKOUT_MAX, remaining() - 3.0)
        if wait < 0.5:
            log(f"keep-current: no time left to update {repo.top}")
            return "", False
        try:
            p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "bg-checkout", repo.top, repo.base,
                                  str(lock)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        except Exception as e:
            log(f"keep-current: helper failed to start: {e}")
            return "", False
        handed_off = True                                  # the helper now owns the lock
        try:
            out, _ = p.communicate(timeout=wait)
        except subprocess.TimeoutExpired:
            log(f"keep-current: checkout of {repo.base} in {repo.top} still running; left to finish")
            return "", False
        try:
            res = json.loads(out or "{}")
        except ValueError:
            res = {}
        if res.get("rc") == 0:
            log(f"keep-current: {repo.top} updated {behind} commits to {repo.base}")
            return "", True
        err = str(res.get("err") or "")
        log(f"keep-current: checkout failed in {repo.top}: {err.strip()[:300]}")
        if "untracked working tree files would be" in err:
            return (f"Main folder {repo.top} could not update to {repo.base}: untracked files in the way "
                    f"(git status). Not changed."), False
        return "", False
    finally:
        if not handed_off:
            try:
                lock.rmdir()
            except OSError:
                pass


def bg_checkout(top: str, base: str, lock: str) -> None:
    """Internal (started by keep_current): the checkout itself, capped at KC_CHECKOUT_MAX, then the lock
    is released. Prints {"rc", "err"} for the waiting hook; if the hook already left, the print fails
    harmlessly."""
    res = {"rc": 1, "err": ""}
    try:
        p = subprocess.Popen(["git", "-C", top, "checkout", "-q", "--detach", base], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                             env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        try:
            _, err = p.communicate(timeout=KC_CHECKOUT_MAX)
            res = {"rc": p.returncode, "err": err}
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            res = {"rc": 1, "err": f"timed out after {KC_CHECKOUT_MAX}s"}
            log(f"keep-current: checkout in {top} timed out")
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass
    try:
        print(json.dumps(res), flush=True)
    except Exception:
        pass


def spill(name: str, text: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = STATE_DIR / name
    p.write_text(text)
    return p


# Each note is (headline, body). The headline is short; the body is the rules or the diff.
def in_force_note(repo: Repo, rules: str, updated: bool = False) -> tuple[str, str, str]:
    if updated:   # the checkout is current now, but this window read CLAUDE.md before the update
        head = (f"RULES IN FORCE: the main folder {repo.top} was just updated to {repo.base} {repo.base_sha()}, "
                f"after this window loaded its older CLAUDE.md. Follow the copy below over the one you loaded.")
    else:
        head = (f"RULES IN FORCE: this checkout's CLAUDE.md is stale ({repo.behind()} commits behind "
                f"{repo.base} {repo.base_sha()}). Follow the copy below over the one loaded from {repo.top}, "
                f"and tell the user the checkout is stale.")
    return head, f"<rules-in-force source=\"{repo.base}:CLAUDE.md\">\n{rules}\n</rules-in-force>", "in-force-CLAUDE.md"


def global_note(rules: str) -> tuple[str, str, str]:
    head = ("RULES IN FORCE: this session's loaded copy of the global rules is unknown and may be old. "
            "Follow the current global rules below over what you loaded earlier.")
    return head, f"<global-rules source=\"~/.claude/CLAUDE.md + ~/.claude/rules/\">\n{rules}\n</global-rules>", "global-rules.md"


def changed_note(changes: list[tuple[str, str, str]]) -> tuple[str, str, str]:
    head = ("RULES CHANGED since this session loaded them. The lines below are the change; follow the new "
            "lines over what you loaded earlier.")
    blocks = []
    for label, old, new in changes:
        diff = difflib.unified_diff(old.splitlines(), new.splitlines(), "loaded", "current", n=1, lineterm="")
        blocks.append(f"<rules-diff source=\"{label}\">\n" + "\n".join(list(diff)[2:]) + "\n</rules-diff>")
    return head, "\n\n".join(blocks), "rules-changes.md"


def render(notes: list[tuple[str, str, str]], tail: str, sid: str) -> str:
    """The whole output under CAP. Bodies that do not fit are written to files, largest first, and the
    headline tells the agent to read them in full."""
    notes = [list(n) for n in notes]

    def text() -> str:
        return "\n\n".join([f"{h}\n\n{b}" for h, b, _ in notes] + ([tail] if tail else []))

    for n in sorted(notes, key=lambda n: -len(n[1])):
        if len(text()) <= CAP:
            break
        p = spill(f"{sid}-{n[2]}", n[1])
        n[1] = f"It is too long to show here: Read {p} in full now, before anything else."
    out = text()
    return out if len(out) <= CAP else out[:CAP]


def load_state(sid: str) -> dict | None:
    try:
        return json.loads((STATE_DIR / f"{sid}.json").read_text())
    except Exception:
        return None


def save_state(sid: str, state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_DIR / f".{sid}.json.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(state))
    os.replace(tmp, STATE_DIR / f"{sid}.json")


def gc_state() -> None:
    cutoff = time.time() - STATE_TTL_DAYS * 86400
    try:
        for f in STATE_DIR.iterdir():
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink()
    except OSError:
        pass


def refresh_codex(global_text: str) -> None:
    """Codex has no hooks; its global rules block is regenerated from the same files when they change.
    install-codex.sh serializes itself, so overlapping calls are safe."""
    if os.environ.get("RIF_NO_CODEX") == "1" or not CODEX_INSTALL.exists():
        return
    try:
        if CODEX_AGENTS.exists() and f"rules-source: {sha(global_text)}" in CODEX_AGENTS.read_text():
            return
        subprocess.Popen(["bash", str(CODEX_INSTALL), "--quiet", "--rules-only"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception as e:
        log(f"codex refresh failed to start: {e}")


def settings_drift() -> str:
    """Main-window session start only: scripts/settings-drift-check.py's report ("" when this Mac's
    settings match the keys every Mac must share). Imported in-process; any error stays silent."""
    try:
        import importlib.util
        path = Path(__file__).resolve().parent.parent / "settings-drift-check.py"
        spec = importlib.util.spec_from_file_location("settings_drift_check", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.report()
    except Exception as e:
        log(f"settings drift check failed: {e.__class__.__name__}: {e}")
        return ""


def judge(sid: str, cwd: str, data: dict, state: dict | None, fresh_load: bool, background: bool,
          update_main: bool = False):
    """Returns (notes, state, global rules, project, keep-current line). fresh_load = Claude just read the
    rule files from disk (startup, clear, compact), so what is on disk now IS the baseline. Otherwise
    compare with the saved baseline; with none (a window opened before this hook existed), deliver
    whatever may have changed since it began. update_main = run keep_current after the fetch and
    BEFORE the stale check, so a main folder it fast-forwards is judged current."""
    notes: list[tuple[str, str, str]] = []
    kc_line = ""
    changes: list[tuple[str, str, str]] = []
    g = global_rules()
    if fresh_load or state is None:
        if state is None and not fresh_load:   # what this window loaded is unknown: give it the current set
            notes.append(global_note(g))
        state = {"global": g, "projects": {}}
    elif g != state.get("global"):
        changes.append(("global rules (~/.claude/CLAUDE.md + ~/.claude/rules/)", state.get("global") or "", g))
        state["global"] = g
    state.setdefault("projects", {})

    repo = Repo(cwd)
    project = None
    if repo.ok:
        repo.fetch(FETCH_EVERY_PROMPT if background else FETCH_EVERY_START, background)
        loaded = repo.local_rules()            # what this window read at start, before any update
        updated = False
        if update_main:
            kc_line, updated = keep_current(repo)
        b = repo.base_rules()
        if b is not None:
            project = (version(b), repo.base, repo.base_sha())
            known = state["projects"].get(repo.top)
            if fresh_load or known is None:
                if updated and loaded != b:
                    notes.append(in_force_note(repo, b, updated=True))
                elif not updated and repo.local_rules() != b:
                    notes.append(in_force_note(repo, b))
            elif known != b:
                changes.append((f"{repo.base}:CLAUDE.md", known, b))
            state["projects"][repo.top] = b
    if changes:
        notes.insert(0, changed_note(changes))
    return notes, state, g, project, kc_line


def worker_note(data: dict, cwd: str, sid: str) -> str:
    """The base branch's CLAUDE.md for a worker (subagent) in a stale checkout, or "". Read-only:
    no saved state is loaded, written or collected, and no Codex refresh is started."""
    if str(data.get("agent_type") or "") in NO_CLAUDE_MD_AGENTS:
        return ""
    repo = Repo(cwd)
    if not repo.ok:
        return ""
    b = repo.base_rules()
    if b is None or repo.local_rules() == b:
        return ""
    return render([in_force_note(repo, b)], "", sid)


def main() -> int:
    global _DEADLINE
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "bg-fetch" and len(sys.argv) == 5:   # internal: started detached by Repo.fetch
        _DEADLINE = time.monotonic() + FETCH_BG_MAX + 1
        git(["fetch", "-q", sys.argv[3], sys.argv[4]], sys.argv[2], limit=FETCH_BG_MAX)
        return 0
    _DEADLINE = time.monotonic() + BUDGET.get(mode, 4.0)
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    sid = re.sub(r"[^A-Za-z0-9_-]", "", str(data.get("session_id") or ""))[:128]
    cwd = str(data.get("cwd") or os.getcwd())
    if not sid:
        return 0

    agent_id = data.get("agent_id")
    if mode == "session-start" and isinstance(agent_id, str) and agent_id:
        # A worker's compaction: SessionStart(compact) with the PARENT's session_id plus agent_id.
        # Give the worker the same note SubagentStart gives it; the parent's baseline is not ours.
        # An oversized note spills to a worker-keyed file, never to the parent's own spill file.
        note = worker_note(data, cwd, f"{sid}-worker")
        if note:
            print(note)
        return 0

    if mode in ("session-start", "prompt"):
        state = load_state(sid)
        source = str(data.get("source") or "startup")
        fresh = mode == "session-start" and source != "resume"
        # Keep the main folder current at a window's start; never on compact (mid-session: the files
        # would change under an agent that is working there).
        notes, state, g, project, kc_line = judge(sid, cwd, data, state, fresh_load=fresh,
                                                  background=(mode == "prompt"),
                                                  update_main=(mode == "session-start" and source != "compact"))
        tail = ""
        if mode == "session-start":
            tail = f"Rules loaded: global {version(g)}"
            if project:
                tail += f"; project {project[0]} from {project[1]} ({project[2]})"
            tail += "."
            if kc_line:
                tail = f"{kc_line}\n{tail}"
            drift = settings_drift()
            if drift:
                tail = f"{drift}\n{tail}"
        out = render(notes, tail, sid)       # spills happen BEFORE the baseline is saved
        save_state(sid, state)
        refresh_codex(g)
        if mode == "session-start":
            gc_state()
        if out:
            print(out)
        return 0

    if mode == "subagent":
        note = worker_note(data, cwd, sid)
        if note:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "SubagentStart",
                                                     "additionalContext": note}}))
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail open: never break a session
        log(f"{sys.argv[1:]} crashed: {e.__class__.__name__}: {e}")
        sys.exit(0)
