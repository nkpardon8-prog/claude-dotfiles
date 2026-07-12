#!/bin/bash
# test-stale-handoff-guard.sh — behavioral suite for stale-handoff-guard.sh.
# Drives the guard exactly as SessionStart does: stdin JSON {cwd, session_id}, stdout captured.
# Positive: an 8-day-old handoff-SHAPED un-tagged CLAUDE.local.md is QUARANTINED.
# Negative (all must be untouched + silent): fresh handoff; hand-authored un-tagged file;
# current-session SID-tagged; symlink; non-repo cwd; permission-denied archive dir.

set -u
GUARD="$HOME/.claude-dotfiles/scripts/hooks/stale-handoff-guard.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

mkrepo() {  # mkrepo <dir> — a minimal git repo the canonical-root helper resolves
  mkdir -p "$1" && git -C "$1" init -q 2>/dev/null
}

backdate() {  # backdate <file> <days>
  touch -t "$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "-$2 days" +%Y%m%d%H%M)" "$1"
}

run_guard() {  # run_guard <cwd> [sid] — real invocation shape: stdin JSON, bash <path>
  printf '{"cwd":"%s","session_id":"%s"}' "$1" "${2:-test-sid-000}" | bash "$GUARD" 2>/dev/null
}

T=$(mktemp -d "${TMPDIR:-/tmp}/shg-test.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# --- 1. POSITIVE: 8-day-old handoff-shaped un-tagged file -> quarantined ---
R="$T/pos"; mkrepo "$R"
printf '# Post-Compact Reference — old\nbody\n<!-- END-OF-HANDOFF schema=v1 sid=deadbeef nonce=x -->\n' > "$R/CLAUDE.local.md"
backdate "$R/CLAUDE.local.md" 8
out=$(run_guard "$R")
if [ ! -f "$R/CLAUDE.local.md" ] && ls "$R/.handoff-archive"/CLAUDE.local.stale-*.md >/dev/null 2>&1 \
   && printf '%s' "$out" | grep -q QUARANTINED; then
  ok "positive: 8-day handoff-shaped file quarantined with notice"
else
  bad "positive: 8-day handoff-shaped file quarantined with notice (out=$out)"
fi

# --- 2. NEGATIVE: fresh (1-day) handoff-shaped file -> untouched, silent ---
R="$T/fresh"; mkrepo "$R"
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=a nonce=b -->\n' > "$R/CLAUDE.local.md"
backdate "$R/CLAUDE.local.md" 1
out=$(run_guard "$R")
[ -f "$R/CLAUDE.local.md" ] && [ -z "$out" ] && ok "negative: fresh handoff untouched + silent" \
  || bad "negative: fresh handoff untouched + silent (out=$out)"

# --- 3. NEGATIVE: hand-authored un-tagged file (no fingerprint), 30 days old -> untouched ---
R="$T/hand"; mkrepo "$R"
printf '# My project notes\nJust instructions, no handoff markers.\n' > "$R/CLAUDE.local.md"
backdate "$R/CLAUDE.local.md" 30
out=$(run_guard "$R")
[ -f "$R/CLAUDE.local.md" ] && [ -z "$out" ] && ok "negative: hand-authored file untouched despite age" \
  || bad "negative: hand-authored file untouched despite age (out=$out)"

# --- 4. NEGATIVE: current session's SID-tagged handoff, 40 days old -> spared by GC ---
R="$T/cursid"; mkrepo "$R"
SID="livesid-1234"
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=b -->\n' "$SID" > "$R/CLAUDE.local.$SID.md"
backdate "$R/CLAUDE.local.$SID.md" 40
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=other nonce=b -->\n' > "$R/CLAUDE.local.othersid-99.md"
backdate "$R/CLAUDE.local.othersid-99.md" 40
out=$(run_guard "$R" "$SID")
if [ -f "$R/CLAUDE.local.$SID.md" ] && [ ! -f "$R/CLAUDE.local.othersid-99.md" ]; then
  ok "negative/GC: current-session handoff spared; 40-day foreign handoff GC'd"
else
  bad "negative/GC: current-session handoff spared; 40-day foreign handoff GC'd"
fi

# --- 5. NEGATIVE: symlinked CLAUDE.local.md -> untouched ---
R="$T/link"; mkrepo "$R"
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=a nonce=b -->\n' > "$R/real.md"
ln -s "$R/real.md" "$R/CLAUDE.local.md"
backdate "$R/real.md" 20
out=$(run_guard "$R")
[ -L "$R/CLAUDE.local.md" ] && ok "negative: symlink untouched" || bad "negative: symlink untouched"

# --- 6. NEGATIVE: non-repo cwd -> exits silently, nothing moved ---
R="$T/norepo"; mkdir -p "$R"
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=a nonce=b -->\n' > "$R/CLAUDE.local.md"
backdate "$R/CLAUDE.local.md" 30
out=$(run_guard "$R")
[ -f "$R/CLAUDE.local.md" ] && [ -z "$out" ] && ok "negative: non-repo cwd never quarantines" \
  || bad "negative: non-repo cwd never quarantines (out=$out)"

# --- 7. NEGATIVE: permission-denied archive dir -> file stays, no crash ---
R="$T/perm"; mkrepo "$R"
printf 'x\n<!-- END-OF-HANDOFF schema=v1 sid=a nonce=b -->\n' > "$R/CLAUDE.local.md"
backdate "$R/CLAUDE.local.md" 10
mkdir -p "$R/.handoff-archive"; chmod 500 "$R/.handoff-archive"
out=$(run_guard "$R"); rc=$?
chmod 700 "$R/.handoff-archive"
if [ "$rc" -eq 0 ] && [ -f "$R/CLAUDE.local.md" ]; then
  ok "negative: unwritable archive dir -> guard exits 0, file left in place"
else
  bad "negative: unwritable archive dir -> guard exits 0, file left in place (rc=$rc)"
fi

# --- 8. MEMORY.md cliff warning fires over threshold (isolated fake HOME layout not used;
#        instead verify the guard's grep/wc logic via a crafted root whose project dir exists) ---
R="$T/memwarn"; mkrepo "$R"
# Derive the project dir from the SAME canonical root the guard resolves (it canonicalizes
# /var/folders -> /private/var/folders etc.; encoding from the raw $R would miss).
CANON=$(cd "$R" && . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-locate.sh" 2>/dev/null && handoff_canonical_root)
memdir="$HOME/.claude/projects/$(printf '%s' "$CANON" | tr '/.' '--')/memory"
mkdir -p "$memdir"
{ for i in $(seq 1 95); do echo "- [entry $i](f$i.md) — hook"; done; } > "$memdir/MEMORY.md"
out=$(run_guard "$R")
printf '%s' "$out" | grep -q "injection cliff" && ok "memory-cliff warning fires at 95 entries" \
  || bad "memory-cliff warning fires at 95 entries (out=$out)"
rm -rf "$memdir" 2>/dev/null; rmdir "$(dirname "$memdir")" 2>/dev/null

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
