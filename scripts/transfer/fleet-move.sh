#!/usr/bin/env bash
# fleet-move.sh - ONE-TIME move of every live Claude chat on this Mac to another Mac (the ssh host
# named by FLEET_DEST=<your-alias>, REQUIRED, no default), at the SAME absolute paths, so each chat
# continues there with plain `claude --resume <sid>` (or /resume from its folder). This Mac keeps
# every file: it only gains markers and logs under ~/.claude/progress and ~/.claude/logs/fleet.
#
# Usage:  fleet-move.sh <subcommand> [--dry-run] [--only <sid,...>] [--apply] [--no-npm]
#   inventory              live chats (session registry + liveness), the repo roots they own, extra
#                          roots from FLEET_EXTRA_ROOTS (colon-separated globs); writes
#                          ~/.claude/logs/fleet/fleet.json. Exits 2 on a duplicate window or a bad root.
#   dest-check             tool parity on the destination (claude codex gh gcloud op node npm, logins,
#                          git identity, MCP servers, credentials.md, docker shim, alias homes, free
#                          space, dotfiles HEAD, fleet_lib.py version) and per chat what is missing.
#   dest-setup [--apply]   settings.json full match (this Mac's $HOME rewritten to the destination's),
#                          MCP servers + project trust merged into ~/.claude.json, git identity, npm
#                          installs of codex/runpane. Shows the diff; writes (with backups) only with --apply.
#   backup                 ~/fleet-backup-<ts>/claude (all of ~/.claude except the session registry and
#                          login files) + ~/fleet-backup-<ts>/roots.tar on the destination. Never restored
#                          automatically: the "nothing missed" net.
#   seed [--no-npm]        bulk rsync of every root (no --delete, no --checksum; windows keep working),
#                          then `npm ci --legacy-peer-deps` there for each chat's launch worktree.
#   final [--only ...]     needs FLEET_DOCKER_OK=1. Gates (packed markers, nothing open or running in
#                          the roots, versions, aliases, nothing changed on the destination since a
#                          landing), then rsync --checksum --delete of the roots, then the per-chat
#                          state copy (staged, checksummed, refused on conflict) and the merges.
#   verify                 byte manifest + git fingerprints of the last final (or seed) on both Macs,
#                          plus the chat state; receipt on both Macs. Exit 0 only with zero mismatches.
#   land                   after a clean verify: transferred-<sid> here, transfer-arrived-<sid> and
#                          landed.json there.
#   resume-list            `cd <cwd> && claude --resume <sid>` for every landed chat.
#   rollback <sid>         un-land one chat, only while its transcript on the destination is unchanged.
#   --dry-run              rsync -n (never -E), no staging, no merges, no markers, no receipts; only a
#                          report under ~/.claude/logs/fleet/runs/<ts>-<cmd>-dry/.
#   --only <sid,...>       full session ids or unique 8+ character prefixes (final: the pilot).
#
# Safety (owner rules for this move):
#   - Nothing here deletes or modifies a source file; writes on THIS Mac go only to
#     ~/.claude/progress (markers) and ~/.claude/logs/fleet (plans, logs, receipts).
#   - `--delete` is used only by `final`, only on roots the destination confirmed sit inside a
#     verified home alias and are reached through no symlink.
#   - Logs, manifests and receipts never go inside a git repo or the public dotfiles repo
#     (tx_guard_path + fleet_lib.py guard-path).
#   - Receipts and mismatch lines name the top-level root and a path HASH, never a filename.
#
# rsync: macOS ships openrsync (protocol 29). `-a` there includes -D, so the flags are spelled out
# as -rlptgo (sockets/fifos never travel) plus -H (hard links), -E (xattrs/ACLs; never with -n),
# --numeric-ids, -R with --no-implied-dirs (missing parents are created, existing parents such as
# the alias home are never re-permissioned) and anchored, literal exclude rules from fleet_lib.py.
#
# Destination preflight (every subcommand that touches the destination, dest-check first of all):
# FLEET_DEST must be set, and the host it reaches must answer `uname -s` = Darwin with a $HOME under
# /Users - an ssh alias that was repointed at some other machine is refused before anything runs.
#
# Exit: 0 ok | 2 refused (reasons on stderr) | 1 error.
# Dev-only (TRANSFER_TESTS_ALLOW_DEV=true): FLEET_TEST_DEST_HOME + FLEET_TEST_DEST_PREFIX run the
# destination side locally (tests); see fleet_lib.py for the rest.
set -uo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _t=$(readlink "$_self")
  case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "$_self")" && pwd -P)"
# shellcheck source=transfer-lib.sh
. "$SELF_DIR/transfer-lib.sh" || { echo "fleet-move: cannot load transfer-lib.sh" >&2; exit 1; }

PROG="fleet-move"
LIB="$SELF_DIR/fleet_lib.py"
PY="${FLEET_PYTHON:-python3}"
note() { echo "$PROG: $*" >&2; }
# flog: tx_log's format and size ring, but in ~/.claude/logs/fleet/fleet.log. tx_log itself is not
# used because it writes ~/.claude/logs/transfer.log, and this move writes nothing on this Mac
# outside ~/.claude/progress and ~/.claude/logs/fleet.
flog() {
  local log="$HOME/.claude/logs/fleet/fleet.log" size
  [ -d "${log%/*}" ] || return 0
  ( umask 077 && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$log" ) 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$size" ] && [ "$size" -gt 262144 ]; then
    ( umask 077 && tail -c 131072 "$log" > "$log.tmp.$$" ) 2>/dev/null && mv "$log.tmp.$$" "$log" 2>/dev/null
  fi
  return 0
}
refuse() { echo "$PROG: REFUSED: $*" >&2; flog "refused: $*"; exit 2; }
die() { echo "$PROG: ERROR: $*" >&2; flog "error: $*"; exit 1; }

DEV_OK=0
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] && DEV_OK=1
LOCAL_DEST=0
if [ "$DEV_OK" = 1 ] && [ -n "${FLEET_TEST_DEST_HOME:-}" ]; then
  [ -n "${FLEET_TEST_DEST_PREFIX:-}" ] || die "FLEET_TEST_DEST_HOME needs FLEET_TEST_DEST_PREFIX"
  LOCAL_DEST=1
fi
FLEET_DEST="${FLEET_DEST:-}"
LOGDIR="$HOME/.claude/logs/fleet"
TS=$(date -u '+%Y%m%dT%H%M%SZ')
HOST_S=$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9._-\n' '-')
FLEET_ALIAS_HOMES="$(tx_alias_homes)"
export FLEET_ALIAS_HOMES

command -v "$PY" >/dev/null 2>&1 || refuse "python3 is required"
[ -f "$LIB" ] || die "fleet_lib.py not found next to this script"

usage() { sed -n '2,/^# Exit:/p' "$SELF_DIR/fleet-move.sh" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------------------------
CMD="${1:-}"
[ -n "$CMD" ] || { usage; exit 1; }
shift
DRY=0; ONLY=""; APPLY=0; NO_NPM=0; ARG_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --only) [ $# -gt 1 ] || refuse "--only needs a list of session ids"; ONLY="$2"; shift ;;
    --only=*) ONLY="${1#--only=}" ;;
    --apply) APPLY=1 ;;
    --no-npm) NO_NPM=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) refuse "unknown option $1" ;;
    *) [ "$CMD" = rollback ] && [ -z "$ARG_SID" ] || refuse "unexpected argument $1"; ARG_SID="$1" ;;
  esac
  shift
done
case "$ONLY" in *[!A-Za-z0-9_,-]*) refuse "--only takes session ids separated by commas" ;; esac
[ -n "$ONLY" ] && [ "$CMD" != final ] && refuse "--only applies to final (the pilot); verify and land follow that run"
[ "$APPLY" = 1 ] && [ "$CMD" != dest-setup ] && refuse "--apply only applies to dest-setup"
[ "$APPLY" = 1 ] && [ "$DRY" = 1 ] && refuse "--apply and --dry-run do not combine"

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------
lib() { "$PY" "$LIB" "$@"; }

rlib() {  # rlib <cmd> [args]: fleet_lib.py on the destination; stdin/stdout pass through
  local a
  for a in "$@"; do
    case "$a" in "" | *[!A-Za-z0-9_.,=:/+-]*) die "internal: unsafe remote argument" ;; esac
  done
  if [ "$LOCAL_DEST" = 1 ]; then
    env -u FLEET_ALIAS_HOMES HOME="$FLEET_TEST_DEST_HOME" "$PY" "$LIB" "$@"
  else
    # The tilde is meant to expand on the destination, not here.
    # shellcheck disable=SC2088
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$FLEET_DEST" python3 '~/.claude-dotfiles/scripts/transfer/fleet_lib.py' "$@"
  fi
}

dest_root_spec() { if [ "$LOCAL_DEST" = 1 ]; then printf '%s/' "$FLEET_TEST_DEST_PREFIX"; else printf '%s:/' "$FLEET_DEST"; fi; }
dest_home_spec() { if [ "$LOCAL_DEST" = 1 ]; then printf '%s/%s' "$FLEET_TEST_DEST_HOME" "$1"; else printf '%s:%s' "$FLEET_DEST" "$1"; fi; }

need_dest() {  # FLEET_DEST set + the destination is a Mac whose user home is under /Users
  local out os dhome
  [ -n "$FLEET_DEST" ] || refuse "FLEET_DEST is not set: export FLEET_DEST=<ssh alias of the destination Mac> (there is no default)"
  case "$FLEET_DEST" in -* | *[!A-Za-z0-9@._-]*) refuse "FLEET_DEST must be an ssh host name" ;; esac
  [ -n "${DEST_OK:-}" ] && return 0
  if [ "$LOCAL_DEST" = 1 ]; then
    os=$(uname -s); dhome="$FLEET_TEST_DEST_HOME"
    [ -d "$dhome" ] || refuse "test destination home $dhome does not exist"
  else
    # shellcheck disable=SC2016  # $HOME must expand on the destination
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$FLEET_DEST" 'uname -s; printf "%s\n" "$HOME"' 2>/dev/null) \
      || refuse "cannot reach $FLEET_DEST over ssh (BatchMode): check the alias and keys"
    os=$(printf '%s\n' "$out" | sed -n 1p); dhome=$(printf '%s\n' "$out" | sed -n 2p)
    [ "$os" = Darwin ] || refuse "$FLEET_DEST is not a Mac (uname -s says '${os:-?}'): FLEET_DEST must name the destination Mac"
    case "$dhome" in /Users/?*) ;; *) refuse "$FLEET_DEST is not a Mac user account: its home is '${dhome:-?}', expected /Users/<name>" ;; esac
  fi
  [ "$os" = Darwin ] || refuse "$FLEET_DEST is not a Mac (uname -s says '${os:-?}'): FLEET_DEST must name the destination Mac"
  DEST_OK=1
}

ensure_logdir() {
  tx_guard_path "$LOGDIR" || refuse "the fleet log folder would sit inside the public dotfiles repo"
  lib guard-path "$LOGDIR" || refuse "the fleet log folder $LOGDIR must not sit inside a git repo"
  mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
  chmod 700 "$LOGDIR" "$HOME/.claude/logs" 2>/dev/null
}

need_inventory() { [ -f "$LOGDIR/fleet.json" ] || refuse "run '$PROG inventory' first"; }

new_run() {  # new_run <name> -> sets RUN
  local suffix=""
  [ "$DRY" = 1 ] && suffix="-dry"
  RUN="$LOGDIR/runs/$TS-$1$suffix"
  ( umask 077; mkdir -p "$RUN" ) || die "cannot create $RUN"
}

json_get() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }

roots_args() {  # sets ROOTS_N from the run's roots.txt
  ROOTS_N=$(grep -c . "$RUN/roots.txt" 2>/dev/null | tr -d ' ')
}

run_rsync_roots() {  # run_rsync_roots <seed|final>
  local flags=(-rlptgoH --numeric-ids -R --no-implied-dirs --itemize-changes "--exclude-from=$RUN/excludes.rsync")
  local r roots=() rc
  [ "$DRY" = 1 ] && flags+=(-n) || flags+=(-E)
  [ "$1" = final ] && flags+=(--checksum --delete)
  [ "$LOCAL_DEST" = 1 ] || flags+=(-e "ssh -o BatchMode=yes")
  while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done < "$RUN/roots.txt"
  [ "${#roots[@]}" -gt 0 ] || { note "no roots to copy"; return 0; }
  note "rsync ($1$([ "$DRY" = 1 ] && echo ', dry run')): ${#roots[@]} root(s) -> $([ "$LOCAL_DEST" = 1 ] && echo 'local test destination' || echo "$FLEET_DEST")"
  rsync "${flags[@]}" "${roots[@]}" "$(dest_root_spec)" > "$RUN/rsync.log" 2> "$RUN/rsync.err"
  rc=$?
  chmod 600 "$RUN/rsync.log" "$RUN/rsync.err" 2>/dev/null
  # Counts only: the itemized log holds filenames and stays in the mode-700 run folder.
  note "rsync: $(grep -c '^[<>]f' "$RUN/rsync.log" | tr -d ' ') file(s) $([ "$DRY" = 1 ] && echo 'would be ')sent, $(grep -c '^cd' "$RUN/rsync.log" | tr -d ' ') new folder(s), $(grep -c '^\*deleting' "$RUN/rsync.log" | tr -d ' ') deletion(s); rc=$rc (itemized: $RUN/rsync.log)"
  if [ "$rc" -ne 0 ]; then
    grep -v 'skipping non-regular file' "$RUN/rsync.err" | head -5 | sed 's/^/  /' >&2
    return "$rc"
  fi
  return 0
}

gate_dest() {  # dest-gate + fold into the plan; rc 2 when anything refuses
  rlib dest-gate < "$RUN/plan.json" > "$RUN/gate.json" || die "cannot run the destination gate on $FLEET_DEST"
  lib apply-gate --run-dir "$RUN"
}

# ------------------------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------------------------
do_inventory() {
  local rc
  [ "$DRY" = 1 ] && note "inventory only reads; --dry-run changes nothing"
  ensure_logdir
  lib inventory --out "$LOGDIR/fleet.json"
  rc=$?
  note "saved $LOGDIR/fleet.json"
  flog "inventory rc=$rc"
  return "$rc"
}

do_dest_check() {
  need_dest
  ensure_logdir; need_inventory
  ( umask 077
    rlib dest-check > "$LOGDIR/dest-check-$TS.json" ) || die "cannot run fleet_lib.py on $FLEET_DEST (ssh, or its dotfiles lack fleet_lib.py)"
  ( umask 077; lib dest-check --local > "$LOGDIR/source-check-$TS.json" ) || die "local tool report failed"
  lib dest-compare "$LOGDIR/source-check-$TS.json" "$LOGDIR/dest-check-$TS.json" --fleet-json "$LOGDIR/fleet.json"
  flog "dest-check dest=$FLEET_DEST"
}

do_dest_setup() {
  need_dest
  local rc
  ensure_logdir; need_inventory
  if [ "$APPLY" = 1 ]; then
    lib setup-payload --fleet-json "$LOGDIR/fleet.json" | rlib dest-setup --ts "$TS" --apply
  else
    lib setup-payload --fleet-json "$LOGDIR/fleet.json" | rlib dest-setup --ts "$TS"
  fi
  rc=$?
  flog "dest-setup apply=$APPLY rc=$rc"
  return "$rc"
}

do_backup() {
  need_dest
  local rc dir="fleet-backup-$TS" lsha rsha
  local cflags=(-rlptgoH --numeric-ids --itemize-changes --exclude=/sessions/ "--exclude=/.credentials*" --exclude=/fleet-staging/)
  ensure_logdir; need_inventory; new_run backup
  lib plan --mode backup --run-dir "$RUN" --fleet-json "$LOGDIR/fleet.json"
  rc=$?
  [ "$rc" = 2 ] && refuse "backup plan refused (reasons above); nothing was copied"
  [ "$rc" = 0 ] || die "planning the backup failed"
  [ "$(rlib self-sha)" = "$(lib self-sha)" ] || refuse "the destination's fleet_lib.py differs from this one: pull the dotfiles there first"
  roots_args
  if [ "$DRY" = 1 ]; then
    note "dry run: would stream a tar of $ROOTS_N root(s) to ~/$dir/roots.tar there and copy ~/.claude to ~/$dir/claude"
    [ "$LOCAL_DEST" = 1 ] || cflags+=(-e "ssh -o BatchMode=yes")
    rsync "${cflags[@]}" -n "$HOME/.claude/" "$(dest_home_spec "$dir/claude/")" > "$RUN/claude-rsync.log" 2>&1
    rc=$?
    note "~/.claude: $(grep -c '^[<>]f' "$RUN/claude-rsync.log" | tr -d ' ') file(s) would be copied (rc=$rc)"
    return 0
  fi
  [ "$LOCAL_DEST" = 1 ] || cflags+=(-e "ssh -o BatchMode=yes")
  note "backup: streaming $ROOTS_N root(s) to ~/$dir/roots.tar on the destination"
  lib tar-roots --sha-out "$RUN/tar.sha" < "$RUN/plan.json" | rlib write-stream --path "$dir/roots.tar" > "$RUN/tar.dest"
  rc=$?
  lsha=$(cat "$RUN/tar.sha" 2>/dev/null); rsha=$(cat "$RUN/tar.dest" 2>/dev/null)
  { [ "$rc" = 0 ] && [ -n "$lsha" ] && [ "$lsha" = "$rsha" ]; } || die "roots backup failed or arrived different (sent '$lsha', stored '$rsha')"
  note "roots.tar stored: ${lsha%% *} bytes, sha256 matches"
  rsync "${cflags[@]}" -E "$HOME/.claude/" "$(dest_home_spec "$dir/claude/")" > "$RUN/claude-rsync.log" 2> "$RUN/claude-rsync.err"
  rc=$?
  [ "$rc" = 0 ] || die "copying ~/.claude to the backup failed (rc=$rc; see $RUN/claude-rsync.err)"
  note "backup complete: ~/$dir on the destination (never restored automatically)"
  flog "backup ok dir=$dir roots=$ROOTS_N"
}

do_seed() {
  need_dest
  local rc grc
  ensure_logdir; need_inventory; new_run seed
  lib plan --mode seed --run-dir "$RUN" --fleet-json "$LOGDIR/fleet.json"
  rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "planning the seed failed"
  gate_dest; grc=$?
  if [ "$rc" = 2 ] || [ "$grc" != 0 ]; then
    [ "$DRY" = 1 ] || refuse "seed refused (reasons above); nothing was copied"
    note "A real run would REFUSE (reasons above); listing anyway"
  fi
  roots_args
  run_rsync_roots seed || die "seed rsync failed"
  [ "$DRY" = 1 ] || printf '%s\n' "$RUN" > "$LOGDIR/last-seed.txt"
  if [ "$NO_NPM" = 0 ]; then
    if [ "$DRY" = 1 ]; then
      lib npm-dirs --plan "$RUN/plan.json" | rlib npm-ci --dry-run
    else
      lib npm-dirs --plan "$RUN/plan.json" | rlib npm-ci
    fi
  fi
  flog "seed dry=$DRY roots=$ROOTS_N"
  [ "$DRY" = 1 ] && { [ "$rc" = 2 ] || [ "$grc" != 0 ]; } && return 2
  return 0
}

do_final() {
  local rc grc src prc refused=0
  if [ "$DRY" = 0 ] && [ "${FLEET_DOCKER_OK:-}" != 1 ]; then
    refuse "final needs FLEET_DOCKER_OK=1: set it only after the owner confirms Docker has moved off the destination"
  fi
  need_dest
  ensure_logdir; need_inventory; new_run final
  if [ "$DRY" = 1 ]; then
    lib plan --mode final --run-dir "$RUN" --fleet-json "$LOGDIR/fleet.json" --only "$ONLY" --dry-run
  else
    lib plan --mode final --run-dir "$RUN" --fleet-json "$LOGDIR/fleet.json" --only "$ONLY"
  fi
  rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "planning final failed"
  [ -f "$RUN/plan.json" ] || die "planning final wrote no plan"
  gate_dest; grc=$?
  { [ "$rc" = 2 ] || [ "$grc" != 0 ]; } && refused=1
  if [ "$refused" = 1 ]; then
    [ "$DRY" = 1 ] || refuse "final refused (reasons above); nothing was copied"
    note "A real run would REFUSE (reasons above); listing what it would copy anyway"
  fi
  roots_args
  run_rsync_roots final || die "final rsync failed; re-run final once the cause is fixed (it is re-runnable)"
  note "chat state for $(json_get "$RUN/plan.json" 'len([s for s in d["sids"] if s["state"]])') chat(s)$([ "$DRY" = 1 ] && echo ' (dry run: checked, not placed)')"
  if [ "$DRY" = 1 ]; then
    lib pack-state < "$RUN/plan.json" | rlib place-state --ts "$TS" --host "$HOST_S" --dry-run > "$RUN/state.json"
    prc=("${PIPESTATUS[@]}")
  else
    lib pack-state < "$RUN/plan.json" | rlib place-state --ts "$TS" --host "$HOST_S" > "$RUN/state.json"
    prc=("${PIPESTATUS[@]}")
  fi
  src="${prc[1]}"
  [ "$src" = 2 ] || [ "${prc[0]}" = 0 ] || die "packing the chat state failed"
  "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("state: %d placed, %d would be placed, %d already identical, %d conflict(s), merges %s, %d history/ledger line(s) appended" % (d["placed"], d["would_place"], d["same"], len(d["conflicts"]), d["merge"], d["appended_lines"]))' "$RUN/state.json" >&2 2>/dev/null
  [ "$src" = 2 ] && refuse "a chat file already exists on the destination with different content; nothing of the state was placed (see $RUN/state.json)"
  [ "$src" = 0 ] || die "placing the chat state failed (rc=$src)"
  if [ "$DRY" = 1 ]; then
    flog "final dry run refused=$refused"
    [ "$refused" = 1 ] && return 2
    return 0
  fi
  printf '%s\n' "$RUN" > "$LOGDIR/last-final.txt"
  flog "final ok run=$(basename "$RUN") only=${ONLY:-all}"
  note "final done. Next: $PROG verify"
}

last_run() {  # last_run -> prints the run folder verify/land work on
  local f
  for f in "$LOGDIR/last-final.txt" "$LOGDIR/last-seed.txt"; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  return 1
}

do_verify() {
  need_dest
  local rc
  ensure_logdir
  RUN=$(last_run) || refuse "nothing to verify yet: run seed or final first"
  [ -f "$RUN/plan.json" ] || refuse "the last run's plan is missing ($RUN)"
  note "verify: hashing every file of $(json_get "$RUN/plan.json" 'len(d["roots"])') root(s) on both Macs (this takes a while)"
  ( umask 077; lib manifest < "$RUN/plan.json" > "$RUN/source.manifest.gz" ) || die "manifest on this Mac failed"
  ( umask 077; rlib manifest --dest --fsck < "$RUN/plan.json" > "$RUN/dest.manifest.gz" ) || die "manifest on the destination failed"
  ( umask 077; lib compare "$RUN/source.manifest.gz" "$RUN/dest.manifest.gz" --plan "$RUN/plan.json" > "$RUN/verify-files.json" ) || die "comparing manifests failed"
  ( umask 077; lib state-digest < "$RUN/plan.json" | rlib state-check > "$RUN/verify-state.json" ) || die "checking the chat state failed"
  lib receipt --run-dir "$RUN"
  rc=$?
  if [ "$DRY" = 0 ]; then
    mkdir -p "$LOGDIR/receipts" && chmod 700 "$LOGDIR/receipts"
    cp "$RUN/verify.json" "$LOGDIR/receipts/$(basename "$RUN")-verify.json" && chmod 600 "$LOGDIR/receipts/$(basename "$RUN")-verify.json"
    rlib write-receipt --name "$(basename "$RUN")-verify.json" < "$RUN/verify.json" > /dev/null || note "could not store the receipt on the destination"
  fi
  flog "verify run=$(basename "$RUN") rc=$rc"
  return "$rc"
}

do_land() {
  need_dest
  ensure_logdir
  [ -f "$LOGDIR/last-final.txt" ] || refuse "nothing to land: run final first"
  RUN=$(cat "$LOGDIR/last-final.txt")
  [ -f "$RUN/verify.json" ] || refuse "run '$PROG verify' after the last final before landing"
  [ "$(json_get "$RUN/verify.json" 'd.get("ok") is True')" = True ] || refuse "the last verify found mismatches; fix them, re-run final + verify, then land"
  if [ "$DRY" = 1 ]; then
    lib land-request --run-dir "$RUN" | rlib land-dest --dry-run > "$RUN/land-dry.json" || die "land (dry run) failed"
    note "dry run: would land $(json_get "$RUN/land-dry.json" 'len(d["sids"])') chat(s) and record $(json_get "$RUN/land-dry.json" 'len(d["roots"])') root fingerprint(s)"
    return 0
  fi
  ( umask 077; lib land-request --run-dir "$RUN" | rlib land-dest > "$RUN/land.json" ) || die "landing on the destination failed"
  lib land-local --run-dir "$RUN" --dest "$FLEET_DEST" || die "recording the landing here failed"
  flog "land run=$(basename "$RUN")"
  note "landed. Next: $PROG resume-list"
}

do_resume_list() { lib resume-list; }

do_rollback() {
  need_dest
  local sid expect
  ensure_logdir
  [ -n "$ARG_SID" ] || refuse "rollback needs a session id"
  sid=$(lib resolve-only "$ARG_SID" --fleet-json "$LOGDIR/fleet.json") || exit 2
  expect=$(lib rollback-local --sid "$sid" --expect-only) || exit 2
  if [ "$DRY" = 1 ]; then
    rlib rollback-dest --sid "$sid" --expect "$expect" --dry-run > /dev/null || exit $?
    note "dry run: chat ${sid:0:8} can be rolled back (unchanged on the destination)"
    return 0
  fi
  rlib rollback-dest --sid "$sid" --expect "$expect" > /dev/null || exit $?
  lib rollback-local --sid "$sid"
  flog "rollback sid=$sid"
}

case "$CMD" in
  inventory) do_inventory ;;
  dest-check) do_dest_check ;;
  dest-setup) do_dest_setup ;;
  backup) do_backup ;;
  seed) do_seed ;;
  final) do_final ;;
  verify) do_verify ;;
  land) do_land ;;
  resume-list) do_resume_list ;;
  rollback) do_rollback ;;
  -h | --help | help) usage ;;
  *) refuse "unknown subcommand '$CMD' (inventory|dest-check|dest-setup|backup|seed|final|verify|land|resume-list|rollback)" ;;
esac
