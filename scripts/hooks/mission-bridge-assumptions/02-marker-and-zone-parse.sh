#!/usr/bin/env bash
# 02 — marker last-line parse + nonce-qualified zone fence + hash determinism.
#
# Proves the durable-spine PARSE robustness (mission_verify / mission_read_zone /
# _mission_plan_hash, plan Key Pseudocode + On-disk contract):
#   marker: grep -nE '^<!-- MISSION schema=v1 ' | tail -1   (LAST line, NOT head -1)
#   zone:   open  <!-- MZONE:PLAN n=<nonce8> -->
#           close <!-- /MZONE:PLAN n=<nonce8> -->   (nonce-qualified, column-0)
#   hash:   shasum -a 256 of the extracted PLAN zone, first 16 hex
#
# Load-bearing assumption: pasted/quoted content in the PLAN BODY cannot
# (a) be mistaken for the canonical last-line marker, (b) truncate the zone via a
# bare or stale-nonce close fence, or (c) destabilize plan_hash. Any of these = a
# silent corruption / data-loss event in the zero-loss spine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "02-marker-and-zone-parse"

NONCE="a1b2c3d4"                # the file's LIVE nonce8
F="$ATEST_DIR/MISSION.test.md"

# A file whose PLAN body adversarially contains BOTH a pseudo-marker line and a
# bare close-fence and a STALE-but-valid-format wrong-nonce close-fence.
cat > "$F" <<EOF
# MISSION test
<!-- MZONE:PLAN n=${NONCE} -->
Step 1: do the thing.
A user pasted this line that looks like a marker:
<!-- MISSION schema=v1 sid=evil nonce=deadbeef plan_hash=0000000000000000 -->
And pasted a bare close fence (no live nonce):
<!-- /MZONE:PLAN -->
And pasted a stale close fence with a wrong-but-valid-format nonce:
<!-- /MZONE:PLAN n=99999999 -->
Step 2: the REAL plan continues past all the spoofs.
<!-- /MZONE:PLAN n=${NONCE} -->
<!-- MZONE:DURABLE NOTES n=${NONCE} -->
note one
<!-- /MZONE:DURABLE NOTES n=${NONCE} -->
<!-- MISSION schema=v1 sid=test nonce=${NONCE} plan_hash=deadbeefdeadbeef -->
EOF

# --- A1: last-line marker parse selects the CANONICAL marker, not the body one
marker_line="$(grep -nE '^<!-- MISSION schema=v1 ' "$F" | tail -1)"
marker_sid="$(printf '%s' "$marker_line" | sed -n 's/.*sid=\([^ ]*\).*/\1/p')"
[ "$marker_sid" = "test" ]
atest_assert "A1" "$?" "last-line marker parse picked sid='$marker_sid' (want 'test') — a body pseudo-marker fooled the parser."

# --- A1b: head -1 would have been WRONG (proves last-line discipline matters) -
head_line="$(grep -nE '^<!-- MISSION schema=v1 ' "$F" | head -1)"
head_sid="$(printf '%s' "$head_line" | sed -n 's/.*sid=\([^ ]*\).*/\1/p')"
[ "$head_sid" = "evil" ]   # confirms head-1 IS fooled -> last-line is load-bearing
atest_assert "A1b" "$?" "expected head-1 to be fooled (sid='evil') to prove tail-1 is necessary; got '$head_sid'."

# --- A2: marker count — canonical must be the LAST non-empty line -------------
# mission_verify counts ALL marker-anchored lines; the canonical one MUST be last.
last_nonempty="$(grep -nvE '^[[:space:]]*$' "$F" | tail -1 | sed 's/^[0-9]*://')"
case "$last_nonempty" in
  '<!-- MISSION schema=v1 sid=test '*) _rc=0 ;;
  *) _rc=1 ;;
esac
atest_assert "A2" "$_rc" "canonical marker is not the file's last non-empty line — mission_verify would flag corruption (or miss it)."

# --- A3: nonce-qualified zone extraction ignores bare + stale-nonce closes ----
# Extract PLAN zone bounded by the LIVE-nonce open/close pair. The close must be
# the live-nonce close (column-0, exact nonce), NOT the bare or wrong-nonce ones.
open_ln="$(grep -nE "^<!-- MZONE:PLAN n=${NONCE} -->$" "$F" | head -1 | cut -d: -f1)"
close_ln="$(grep -nE "^<!-- /MZONE:PLAN n=${NONCE} -->$" "$F" | head -1 | cut -d: -f1)"
# zone body = strictly-between lines
zone="$(sed -n "$((open_ln+1)),$((close_ln-1))p" "$F")"
# The REAL Step 2 line lives AFTER the bare/stale closes; it MUST be inside the zone.
printf '%s\n' "$zone" | grep -q 'Step 2: the REAL plan continues past all the spoofs.'
atest_assert "A3" "$?" "nonce-fence extraction truncated the PLAN at a bare/stale close fence — real plan content was lost from the zone."

# --- A3b: a NAIVE bare-fence parser WOULD truncate (negative control) ---------
bare_close_ln="$(grep -nE '^<!-- /MZONE:PLAN' "$F" | head -1 | cut -d: -f1)"   # first ANY close
naive_zone="$(sed -n "$((open_ln+1)),$((bare_close_ln-1))p" "$F")"
printf '%s\n' "$naive_zone" | grep -q 'Step 2: the REAL plan continues past all the spoofs.' && _naive=0 || _naive=1
[ "$_naive" = "1" ]   # naive parser MUST lose Step 2 -> proves nonce-qualification matters
atest_assert "A3b" "$?" "a naive first-close parser did NOT truncate — the nonce-qualification test is vacuous (cannot go red)."

# --- A4: plan_hash determinism (shasum -a 256, first 16 hex) ------------------
command -v shasum >/dev/null 2>&1 || atest_infra "shasum not found (required for plan_hash)"
h1="$(printf '%s' "$zone" | shasum -a 256 | cut -c1-16)"
h2="$(printf '%s' "$zone" | shasum -a 256 | cut -c1-16)"
[ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "${#h1}" = "16" ]
atest_assert "A4" "$?" "shasum -a 256 first-16-hex not deterministic/16-wide (h1='$h1' h2='$h2') — plan_hash would be unstable."

# --- A4b: cross-tool equivalence ONLY if sha256sum is present (gated) ---------
if command -v sha256sum >/dev/null 2>&1; then
  h3="$(printf '%s' "$zone" | sha256sum | cut -c1-16)"
  [ "$h1" = "$h3" ]
  atest_assert "A4b" "$?" "shasum vs sha256sum disagree (shasum='$h1' sha256sum='$h3') — hash tool choice would matter across machines."
else
  echo "  (A4b skipped: sha256sum absent — implementation must standardize on shasum)" >&2
fi

atest_report
