#!/usr/bin/env bash
# 27 - fleet-move.sh copies a repo root whole, leaving out ONLY untracked/ignored machine-bound
# state and rebuildable heavy dirs (plan rule 1), and refuses roots that are a home (rule 2).
# Drives the REAL fleet-move.sh (inventory -> seed -> verify) with the destination side run locally
# (FLEET_TEST_DEST_HOME + FLEET_TEST_DEST_PREFIX, dev gate only) and the REAL openrsync.
#
#   E1 travels: tracked dist/app.js, tracked deno.lock (a *.lock never-name, but tracked), a tracked
#      transferred-log.md, branch resumed-x (a resumed-* never-name inside .git), ignored .env,
#      untracked yarn.lock (lockfile allowlist), untracked tmp/notes.md, an untracked symlink.
#   E2 left out: untracked node_modules/, an ignored file under tracked dist/, untracked foo.lock,
#      untracked tmp/resumed-abc, a socket, .git/index.lock.
#   E3 verify on the copy: 0 mismatches and git fingerprints equal (branch list, HEAD, status).
#   E4 negative control: a tracked file edited on the destination makes verify exit 1, and the
#      mismatch line names the root and a path HASH, never the filename.
#   E5 rule 2: an alias home itself, and /, as an extra root are refused by inventory (exit 2).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
FLEET="$TX_REPO/scripts/transfer/fleet-move.sh"
[ -x "$FLEET" ] || { echo "INFRA: fleet-move.sh missing or not executable at $FLEET" >&2; exit 3; }
command -v rsync >/dev/null 2>&1 || { echo "INFRA: rsync missing" >&2; exit 3; }

SANDBOX=$(tx_sandbox 27)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(cd -P "$SANDBOX" && pwd -P)

USERS="$SANDBOX/users"; ALIAS="$USERS/omid-a"; SRC="$SANDBOX/src-home"
DHOME="$SANDBOX/dest-home"; DPRE="$SANDBOX/dest-root"
mkdir -p "$ALIAS/Developer" "$SRC/.claude" "$DHOME/.claude" "$DPRE"
printf 'alias_of=%s\n' "$(id -un)" > "$ALIAS/.home-alias-of"
export TX_TEST_ALIAS_HOMES_BASE="$USERS" FLEET_TEST_DEST_HOME="$DHOME" FLEET_TEST_DEST_PREFIX="$DPRE"
export FLEET_DEST="sandbox-dest"     # required (no default); unused in local-destination mode

ROOT="$ALIAS/Developer/proj"
tx_init_origin "$SANDBOX/origin.git" "$ROOT" >/dev/null
printf 'dist/\n.env\n' > "$ROOT/.gitignore"
mkdir -p "$ROOT/dist" "$ROOT/notes"
printf 'built and committed\n' > "$ROOT/dist/app.js"
printf '{"version": 3}\n' > "$ROOT/deno.lock"
printf 'a tracked file with a never-name\n' > "$ROOT/notes/transferred-log.md"
git -C "$ROOT" add .gitignore deno.lock notes/transferred-log.md
git -C "$ROOT" add -f dist/app.js
git -C "$ROOT" commit -q -m "tracked dist + deno.lock"
git -C "$ROOT" branch resumed-x
printf 'SECRET_NAME=value\n' > "$ROOT/.env"
printf 'ignored build cache\n' > "$ROOT/dist/build-cache.js"
mkdir -p "$ROOT/node_modules/pkg" "$ROOT/tmp"
printf 'module\n' > "$ROOT/node_modules/pkg/index.js"
printf 'runtime lock\n' > "$ROOT/foo.lock"
printf 'yarn lockfile\n' > "$ROOT/yarn.lock"
printf 'notes\n' > "$ROOT/tmp/notes.md"
printf 'marker\n' > "$ROOT/tmp/resumed-abc"
ln -s README.md "$ROOT/readme-link"
printf 'stale\n' > "$ROOT/.git/index.lock"
( cd "$ROOT/tmp" && python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('run.sock')" ) || { echo "INFRA: cannot create a socket" >&2; exit 3; }
[ -S "$ROOT/tmp/run.sock" ] || { echo "INFRA: socket fixture missing" >&2; exit 3; }

fleet() {  # fleet <args...> -> FO (stdout+stderr), FRC
  FO=$(HOME="$SRC" FLEET_EXTRA_ROOTS="${EXTRA:-$ROOT}" "$FLEET" "$@" 2>&1); FRC=$?
}

# --- inventory + seed + verify ------------------------------------------------------------------
fleet inventory
[ "$FRC" -eq 0 ] || { echo "INFRA: inventory failed: $FO" >&2; exit 3; }
fleet seed --no-npm
[ "$FRC" -eq 0 ] || { echo "INFRA: seed failed: $FO" >&2; exit 3; }
D="$DPRE$ROOT"

# --- E1 ---------------------------------------------------------------------------------------------
for f in dist/app.js deno.lock notes/transferred-log.md .env yarn.lock tmp/notes.md README.md; do
  [ -f "$D/$f" ] && [ "$(tx_sha "$D/$f")" = "$(tx_sha "$ROOT/$f")" ] || fail "E1: $f did not travel byte-identical"
done
[ "$(readlink "$D/readme-link" 2>/dev/null)" = "README.md" ] || fail "E1: the untracked symlink did not travel as a symlink"
[ -n "$(git -C "$D" branch --list resumed-x 2>/dev/null)" ] || fail "E1: branch resumed-x is missing on the copy"

# --- E2 ---------------------------------------------------------------------------------------------
for f in node_modules dist/build-cache.js foo.lock tmp/resumed-abc tmp/run.sock .git/index.lock; do
  [ -e "$D/$f" ] || [ -L "$D/$f" ] && fail "E2: $f travelled but must be left out"
done

# --- E3 ---------------------------------------------------------------------------------------------
fleet verify
[ "$FRC" -eq 0 ] || fail "E3: verify on a clean copy did not exit 0: $(printf '%s' "$FO" | tail -5 | tr '\n' '|')"
case "$FO" in *" 0 mismatch"*) ;; *) fail "E3: verify did not report 0 mismatches: $(printf '%s' "$FO" | tail -3 | tr '\n' '|')" ;; esac
[ "$(git -C "$D" rev-parse HEAD 2>/dev/null)" = "$(git -C "$ROOT" rev-parse HEAD)" ] || fail "E3: HEAD differs on the copy"

# --- E4 ---------------------------------------------------------------------------------------------
printf 'edited on the destination\n' >> "$D/notes/transferred-log.md"
fleet verify
[ "$FRC" -eq 1 ] || fail "E4: verify after a destination edit exited $FRC, expected 1"
case "$FO" in *"MISMATCH content"*"root=$ROOT"*) ;; *) fail "E4: no content mismatch naming the root: $(printf '%s' "$FO" | tail -4 | tr '\n' '|')" ;; esac
case "$FO" in *transferred-log*) fail "E4: a mismatch line printed the filename (rule 13)" ;; esac
grep -rq "transferred-log" "$SRC/.claude/logs/fleet/receipts" 2>/dev/null && fail "E4: a receipt holds the filename (rule 13)"

# --- E5 ---------------------------------------------------------------------------------------------
EXTRA="$ALIAS" fleet inventory
[ "$FRC" -eq 2 ] || fail "E5: an alias home as a root was not refused (rc=$FRC)"
case "$FO" in *"REFUSED $ALIAS"*"home folder"*) ;; *) fail "E5: refusal did not name the alias home: $FO" ;; esac
EXTRA="/" fleet inventory
[ "$FRC" -eq 2 ] || fail "E5: / as a root was not refused (rc=$FRC)"

ok_report "27-fleet-excludes" "tracked dist/deno.lock/never-named files, branch resumed-x, .env, yarn.lock and symlinks travel; untracked node_modules, ignored dist files, foo.lock, resumed-*, sockets and .git/index.lock stay; verify is 0 on the copy and 1 (path hash only) after a destination edit; home roots are refused"
