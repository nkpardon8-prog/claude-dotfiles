#!/usr/bin/env bash
# 27 - fleet-move.sh copies a repo root whole, leaving out ONLY untracked/ignored machine-bound
# state and rebuildable heavy dirs (plan rule 1), and refuses roots that are a home (rule 2).
# Drives the REAL fleet-move.sh (inventory -> seed -> verify) with the destination side run locally
# (FLEET_TEST_DEST_HOME + FLEET_TEST_DEST_PREFIX, dev gate only) and the REAL openrsync.
#
#   E0 seed --dry-run and backup --dry-run create nothing on the destination.
#   E1 travels: tracked dist/app.js, tracked deno.lock (a *.lock never-name, but tracked), a tracked
#      transferred-log.md, branch resumed-x (a resumed-* never-name inside .git), ignored .env,
#      untracked yarn.lock (lockfile allowlist), untracked tmp/notes.md, an untracked symlink.
#   E2 left out: untracked node_modules/, an ignored file under tracked dist/, untracked foo.lock,
#      untracked tmp/resumed-abc, a socket, .git/index.lock.
#   E3 verify on the copy: 0 mismatches and git fingerprints equal (branch list, HEAD, status).
#   E4 negative control: a tracked file edited on the destination makes verify exit 1, and the
#      mismatch line names the root and a path HASH, never the filename.
#   E5 rule 2: an alias home itself, and /, as an extra root are refused by inventory (exit 2).
#   E6 backup: ~/fleet-backup-<ts>/roots.tar holds tracked files and leaves out the same excludes;
#      .../claude holds ~/.claude minus the session registry and login files; the source is untouched.
#   E8 a stale .git/index.lock on the destination (excluded, so --delete keeps it) fails verify.
#   E9 rsync rc 23: failure when an unexplained error line exists (the /Users utimensat shape); passes
#      when the only lines are skipped sockets. rc 24 (vanished) passes for seed. PATH stub for rsync.
#   E7 rule 18: npm-dirs finds a launch folder with node_modules + package-lock.json, and npm-ci
#      --dry-run names it without installing.
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

printf '{"lockfileVersion": 3}\n' > "$ROOT/package-lock.json"
mkdir -p "$SRC/.claude/sessions" "$SRC/.claude/projects/p"
printf '{}\n' > "$SRC/.claude/sessions/1.json"; printf 'cred\n' > "$SRC/.claude/.credentials.json"
printf 'keep\n' > "$SRC/.claude/projects/p/keep.jsonl"

# --- inventory + seed + verify ------------------------------------------------------------------
fleet inventory
[ "$FRC" -eq 0 ] || { echo "INFRA: inventory failed: $FO" >&2; exit 3; }
fleet seed --no-npm --dry-run
[ "$FRC" -eq 0 ] || fail "E0: seed --dry-run failed: $(printf '%s' "$FO" | tail -3 | tr '\n' '|')"
[ -z "$(ls -A "$DPRE")" ] || fail "E0: seed --dry-run created something on the destination"
fleet backup --dry-run
[ "$FRC" -eq 0 ] || fail "E0: backup --dry-run failed: $(printf '%s' "$FO" | tail -3 | tr '\n' '|')"
[ -z "$(ls -d "$DHOME"/fleet-backup-* 2>/dev/null)" ] || fail "E0: backup --dry-run created a folder on the destination"
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

# --- E6 ---------------------------------------------------------------------------------------------
fleet inventory
SRC_BEFORE=$(cd "$ROOT" && find . -type f ! -path './.git/*' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256)
fleet backup
[ "$FRC" -eq 0 ] || fail "E6: backup failed: $(printf '%s' "$FO" | tail -4 | tr '\n' '|')"
BK=$(ls -d "$DHOME"/fleet-backup-* 2>/dev/null | head -1)
if [ -z "$BK" ]; then
  fail "E6: no backup folder on the destination"
else
  LIST=$(tar -tf "$BK/roots.tar" 2>/dev/null)
  case "$LIST" in *"proj/dist/app.js"*) ;; *) fail "E6: roots.tar lacks a tracked file" ;; esac
  case "$LIST" in *"proj/node_modules"*|*"foo.lock"*) fail "E6: roots.tar holds an excluded path" ;; esac
  [ -f "$BK/claude/projects/p/keep.jsonl" ] || fail "E6: ~/.claude content missing from the backup"
  [ -e "$BK/claude/sessions" ] && fail "E6: the session registry was backed up"
  [ -e "$BK/claude/.credentials.json" ] && fail "E6: a login file was backed up"
fi
[ "$(cd "$ROOT" && find . -type f ! -path './.git/*' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256)" = "$SRC_BEFORE" ] || fail "E6: backup changed the source root"

# --- E8 ---------------------------------------------------------------------------------------------
cp -p "$ROOT/notes/transferred-log.md" "$D/notes/transferred-log.md"
fleet verify
[ "$FRC" -eq 0 ] || fail "E8: precondition: verify is not clean after restoring: $(printf '%s' "$FO" | tail -3 | tr '\n' '|')"
printf 'stale\n' > "$D/.git/index.lock"
fleet verify
[ "$FRC" -eq 1 ] && case "$FO" in *"stray-git-lock-on-dest"*) true ;; *) false ;; esac || fail "E8: a stale lock on the destination did not fail verify (rc=$FRC)"
rm -f "$D/.git/index.lock"

# --- E9 ---------------------------------------------------------------------------------------------
STUB="$SANDBOX/stubbin"; mkdir -p "$STUB"
stub() { printf '#!/bin/sh\nprintf "%%s\\n" "%s" >&2\nexit %s\n' "$1" "$2" > "$STUB/rsync"; chmod +x "$STUB/rsync"; }
sfleet() { FO=$(PATH="$STUB:$PATH" HOME="$SRC" FLEET_EXTRA_ROOTS="$ROOT" "$FLEET" "$@" 2>&1); FRC=$?; }
stub 'rsync: error: Users: utimensat (2): Operation not permitted' 23
sfleet seed --no-npm
[ "$FRC" -eq 1 ] || fail "E9: rc 23 with an unexplained error did not fail seed (rc=$FRC): $FO"
stub 'skipping non-regular file x.sock' 23
sfleet seed --no-npm
[ "$FRC" -eq 0 ] || fail "E9: rc 23 with only skipped sockets failed seed (rc=$FRC): $FO"
stub 'file has vanished: y' 24
sfleet seed --no-npm
[ "$FRC" -eq 0 ] || fail "E9: rc 24 vanished failed seed (rc=$FRC): $FO"
rm -f "$STUB/rsync"

# --- E7 ---------------------------------------------------------------------------------------------
printf '{"sids": [{"sid": "s", "cwd": "%s"}]}' "$ROOT" > "$SANDBOX/npm-plan.json"
LIBPY="$TX_REPO/scripts/transfer/fleet_lib.py"
NO=$(HOME="$SRC" python3 "$LIBPY" npm-dirs --plan "$SANDBOX/npm-plan.json" | HOME="$DHOME" python3 "$LIBPY" npm-ci --dry-run 2>&1)
case "$NO" in *"npm ci --legacy-peer-deps in $ROOT"*|*"NPM MISSING: npm ci --legacy-peer-deps in $ROOT"*) ;; *) fail "E7: npm-ci --dry-run did not name the launch folder: $NO" ;; esac
[ -e "$DPRE$ROOT/node_modules" ] && fail "E7: a dry run created node_modules"

ok_report "27-fleet-excludes" "tracked dist/deno.lock/never-named files, branch resumed-x, .env, yarn.lock and symlinks travel; untracked node_modules, ignored dist files, foo.lock, resumed-*, sockets and .git/index.lock stay; verify is 0 on the copy and 1 (path hash only) after a destination edit; home roots are refused"
