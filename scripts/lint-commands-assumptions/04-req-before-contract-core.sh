#!/usr/bin/env bash
# 04 - A1..A6: req_before - a gated literal's FIRST occurrence must precede
#      '<!-- CONTRACT-CORE-END -->', and the check fails CLOSED when it cannot be decided.
#
# Load-bearing because presence is not the property that matters. After every compaction
# the harness re-injects an invoked skill's body HEAD-TRUNCATED at 20,000 chars.
# codex-review.md is ~57k and implement.md ~23k, so most of each file is invisible to a
# post-compaction agent. A launch register that drifts below the marker is present in the
# file, passes a plain grep, and is never read by the agent it exists to instruct - the
# textbook silent failure: nothing errors, the work just quietly serializes again.
#
# Offsets are counted in CHARACTERS, not bytes, mirroring lint-skill-size.sh's marker_pos,
# because the ceiling the marker approximates is itself a character count.
#
# A6 is the anti-tautology assertion: moving the marker DOWN keeps the check green, which
# is only possible if the comparison is relative (literal vs marker) rather than a
# hardcoded offset that would happen to pass today.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-change lint has no req_before at
# all - marker position was checked only by lint-skill-size.sh, and only for two other
# files).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "04-req-before-contract-core"
lc_baseline

MARK='<!-- CONTRACT-CORE-END -->'

# A1 - the marker moves ABOVE the gated literals (the realistic drift: someone adds a
# section and the core boundary creeps upward past the launch schedule).
lc_edit commands/codex-review.md "
m = '${MARK}'
s = s.replace(m, '', 1)
s = m + chr(10) + s"
lc_run 1 "A1 literal below a raised marker fails" "$FIX" "$CONTRACT"
lc_out_has "BELOW the marker" "A1"
lc_out_has "EXACTLY 6 tool calls" "A1"

# A2 - FAIL CLOSED: no marker at all means the position cannot be decided. Silence here
# would let a file lose its marker and keep its green, which is how the check dies quietly.
lc_restore
lc_edit commands/codex-review.md "
m = '${MARK}'
s = s.replace(m, '', 1)"
lc_run 1 "A2 missing marker fails closed" "$FIX" "$CONTRACT"
lc_out_has "lacks the '${MARK}' marker" "A2"

# A3 - FAIL CLOSED the other way: the marker is present but the literal is gone. Both the
# presence rule and the position rule must speak, so a reader is not left thinking the
# literal merely moved.
lc_restore
lc_edit commands/codex-review.md "s = s.replace('NON-CODE TARGETS ONLY', 'non-code targets only')"
lc_run 1 "A3 missing literal fails the position check too" "$FIX" "$CONTRACT"
lc_out_has "contract-core position check" "A3"

# A4 - implement.md: the register line is MOVED below the marker while the file keeps two
# lines carrying the literal. req's min-count of 2 is still satisfied - only req_before can
# see this, which is exactly why it exists.
lc_restore
lc_edit commands/implement.md "
lines = s.split(chr(10))
i = [k for k, l in enumerate(lines) if 'in a SINGLE message' in l][0]
moved = lines.pop(i)
lines.append(moved)
s = chr(10).join(lines)"
lc_run 1 "A4 register moved below the marker fails despite min-count holding" "$FIX" "$CONTRACT"
lc_out_has "commands/implement.md" "A4"
lc_out_has "BELOW the marker" "A4"
lc_out_lacks "need >=2" "A4 min-count still satisfied"

# A5 - pristine is green (the live files really do satisfy the position rule today).
lc_restore
lc_run 0 "A5 pristine fixture passes every position check" "$FIX" "$CONTRACT"

# A6 - the comparison is RELATIVE: pushing the marker to the end of the file keeps it green.
lc_edit commands/codex-review.md "
m = '${MARK}'
s = s.replace(m, '', 1)
s = s + chr(10) + m + chr(10)"
lc_run 0 "A6 marker lowered stays green (relative, not a fixed offset)" "$FIX" "$CONTRACT"

lc_finish '{"below_marker":"exit 1","missing_marker":"exit 1 (fail-closed)","missing_literal":"exit 1 (fail-closed)","offsets":"characters","comparison":"relative to the marker"}' \
  "6 assertions (req_before position rule + both fail-closed paths)"
