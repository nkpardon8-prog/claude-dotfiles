#!/usr/bin/env bash
# transfer-send.sh - package ONE Claude Code or Codex chat so `resumework <code>` can reopen it,
# verbatim, on another Mac (same username, same absolute paths).
#
# Usage:
#   transfer-send.sh --tool claude|codex --sid <id> [--cwd <dir>] [--dry-run] [--force]
#                    [--seal-after-exit] [--code <TX-...>]
#   transfer-send.sh --tool codex <id>                      (a positional id is accepted too)
#
#   --dry-run          list what would travel (counts, total size, the 10 largest items, excluded
#                      secret names, git plan, secret-scan verdict) and write NOTHING. Exits 2 when a
#                      real run would refuse.
#   --force            allow a bundle over the 500 MB total cap.
#   --seal-after-exit  (claude only) validate everything, print CODE/LOCATOR at once, then hand off to
#                      a fully detached sealer that waits (max 30 min) for this chat's claude process
#                      to exit, snapshots the now-complete transcript and git state, and packages.
#                      Without it, packaging happens immediately (tests, the Codex path, a chat that
#                      is already closed).
#   --code <TX-...>    use this code instead of generating one (the code is visible in `ps` while
#                      this runs; /transfer never passes it).
#
# Output on stdout, only when it proceeds:   CODE=TX-XXXX-XXXX-XXXX-XXXX   and   LOCATOR=<16 hex>
# Exit: 0 ok | 2 refused (one-line human reason on stderr) | 1 error
#
# What travels (paths are $HOME-relative; B must have the same username and paths):
#   claude  transcript <slug>/<sid>.jsonl + <slug>/<sid>/, file-history/<sid>/, session-env/<sid>/,
#           tasks/<sid>/, chains/<sid>.{json,log}, progress/ctx-<sid>.txt, session-status/<sid>.txt
#           (the /line caption), the project memory dir, plans/ and paste-cache/ entries this chat
#           referenced; at ROOT: CLAUDE.local.<sid>.md(.prev), MISSION.<sid>.*, TRANSFER.<sid>.md,
#           .mission-backups/*<sid>*
#   codex   the rollout file plus every history_base / forked_from parent, from $CODEX_HOME
#   both    git: a bundle of commits no remote has (or none), a `git diff HEAD` patch, untracked
#           files; context: worktree tmp/ and ROOT tmp/ files modified in the last 7 days or named
#           in the handoff / TRANSFER / MISSION files (5 MB per file)
# What never travels: auto-compact sentinels, mission liveness, locks (incl. tick.<sid>.lock),
#   prod.lock, resumed-/transferred- markers, node_modules/dist/.next/coverage, and any secret-named
#   file (.env*, *.env, *creds*, *credential*, *.pem, *.key, *.p12, .envrc, .npmrc, *secret*,
#   auth.json) - their NAMES go into the manifest so B's restart checklist can say what to reload.
#   The staged payload is then run through scripts/secret-scan.sh and any hit refuses the send.
#
# SEALER DETACH (why not launchctl submit): `launchctl submit` tells launchd to keep the job alive,
# i.e. to RESTART it when it exits - wrong for a one-shot. Instead: nohup + all fds redirected +
# a perl double-fork with POSIX::setsid(), so the sealer is in its own session, reparented to
# launchd, immune to SIGHUP and to the claude process-group teardown when the chat exits.
set -uo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _t=$(readlink "$_self")
  case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "$_self")" && pwd -P)"
SELF="$SELF_DIR/$(basename "$_self")"
# shellcheck source=transfer-lib.sh
. "$SELF_DIR/transfer-lib.sh" || { echo "transfer-send: cannot load transfer-lib.sh" >&2; exit 1; }

PROG="transfer-send"
DEV_OK=0
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] && DEV_OK=1
# Test-only switch for the exclusion negative control. Honored ONLY under the test gate, so a stray
# environment variable can never make a real transfer carry secrets or machine-bound state.
EXCLUDES_OFF=0
[ "$DEV_OK" = 1 ] && [ "${TX_TEST_DISABLE_EXCLUDES:-}" = "1" ] && EXCLUDES_OFF=1

CONTEXT_FILE_CAP=5242880                 # 5 MB per context file
TOTAL_CAP=524288000                      # 500 MB per bundle unless --force
[ "$DEV_OK" = 1 ] && [ -n "${TX_TEST_TOTAL_CAP_BYTES:-}" ] && TOTAL_CAP="$TX_TEST_TOTAL_CAP_BYTES"
HANDOFF_MAX_AGE=1800                     # the handoff must be under 30 minutes old
SEAL_TIMEOUT=1800
[ "$DEV_OK" = 1 ] && [ -n "${TX_TEST_SEAL_TIMEOUT:-}" ] && SEAL_TIMEOUT="$TX_TEST_SEAL_TIMEOUT"

WORK=""; STAGE=""; SEALDIR=""; IN_SEALER=0; LOC=""
cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  [ "$IN_SEALER" = 1 ] && [ -n "$SEALDIR" ] && rm -rf "$SEALDIR"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

_fail_marker() {  # sealer only: tell the waiting receiver why no bundle will come (never the code)
  [ "$IN_SEALER" = 1 ] && [ -n "$LOC" ] || return 0
  local d
  d=$(tx_drop_dir 2>/dev/null) || return 0
  ( umask 077
    printf 'reason=%s\nat=%s\nhost=%s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname -s)" \
      > "$d/.$LOC.tx.failed.tmp.$$" && mv -f "$d/.$LOC.tx.failed.tmp.$$" "$d/$LOC.tx.failed" ) 2>/dev/null
  return 0
}
refuse() { echo "$PROG: REFUSED: $*" >&2; tx_log "send refused locator=${LOC:-none}: $*"; _fail_marker "refused: $*"; exit 2; }
die()    { echo "$PROG: ERROR: $*" >&2; tx_log "send error locator=${LOC:-none}: $*"; _fail_marker "error: $*"; exit 1; }
note()   { echo "$PROG: $*" >&2; }

usage() { sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------------------------
TOOL=""; SID=""; CWD_ARG=""; DRY=0; FORCE=0; SEAL=0; CODE_ARG=""; SEAL_RUN=""
SEALED_AT=""; ARGV_STR=""; WPID=""; WLSTART=""
_need() { [ "$1" -ge 2 ] || { echo "$PROG: REFUSED: $2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tool) _need $# "$1"; TOOL="$2"; shift 2 ;;
    --tool=*) TOOL="${1#*=}"; shift ;;
    --sid) _need $# "$1"; SID="$2"; shift 2 ;;
    --sid=*) SID="${1#*=}"; shift ;;
    --cwd) _need $# "$1"; CWD_ARG="$2"; shift 2 ;;
    --cwd=*) CWD_ARG="${1#*=}"; shift ;;
    --code) _need $# "$1"; CODE_ARG="$2"; shift 2 ;;
    --code=*) CODE_ARG="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --seal-after-exit) SEAL=1; shift ;;
    --_seal-run) _need $# "$1"; SEAL_RUN="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "$PROG: REFUSED: unknown option $1 (see --help)" >&2; exit 2 ;;
    *)
      if [ -z "$SID" ]; then SID="$1"; shift
      else echo "$PROG: REFUSED: unexpected argument $1" >&2; exit 2; fi
      ;;
  esac
done

if [ -n "$SEAL_RUN" ]; then
  # Sealer mode: everything arrives through a private 700 dir, never argv (the code must not show
  # in `ps`, and the chat that launched us is about to disappear).
  IN_SEALER=1
  SEALDIR="$SEAL_RUN"
  [ -f "$SEALDIR/args" ] && [ -f "$SEALDIR/code" ] || { echo "$PROG: sealer handoff dir incomplete: $SEALDIR" >&2; exit 1; }
  while IFS='=' read -r _k _v; do
    case "$_k" in
      tool) TOOL="$_v" ;; sid) SID="$_v" ;; cwd) CWD_ARG="$_v" ;; force) FORCE="$_v" ;;
      pid) WPID="$_v" ;; lstart) WLSTART="$_v" ;; argv) ARGV_STR="$_v" ;;
    esac
  done < "$SEALDIR/args"
  CODE_ARG=$(cat "$SEALDIR/code")
  rm -f "$SEALDIR/code"
  SEAL=0
fi

case "$TOOL" in claude | codex) ;; *) refuse "--tool must be claude or codex" ;; esac
case "$SID" in "" | *[!A-Za-z0-9_-]*) refuse "--sid must be a session id (letters, digits, - and _)" ;; esac
[ "$SEAL" = 1 ] && [ "$TOOL" != claude ] && refuse "--seal-after-exit is for --tool claude only (close the Codex chat first, then send)"
[ "$SEAL" = 1 ] && [ "$DRY" = 1 ] && refuse "--seal-after-exit and --dry-run do not combine"
command -v python3 >/dev/null 2>&1 || refuse "python3 is required"
command -v git >/dev/null 2>&1 || refuse "git is required"
tx_openssl >/dev/null || refuse "no openssl with -pbkdf2 support found"
HOME_P=$(cd -P "$HOME" 2>/dev/null && pwd -P) || die "cannot resolve \$HOME"
CODE_N=""
if [ -n "$CODE_ARG" ]; then
  CODE_N=$(tx_normalize "$CODE_ARG") || refuse "--code is not a valid transfer code"
  LOC=$(tx_locator "$CODE_N")
fi

under_home() { case "$1/" in "$HOME_P"/*) return 0 ;; esac; return 1; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tx-work.XXXXXX") || die "cannot create a scratch dir"
tx_guard_path "$WORK" || { rm -rf "$WORK"; WORK=""; refuse "scratch dir would sit inside the public dotfiles repo (fix \$TMPDIR)"; }
chmod 700 "$WORK"

# ------------------------------------------------------------------------------------------------
# Resolve the session
# ------------------------------------------------------------------------------------------------
REG_PID=""; REG_CWD=""; TRANSCRIPT=""; CWD=""; CODEX_DIR=""

py_registry() {  # newest ~/.claude/sessions entry for this sid -> "pid<TAB>cwd"
  python3 - "$HOME_P/.claude/sessions" "$SID" <<'PY'
import glob, json, os, sys
d, sid = sys.argv[1], sys.argv[2]
best = None
for f in glob.glob(os.path.join(d, "*.json")):
    try:
        j = json.load(open(f))
    except Exception:
        continue
    if not isinstance(j, dict) or j.get("sessionId") != sid or not isinstance(j.get("pid"), int):
        continue
    m = os.path.getmtime(f)
    if best is None or m > best[0]:
        best = (m, j)
if best:
    print("%d\t%s" % (best[1]["pid"], best[1].get("cwd") or ""))
PY
}

py_transcript_cwd() {  # last "cwd" recorded in a transcript
  python3 - "$1" <<'PY'
import json, sys
cwd = ""
with open(sys.argv[1], "rb") as fh:
    for line in fh:
        try:
            j = json.loads(line)
        except Exception:
            continue
        if isinstance(j, dict) and isinstance(j.get("cwd"), str) and j["cwd"]:
            cwd = j["cwd"]
print(cwd)
PY
}

find_transcript() {  # prefer the project dir whose slug matches $1 (a cwd), else the first hit
  local c pick="" slug=""
  [ -n "${1:-}" ] && slug=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  for c in "$HOME_P"/.claude/projects/*/"$SID".jsonl; do
    [ -f "$c" ] || continue
    [ -z "$pick" ] && pick="$c"
    if [ -n "$slug" ] && [ "$(basename "$(dirname "$c")")" = "$slug" ]; then pick="$c"; fi
  done
  printf '%s' "$pick"
}

if [ "$TOOL" = claude ]; then
  _reg=$(py_registry)
  if [ -n "$_reg" ]; then REG_PID="${_reg%%	*}"; REG_CWD="${_reg#*	}"; fi
  CWD="$CWD_ARG"
  [ -z "$CWD" ] && CWD="$REG_CWD"
  TRANSCRIPT=$(find_transcript "$CWD")
  [ -n "$TRANSCRIPT" ] || refuse "no transcript for session $SID under ~/.claude/projects/*/"
  [ -z "$CWD" ] && CWD=$(py_transcript_cwd "$TRANSCRIPT")
  [ -n "$CWD" ] || refuse "cannot tell this chat's working directory; pass --cwd"
  [ -d "$CWD" ] || refuse "working directory $CWD does not exist"
  CWD=$(cd -P "$CWD" && pwd -P)
  TRANSCRIPT=$(find_transcript "$CWD")
else
  CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
  [ -d "$CODEX_DIR" ] || refuse "no Codex home at $CODEX_DIR"
  CODEX_DIR=$(cd -P "$CODEX_DIR" && pwd -P)
  under_home "$CODEX_DIR" || refuse "CODEX_HOME ($CODEX_DIR) must be under \$HOME so B can mirror it"
  if [ -d "$CODEX_DIR/thread-writer-locks" ] && \
     [ -n "$(find "$CODEX_DIR/thread-writer-locks" -maxdepth 2 -name "*$SID*" 2>/dev/null | head -1)" ]; then
    refuse "Codex session $SID is still open (a thread-writer lock exists) - close that Codex chat first"
  fi
  python3 - "$CODEX_DIR" "$SID" > "$WORK/codex.tsv" <<'PY'
import json, os, re, sys
home, sid = sys.argv[1], sys.argv[2]
UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
name_rx = re.compile(r"^rollout-.*-(" + UUID + r")\.jsonl")
index = {}
for sub in ("sessions", "archived_sessions"):
    for dp, dn, fn in os.walk(os.path.join(home, sub)):
        for f in fn:
            m = name_rx.match(f)
            if m:
                index.setdefault(m.group(1).lower(), []).append(os.path.join(dp, f))

def meta(path):
    try:
        with open(path, "rb") as fh:
            j = json.loads(fh.readline())
    except Exception:
        return {}
    p = j.get("payload") if isinstance(j, dict) else None
    return p if isinstance(p, dict) else {}

def ids_in(v):
    # history_base's exact shape is not pinned by any doc we have: accept a bare id, a rollout
    # path, or an object carrying either, so a shape change fails LOUD (parent not found) rather
    # than silently shipping a chat that cannot rebuild its history.
    out = []
    if isinstance(v, str):
        m = re.search(UUID, v)
        if m:
            out.append(m.group(0).lower())
    elif isinstance(v, dict):
        for k in ("id", "thread_id", "session_id", "forked_from_id", "rollout_path", "path"):
            if k in v:
                out.extend(ids_in(v[k]))
    return out

hits = index.get(sid.lower(), [])
if not hits:
    print("ERR\tno Codex rollout for id %s under %s/sessions or archived_sessions" % (sid, home))
    sys.exit(0)
main = sorted(hits)[0]
print("CWD\t%s" % (meta(main).get("cwd") or ""))
todo, seen = [(main, True)], set()
while todo:
    path, required = todo.pop()
    if path in seen:
        continue
    seen.add(path)
    print("FILE\t%s" % path)
    m = meta(path)
    for key, req in (("history_base", True), ("forked_from_id", False)):
        for pid in ids_in(m.get(key)):
            got = index.get(pid)
            if got:
                todo.append((sorted(got)[0], req))
            elif req:
                print("ERR\thistory_base parent %s of %s is not on this Mac" % (pid, os.path.basename(path)))
            else:
                print("WARN\tfork parent %s of %s is not on this Mac (continuing)" % (pid, os.path.basename(path)))
PY
  _err=$(sed -n 's/^ERR	//p' "$WORK/codex.tsv" | head -1)
  [ -n "$_err" ] && refuse "$_err"
  sed -n 's/^WARN	//p' "$WORK/codex.tsv" | while IFS= read -r _w; do note "warning: $_w"; done
  CWD="$CWD_ARG"
  [ -z "$CWD" ] && CWD=$(sed -n 's/^CWD	//p' "$WORK/codex.tsv" | head -1)
  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r _f; do
      [ -n "$(lsof -t -- "$_f" 2>/dev/null)" ] && refuse "a process still has $(basename "$_f") open - close that Codex chat first"
    done <<EOF
$(sed -n 's/^FILE	//p' "$WORK/codex.tsv")
EOF
  fi
  if [ -n "$CWD" ] && [ -d "$CWD" ]; then CWD=$(cd -P "$CWD" && pwd -P)
  else
    [ -n "$CWD" ] && note "warning: the Codex chat's cwd $CWD no longer exists; sending without git or context"
    CWD=""
  fi
fi

# ------------------------------------------------------------------------------------------------
# Repo layout + guards
# ------------------------------------------------------------------------------------------------
GIT=0; WT=""; ROOT=""
if [ -n "$CWD" ]; then
  under_home "$CWD" || refuse "working directory $CWD must be under \$HOME so B can mirror the path"
  tx_guard_path "$CWD" 2>/dev/null || refuse "this chat works inside the public dotfiles repo ($CWD); transfer refuses to package anything from there"
  if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT=1
    WT=$(git -C "$CWD" rev-parse --show-toplevel)
    ROOT=$(handoff_canonical_root "$CWD")
  else
    ROOT="$CWD"
  fi
  tx_guard_path "$ROOT" 2>/dev/null || refuse "the repo root is the public dotfiles repo ($ROOT); transfer refuses to package it"
  under_home "$ROOT" || refuse "repo root $ROOT must be under \$HOME"
fi

if [ "$GIT" = 1 ]; then
  _gd=$(git -C "$WT" rev-parse --absolute-git-dir)
  for _m in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$_gd/$_m" ] && refuse "a git operation is in progress in $WT ($_m present) - finish or abort it first"
  done
  git -C "$WT" rev-parse -q --verify HEAD >/dev/null 2>&1 || refuse "the repository at $WT has no commits yet"
fi

if [ "$TOOL" = claude ] && [ "$IN_SEALER" = 0 ]; then
  _h="$ROOT/CLAUDE.local.$SID.md"
  [ -f "$_h" ] || refuse "no handoff at $_h - run /pre-compact first (the /transfer command does this)"
  _msid=$(_resolver_extract_marker_sid "$_h")
  [ "$_msid" = "$SID" ] || refuse "the handoff's END-OF-HANDOFF marker sid (${_msid:-missing}) does not match $SID - it is truncated or belongs to another chat"
  _age=$(( $(date +%s) - $(stat -f %m "$_h") ))
  [ "$_age" -lt "$HANDOFF_MAX_AGE" ] || refuse "the handoff is $((_age / 60)) minutes old (limit 30) - re-run /pre-compact"
fi

# ------------------------------------------------------------------------------------------------
# Collection. LIST = kind<TAB>abs ; SKIP = reason<TAB>abs ; SECR = names left behind on purpose.
# ------------------------------------------------------------------------------------------------
LIST="$WORK/list.tsv"; SKIP="$WORK/skipped.tsv"; SECR="$WORK/secrets.txt"

disp() {  # display a path relative to its worktree, repo root, or $HOME
  if [ -n "$WT" ]; then case "$1" in "$WT"/*) printf '%s' "${1#"$WT"/}"; return ;; esac; fi
  if [ -n "$ROOT" ]; then case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}"; return ;; esac; fi
  printf '%s' "${1#"$HOME_P"/}"
}

add_file() {  # add_file <kind> <abs> [<relpath used for the machine-bound check>]
  local kind="$1" f="$2" rel="${3:-${2##*/}}"
  [ -e "$f" ] || [ -L "$f" ] || return 0
  case "$f" in
    *"	"* | *"
"*) printf 'unsupported-name\t%s\n' "$(printf '%s' "$f" | tr '\t\n' '??')" >> "$SKIP"; return 0 ;;
  esac
  if [ "$EXCLUDES_OFF" != 1 ]; then
    if tx_is_never_name "$rel"; then printf 'machine-bound\t%s\n' "$f" >> "$SKIP"; return 0; fi
    case "$kind" in
      untracked | context)
        if tx_is_heavy_path "$rel"; then printf 'heavy-dir\t%s\n' "$f" >> "$SKIP"; return 0; fi
        ;;
    esac
    if tx_is_secret_name "$f"; then disp "$f" >> "$SECR"; printf '\n' >> "$SECR"; return 0; fi
  fi
  if [ -L "$f" ]; then printf 'symlink\t%s\n' "$f" >> "$SKIP"; return 0; fi
  [ -f "$f" ] || return 0
  printf '%s\t%s\n' "$kind" "$f" >> "$LIST"
}

add_tree() {  # add_tree <kind> <dir> <relpath-prefix>
  local kind="$1" d="$2" pre="$3" f
  [ -d "$d" ] && [ ! -L "$d" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && add_file "$kind" "$f" "$pre/${f#"$d"/}"
  done <<EOF
$(find "$d" \( -type f -o -type l \) 2>/dev/null)
EOF
}

add_entry() {  # a path that may be a file or a directory
  if [ -d "$2" ] && [ ! -L "$2" ]; then add_tree "$1" "$2" "$3"; else add_file "$1" "$2" "$3"; fi
}

collect_claude() {
  local pdir f h
  pdir=$(dirname "$TRANSCRIPT")
  add_file session "$TRANSCRIPT"
  add_tree session "$pdir/$SID" "$SID"
  add_tree session "$HOME_P/.claude/file-history/$SID" "$SID"
  add_tree session "$HOME_P/.claude/session-env/$SID" "$SID"
  add_tree session "$HOME_P/.claude/tasks/$SID" "$SID"
  add_file session "$HOME_P/.claude/chains/$SID.json"
  add_file session "$HOME_P/.claude/chains/$SID.log"
  add_file session "$HOME_P/.claude/progress/ctx-$SID.txt"
  add_file session "$HOME_P/.claude/session-status/$SID.txt"
  add_tree memory "$pdir/memory" "memory"
  # plans/ named in the transcript; paste-cache/ entries this sid pasted (history.jsonl keys them by
  # sessionId + contentHash, the transcript itself does not name them).
  grep -aoE '\.claude/plans/[A-Za-z0-9._-]+\.md' "$TRANSCRIPT" 2>/dev/null | sort -u | while IFS= read -r f; do
    add_file session "$HOME_P/$f"
  done
  if [ -f "$HOME_P/.claude/history.jsonl" ]; then
    python3 - "$HOME_P/.claude/history.jsonl" "$SID" <<'PY' | while IFS= read -r h; do add_file session "$HOME_P/.claude/paste-cache/$h.txt"; done
import json, re, sys
seen = set()
with open(sys.argv[1], "rb") as fh:
    for line in fh:
        if sys.argv[2].encode() not in line:
            continue
        try:
            j = json.loads(line)
        except Exception:
            continue
        if j.get("sessionId") != sys.argv[2]:
            continue
        for v in (j.get("pastedContents") or {}).values():
            h = v.get("contentHash") if isinstance(v, dict) else None
            if isinstance(h, str) and re.match(r"^[0-9a-f]{8,64}$", h) and h not in seen:
                seen.add(h)
                print(h)
PY
  fi
}

collect_root() {
  local e
  [ -n "$ROOT" ] || return 0
  if [ "$TOOL" = claude ]; then
    add_file root "$ROOT/CLAUDE.local.$SID.md"
    add_file root "$ROOT/CLAUDE.local.$SID.md.prev"
    for e in "$ROOT"/MISSION."$SID".*; do add_file root "$e"; done
    for e in "$ROOT"/.mission-backups/*"$SID"*; do add_entry root "$e" "${e##*/}"; done
  fi
  add_file root "$ROOT/TRANSFER.$SID.md"
}

collect_codex() {
  local f
  while IFS= read -r f; do [ -n "$f" ] && add_file codex "$f"; done <<EOF
$(sed -n 's/^FILE	//p' "$WORK/codex.tsv")
EOF
}

collect_untracked() {
  local r
  [ "$GIT" = 1 ] || return 0
  git -C "$WT" ls-files -o --exclude-standard -z 2>/dev/null | tr '\0' '\n' > "$WORK/untracked.raw"
  while IFS= read -r r; do
    [ -n "$r" ] && add_file untracked "$WT/$r" "$r"
  done < "$WORK/untracked.raw"
}

collect_context() {
  local base f r seen="" files
  for base in "$WT" "$ROOT"; do
    [ -n "$base" ] && [ -d "$base/tmp" ] || continue
    case " $seen " in *" $base "*) continue ;; esac
    seen="$seen $base"
    find "$base/tmp" \( -name node_modules -o -name .git -o -name dist -o -name .next -o -name coverage \) -prune \
      -o \( -type f -o -type l \) -mmin -10080 -print 2>/dev/null | while IFS= read -r f; do
      add_file context "$f" "${f#"$base"/}"
    done
  done
  # Anything under tmp/ that the handoff, TRANSFER or MISSION files name by path, however old.
  files=""
  for f in "$ROOT/CLAUDE.local.$SID.md" "$ROOT/TRANSFER.$SID.md" "$ROOT"/MISSION."$SID".*; do
    [ -f "$f" ] && files="$files
$f"
  done
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | while IFS= read -r f; do [ -n "$f" ] && cat "$f"; done 2>/dev/null \
    | grep -aoE 'tmp/[A-Za-z0-9._@+/-]+' | sed -E 's#[.,:;/]+$##' | sort -u | while IFS= read -r r; do
      for base in "$WT" "$ROOT"; do
        [ -n "$base" ] || continue
        if [ -e "$base/$r" ] || [ -L "$base/$r" ]; then add_entry context "$base/$r" "$r"; fi
      done
    done
}

collect_all() {
  : > "$LIST"; : > "$SKIP"; : > "$SECR"
  if [ "$TOOL" = claude ]; then collect_claude; else collect_codex; fi
  collect_root
  collect_untracked
  collect_context
  # .env* names that exist in the repo (typically gitignored, so the untracked walk never sees them)
  local base
  for base in "$WT" "$ROOT"; do
    [ -n "$base" ] && [ -d "$base" ] || continue
    find "$base" -maxdepth 4 \( -name node_modules -o -name .git -o -name tmp \) -prune -o \
      -type f \( -name '.env*' -o -name '*.env' -o -name '.envrc' \) -print 2>/dev/null | while IFS= read -r f; do
      disp "$f" >> "$SECR"; printf '\n' >> "$SECR"
    done
  done
  sort -u "$SECR" | sed '/^$/d' > "$SECR.sorted" && mv "$SECR.sorted" "$SECR"
}

# ------------------------------------------------------------------------------------------------
# plan / stage (python: sizes, per-file cap, copy with mtime+mode, hash the STAGED bytes)
# ------------------------------------------------------------------------------------------------
py_files() {  # py_files plan|stage <out> [<stage-payload-dir>]
  python3 - "$1" "$LIST" "$SKIP" "$HOME_P" "$CONTEXT_FILE_CAP" "$2" "${3:-}" "${CODEX_DIR:-}" <<'PY'
import hashlib, json, os, shutil, stat, sys
mode, lst, skipf, home, cap, out, payload, codex_dir = sys.argv[1:9]
cap = int(cap)
seen, entries, skipped = set(), [], []
with open(lst, encoding="utf-8", errors="surrogateescape") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        kind, _, ab = line.partition("\t")
        if ab in seen:
            continue
        seen.add(ab)
        if not ab.startswith(home + "/"):
            skipped.append(["outside-home", ab])
            continue
        try:
            st = os.lstat(ab)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            skipped.append(["not-a-regular-file", ab])
            continue
        if kind == "context" and st.st_size > cap:
            skipped.append(["over-%dMB-cap" % (cap // 1048576), ab])
            continue
        entries.append((kind, ab, st))
by_kind, total = {}, 0
for kind, ab, st in entries:
    n, b = by_kind.get(kind, (0, 0))
    by_kind[kind] = (n + 1, b + st.st_size)
    total += st.st_size
top = sorted(((st.st_size, ab[len(home) + 1:]) for _, ab, st in entries), reverse=True)[:10]
res = {"count": len(entries), "bytes": total, "by_kind": by_kind, "top10": top, "skipped": skipped}
if mode == "stage":
    files = []
    for kind, ab, st in entries:
        rel = ab[len(home) + 1:]
        dst = os.path.join(payload, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(ab, dst)
        h = hashlib.sha256()
        with open(dst, "rb") as f2:
            for chunk in iter(lambda: f2.read(1 << 20), b""):
                h.update(chunk)
        s2 = os.stat(dst)
        e = {"path": rel, "kind": kind, "sha256": h.hexdigest(), "size": s2.st_size,
             "mode": "%04o" % (st.st_mode & 0o7777), "mtime": int(st.st_mtime), "mtime_ns": st.st_mtime_ns}
        if kind == "codex":
            e["codex_rel"] = ab[len(codex_dir) + 1:]
        files.append(e)
    res["files"] = files
with open(out, "w") as fo:
    json.dump(res, fo)
PY
}

human() { awk -v b="$1" 'BEGIN{ if (b >= 1048576) printf "%.1f MB", b/1048576; else if (b >= 1024) printf "%.1f KB", b/1024; else printf "%d B", b }'; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }

check_space() {  # check_space <dir> <bytes-needed>
  local avail_kb need_kb
  avail_kb=$(df -k "$1" 2>/dev/null | awk 'NR==2{print $4}')
  need_kb=$(( ($2 / 1024) * 2 + 1024 ))
  [ -n "$avail_kb" ] || return 0
  [ "$avail_kb" -ge "$need_kb" ] || refuse "not enough free disk space at $1: need $((need_kb / 1024)) MB (2x the bundle), have $((avail_kb / 1024)) MB"
}

# Secret scan: the repo's own scanner, in batches. Its hit report quotes the matched text, so it is
# captured to a private file and only FILE NAMES are ever shown.
scan_secrets() {  # scan_secrets <NUL-list of files> <prefix-to-strip-for-display>
  local scanner="$TX_REPO_DIR/scripts/secret-scan.sh" worst=0 n=0 f rc out="$WORK/scan.out" hits=""
  local -a batch
  [ -f "$scanner" ] || refuse "secret scanner not found at $scanner"
  : > "$out"; chmod 600 "$out"
  _scan_batch() {
    bash "$scanner" -- "${batch[@]}" >> "$out" 2>&1; rc=$?
    case "$rc" in 0) ;; 2) [ "$worst" -lt 2 ] && worst=2 ;; *) worst=3 ;; esac
    batch=(); n=0
  }
  while IFS= read -r -d '' f; do
    batch[n]="$f"; n=$((n + 1))
    [ "$n" -ge 200 ] && _scan_batch
  done < "$1"
  [ "$n" -gt 0 ] && _scan_batch
  if [ "$worst" = 2 ]; then
    while IFS= read -r -d '' f; do
      if grep -qF -- "$f:" "$out" 2>/dev/null; then
        case "$f" in
          "$2"*) f="${f#"$2"}" ;;
          */uncommitted.patch) f="git: uncommitted changes" ;;
          */unpushed-commits.txt) f="git: commits no remote has" ;;
        esac
        hits="${hits}${hits:+, }$f"
      fi
    done < "$1"
  fi
  rm -f "$out"
  SCAN_RESULT="$worst"; SCAN_HITS="$hits"
}

# ------------------------------------------------------------------------------------------------
# Git staging
# ------------------------------------------------------------------------------------------------
G_HEAD=""; G_BRANCH=""; G_UPSTREAM=""; G_ORIGIN=""; G_BUNDLE=0; G_REF=""; G_UNPUSHED=0
G_PATCH_SHA=""; G_PATCH_BYTES=0; G_BUNDLE_BYTES=0
git_facts() {
  G_HEAD=$(git -C "$WT" rev-parse HEAD)
  G_BRANCH=$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)
  G_UPSTREAM=$(git -C "$WT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  G_ORIGIN=$(git -C "$WT" remote get-url origin 2>/dev/null || true)
  G_UNPUSHED=$(git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null) || die "git rev-list failed in $WT"
  if [ -n "$G_BRANCH" ]; then G_REF="refs/heads/$G_BRANCH"; else G_REF="HEAD"; fi
}

stage_git() {  # writes <dir>/branch.bundle (only if commits no remote has) + uncommitted.patch
  local d="$1" err
  mkdir -p "$d"
  if [ "$G_UNPUSHED" -gt 0 ]; then
    err=$(git -C "$WT" bundle create -q "$d/branch.bundle" "$G_REF" --not --remotes 2>&1) \
      || die "git bundle create failed: $err"
    G_BUNDLE=1
    G_BUNDLE_BYTES=$(stat -f %z "$d/branch.bundle")
    git -C "$WT" log -p --no-color --no-ext-diff HEAD --not --remotes > "$WORK/unpushed-commits.txt" 2>/dev/null
  else
    G_BUNDLE=0
  fi
  tx_git_diff_head "$WT" > "$d/uncommitted.patch" || die "git diff failed in $WT"
  G_PATCH_SHA=$(sha_of "$d/uncommitted.patch")
  G_PATCH_BYTES=$(stat -f %z "$d/uncommitted.patch")
}

# ------------------------------------------------------------------------------------------------
# Build: collect -> plan -> caps/space -> stage -> scan -> manifest -> tar. Leaves $STAGE/inner.tgz.
# ------------------------------------------------------------------------------------------------
build_bundle() {
  local total
  collect_all
  py_files plan "$WORK/plan.json" || die "planning failed"
  [ "$GIT" = 1 ] && git_facts
  total=$(jget "$WORK/plan.json" 'd["bytes"]')
  if [ "$total" -gt "$TOTAL_CAP" ] && [ "$FORCE" != 1 ]; then
    refuse "the bundle would be $(human "$total") (cap $(human "$TOTAL_CAP")); run with --dry-run to see the largest items, or --force"
  fi
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/tx-stage.XXXXXX") || die "cannot create a staging dir"
  tx_guard_path "$STAGE" || refuse "staging would sit inside the public dotfiles repo (fix \$TMPDIR)"
  chmod 700 "$STAGE"
  check_space "$STAGE" "$total"
  mkdir -p "$STAGE/b/payload" "$STAGE/b/git"
  [ "$GIT" = 1 ] && stage_git "$STAGE/b/git"
  py_files stage "$WORK/staged.json" "$STAGE/b/payload" || die "staging failed"

  # secret scan over exactly the bytes that will ship (+ the patch + the unpushed commits' diffs)
  : > "$WORK/scan.list"
  find "$STAGE/b/payload" -type f -print0 >> "$WORK/scan.list"
  if [ "$GIT" = 1 ]; then
    [ -s "$STAGE/b/git/uncommitted.patch" ] && printf '%s\0' "$STAGE/b/git/uncommitted.patch" >> "$WORK/scan.list"
    [ -s "$WORK/unpushed-commits.txt" ] && printf '%s\0' "$WORK/unpushed-commits.txt" >> "$WORK/scan.list"
  fi
  if [ -s "$WORK/scan.list" ]; then
    scan_secrets "$WORK/scan.list" "$STAGE/b/payload/"
    case "$SCAN_RESULT" in
      0) ;;
      2) refuse "secret-shaped content found in: $SCAN_HITS (names only; contents not shown). Remove or redact it, then retry. Nothing was sent." ;;
      *) refuse "the secret scan could not prove the payload clean (scanner failure); nothing was sent" ;;
    esac
  fi

  write_manifest "$STAGE/b/manifest.json"
  ( cd "$STAGE/b" && COPYFILE_DISABLE=1 tar -czf "$STAGE/inner.tgz" manifest.json payload git ) \
    || die "tar failed"
}

write_manifest() {
  local out="$1" cver="" xver=""
  if [ "$TOOL" = claude ]; then
    cver=$(pt_run 15 "${TX_CLAUDE_BIN:-claude}" --version 2>/dev/null </dev/null | head -1 | awk '{print $1}')
  else
    xver=$(pt_run 15 "${TX_CODEX_BIN:-codex}" --version 2>/dev/null </dev/null | head -1 | awk '{print $NF}')
  fi
  {
    printf 'tool=%s\nsid=%s\ncwd=%s\nroot=%s\nworktree=%s\n' "$TOOL" "$SID" "$CWD" "$ROOT" "$WT"
    printf 'user=%s\nhome=%s\nsource_host=%s\n' "$(id -un)" "$HOME_P" "$(hostname -s)"
    printf 'created_at=%s\nsealed_after_exit_at=%s\nargv=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SEALED_AT" "$ARGV_STR"
    printf 'claude_version=%s\ncodex_version=%s\ncodex_home_rel=%s\n' "$cver" "$xver" "${CODEX_DIR#"$HOME_P"/}"
    printf 'git=%s\ngit_origin=%s\ngit_branch=%s\ngit_upstream=%s\ngit_head=%s\n' "$GIT" "$G_ORIGIN" "$G_BRANCH" "$G_UPSTREAM" "$G_HEAD"
    printf 'git_bundle=%s\ngit_bundle_ref=%s\ngit_patch_sha256=%s\ngit_patch_bytes=%s\n' "$G_BUNDLE" "$G_REF" "$G_PATCH_SHA" "$G_PATCH_BYTES"
    printf 'git_worktree_is_root=%s\n' "$([ -n "$WT" ] && [ "$WT" = "$ROOT" ] && echo 1 || echo 0)"
  } > "$WORK/meta"
  python3 - "$WORK/meta" "$WORK/staged.json" "$SECR" "$WORK/untracked.raw" "$out" <<'PY' || die "manifest write failed"
import json, os, sys
meta_f, staged_f, secr_f, untracked_f, out = sys.argv[1:6]
m = {}
with open(meta_f, encoding="utf-8", errors="surrogateescape") as fh:
    for line in fh:
        k, _, v = line.rstrip("\n").partition("=")
        m[k] = v
st = json.load(open(staged_f))
files = st.get("files", [])
secrets = [l.strip() for l in open(secr_f) if l.strip()] if os.path.exists(secr_f) else []
g = None
if m["git"] == "1":
    untracked = sum(1 for f in files if f["kind"] == "untracked")
    g = {"origin": m["git_origin"], "branch": m["git_branch"] or None, "detached": m["git_branch"] == "",
         "upstream": m["git_upstream"] or None, "head": m["git_head"],
         "bundle": "git/branch.bundle" if m["git_bundle"] == "1" else None, "bundle_ref": m["git_bundle_ref"],
         "patch": "git/uncommitted.patch", "patch_sha256": m["git_patch_sha256"],
         "patch_bytes": int(m["git_patch_bytes"] or 0), "untracked_count": untracked,
         "worktree": m["worktree"], "worktree_is_root": m["git_worktree_is_root"] == "1",
         "staged_split_flattened": True, "env_files_present": [s for s in secrets if os.path.basename(s).lower().startswith(".env") or s.lower().endswith(".env")]}
manifest = {
    "format": 1, "tool": m["tool"], "sid": m["sid"], "cwd": m["cwd"] or None, "root": m["root"] or None,
    "user": m["user"], "home": m["home"], "source_host": m["source_host"], "created_at": m["created_at"],
    "sealed_after_exit_at": m["sealed_after_exit_at"] or None, "argv": m["argv"] or None,
    "versions": {"claude": m["claude_version"] or None, "codex": m["codex_version"] or None},
    "codex_home_rel": m["codex_home_rel"] if m["tool"] == "codex" else None,
    "departure": {"head": m["git_head"] or None, "diff_sha256": m["git_patch_sha256"] or None},
    "git": g, "excluded_secret_names": secrets,
    "skipped": [{"reason": r, "path": p} for r, p in st.get("skipped", [])],
    "files": files,
}
with open(out, "w") as fo:
    json.dump(manifest, fo, indent=1, sort_keys=True)
PY
}

publish() {  # encrypt straight into the drop dir under a dot-tmp name, then atomic renames
  local drop tmp side sha size
  drop=$(tx_drop_dir) || refuse "the drop folder is unusable"
  [ -e "$drop/$LOC.tx" ] && refuse "a bundle for this code already exists in the drop folder"
  check_space "$drop" "$(stat -f %z "$STAGE/inner.tgz")"
  tmp="$drop/.$LOC.tx.tmp.$$"
  tx_encrypt "$STAGE/inner.tgz" "$tmp" "$CODE_N" || { rm -f "$tmp"; die "encryption failed"; }
  sha=$(sha_of "$tmp"); size=$(stat -f %z "$tmp")
  mv -f "$tmp" "$drop/$LOC.tx" || die "could not place the bundle in $drop"
  # The sidecar lands AFTER the payload: its presence means the payload is complete on A.
  side="$drop/.$LOC.tx.sha256.tmp.$$"
  printf 'format=1\nsha256=%s\nsize=%s\n' "$sha" "$size" > "$side" && mv -f "$side" "$drop/$LOC.tx.sha256" \
    || die "could not write the checksum sidecar"
  rm -f "$drop/$LOC.tx.failed"
  PUB_SIZE="$size"
}

post_send() {
  local f="$HOME_P/.claude/progress/transferred-$SID"
  mkdir -p "$(dirname "$f")"
  ( umask 077
    printf 'sid=%s\ntool=%s\nlocator=%s\nsent_at=%s\nworktree=%s\nhead=%s\ndiff_sha256=%s\n' \
      "$SID" "$TOOL" "$LOC" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$WT" "$G_HEAD" "$G_PATCH_SHA" > "$f.tmp.$$" \
      && mv -f "$f.tmp.$$" "$f" )
  [ "$GIT" = 1 ] && tx_git_info_exclude "$ROOT"
  tx_log "send ok locator=$LOC tool=$TOOL files=$(jget "$WORK/staged.json" 'len(d.get("files", []))') bytes=${PUB_SIZE:-0} sealed=${SEALED_AT:-no}"
  tx_expire_sweep
}

# ------------------------------------------------------------------------------------------------
# Dry run
# ------------------------------------------------------------------------------------------------
if [ "$DRY" = 1 ]; then
  collect_all
  py_files plan "$WORK/plan.json" || die "planning failed"
  [ "$GIT" = 1 ] && git_facts
  total=$(jget "$WORK/plan.json" 'd["bytes"]')
  would_refuse=""
  echo "DRY-RUN transfer-send  tool=$TOOL  sid=$SID"
  echo "  cwd:      ${CWD:-<none>}"
  echo "  root:     ${ROOT:-<none>}"
  [ "$GIT" = 1 ] && echo "  worktree: $WT"
  echo "  files:    $(jget "$WORK/plan.json" 'd["count"]') ($(human "$total"))  $(jget "$WORK/plan.json" '"  ".join("%s=%d" % (k, v[0]) for k, v in sorted(d["by_kind"].items()))')"
  if [ "$GIT" = 1 ]; then
    echo "  git:      ${G_BRANCH:-<detached>} @ ${G_HEAD:0:12}; commits no remote has: $G_UNPUSHED ($([ "$G_UNPUSHED" -gt 0 ] && echo bundle || echo 'no bundle; B fetches origin')); uncommitted patch: $(tx_git_diff_head "$WT" | wc -c | tr -d ' ') bytes"
  fi
  if [ -s "$SECR" ]; then echo "  left behind on purpose (reload on B):"; sed 's/^/    - /' "$SECR"; fi
  echo "  skipped:  $(jget "$WORK/plan.json" 'len(d["skipped"])') + $(wc -l < "$SKIP" | tr -d ' ') machine-bound/heavy/symlink"
  echo "  10 largest:"
  python3 -c 'import json,sys
for b, p in json.load(open(sys.argv[1]))["top10"]:
    print("    %10s  %s" % (("%.1f MB" % (b / 1048576.0)) if b >= 1048576 else ("%.1f KB" % (b / 1024.0)), p))' "$WORK/plan.json"
  if [ "$total" -gt "$TOTAL_CAP" ] && [ "$FORCE" != 1 ]; then
    would_refuse="over the $(human "$TOTAL_CAP") cap (use --force)"
  fi
  python3 -c 'import sys
for l in open(sys.argv[1]):
    k, _, a = l.rstrip("\n").partition("\t")
    if a: sys.stdout.buffer.write(a.encode("utf-8", "surrogateescape") + b"\0")' "$LIST" > "$WORK/scan.list"
  if [ -s "$WORK/scan.list" ]; then
    scan_secrets "$WORK/scan.list" "$HOME_P/"
    case "$SCAN_RESULT" in
      0) echo "  secret scan: clean" ;;
      2) echo "  secret scan: HIT in $SCAN_HITS"; would_refuse="${would_refuse}${would_refuse:+; }secret-shaped content in $SCAN_HITS" ;;
      *) echo "  secret scan: could not run"; would_refuse="${would_refuse}${would_refuse:+; }secret scan failed" ;;
    esac
  fi
  echo "Nothing was written."
  if [ -n "$would_refuse" ]; then echo "A real run would REFUSE: $would_refuse" >&2; exit 2; fi
  exit 0
fi

# ------------------------------------------------------------------------------------------------
# Seal-after-exit launcher (runs inside the live chat): validate fully, print the code, detach.
# ------------------------------------------------------------------------------------------------
lstart_of() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'; }

if [ "$SEAL" = 1 ]; then
  if [ "$DEV_OK" = 1 ] && [ -n "${TX_SEAL_PID:-}" ]; then WPID="$TX_SEAL_PID"; else WPID="$REG_PID"; fi
  [ -n "$WPID" ] || refuse "cannot find this chat's claude process in ~/.claude/sessions (needed to seal after it exits)"
  WLSTART=$(lstart_of "$WPID")
  [ -n "$WLSTART" ] || refuse "the claude process ($WPID) is not running; send without --seal-after-exit instead"
  ARGV_STR=$(ps -o args= -p "$WPID" 2>/dev/null | tr '\n\t' '  ')
  build_bundle                      # the full pipeline, so a refusal happens NOW, while someone is watching
  rm -rf "$STAGE"; STAGE=""
  [ -n "$CODE_N" ] || CODE_N=$(tx_normalize "$(tx_new_code)") || die "could not generate a code"
  LOC=$(tx_locator "$CODE_N")
  SEALDIR=$(mktemp -d "${TMPDIR:-/tmp}/tx-seal.XXXXXX") || die "cannot create the sealer dir"
  tx_guard_path "$SEALDIR" || refuse "sealer dir would sit inside the public dotfiles repo"
  chmod 700 "$SEALDIR"
  ( umask 077
    printf 'tool=%s\nsid=%s\ncwd=%s\nforce=%s\npid=%s\nlstart=%s\nargv=%s\n' \
      "$TOOL" "$SID" "$CWD" "$FORCE" "$WPID" "$WLSTART" "$ARGV_STR" > "$SEALDIR/args"
    printf '%s' "$CODE_N" > "$SEALDIR/code" )
  mkdir -p "$HOME_P/.claude/logs" && chmod 700 "$HOME_P/.claude/logs" 2>/dev/null
  SEAL_LOG="$HOME_P/.claude/logs/transfer-sealer-$LOC.log"
  ( umask 077; : >> "$SEAL_LOG" )
  nohup perl -MPOSIX -e 'my $p = fork; exit 0 if $p; POSIX::setsid(); exec @ARGV or exit 127' \
    /bin/bash "$SELF" --_seal-run "$SEALDIR" </dev/null >>"$SEAL_LOG" 2>&1 &
  disown 2>/dev/null || true
  tx_log "seal armed locator=$LOC sid=$SID pid=$WPID"
  echo "CODE=$(tx_format "$CODE_N")"
  echo "LOCATOR=$LOC"
  note "sealer armed: the bundle is written after this chat's claude process ($WPID) exits (max $((SEAL_TIMEOUT / 60)) min). Log: $SEAL_LOG"
  exit 0
fi

# ------------------------------------------------------------------------------------------------
# Package now (immediate mode, or the sealer after the chat exited)
# ------------------------------------------------------------------------------------------------
if [ "$IN_SEALER" = 1 ]; then
  echo "sealer: waiting for pid $WPID to exit"
  _start=$(date +%s)
  while kill -0 "$WPID" 2>/dev/null && [ "$(lstart_of "$WPID")" = "$WLSTART" ]; do
    if [ $(( $(date +%s) - _start )) -ge "$SEAL_TIMEOUT" ]; then
      refuse "the chat did not exit within $((SEAL_TIMEOUT / 60)) minutes; nothing was sent - run /transfer again"
    fi
    sleep 1
  done
  SEALED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "sealer: pid $WPID gone at $SEALED_AT; packaging"
else
  if [ "$TOOL" = claude ] && [ -n "$REG_PID" ] && kill -0 "$REG_PID" 2>/dev/null; then
    ARGV_STR=$(ps -o args= -p "$REG_PID" 2>/dev/null | tr '\n\t' '  ')
  fi
fi

[ -n "$CODE_N" ] || CODE_N=$(tx_normalize "$(tx_new_code)") || die "could not generate a code"
LOC=$(tx_locator "$CODE_N")
build_bundle
publish
post_send
if [ "$IN_SEALER" = 1 ]; then
  echo "sealer: bundle $LOC.tx written"
else
  echo "CODE=$(tx_format "$CODE_N")"
  echo "LOCATOR=$LOC"
fi
exit 0
