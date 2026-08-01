#!/bin/bash
# handoff-smoke-check.sh <handoff-file> [root]
#
# ADVISORY validator for a freshly written /pre-compact handoff: verifies that
# file paths the handoff points at actually exist, so a handoff cannot silently
# reference never-written files ("the handoff lie"). Scope:
#   - every path-shaped token in the "## Next Action" section
#   - every path-shaped token on "[in progress]" lines in "## Build Plan"
#
# Path-shaped token = contains a '/' AND matches  [A-Za-z0-9_./~-]+\.[A-Za-z]{1,5}
# (optionally ':<line>'). Relative tokens resolve against [root] (default: the
# handoff file's directory - the canonical root by construction).
#
# CONTRACT: advisory only - ALWAYS exits 0. On misses it appends a
# "## Smoke Check" section (WARN lines) to the handoff itself so the next
# session sees the discrepancy. Idempotent: an existing "## Smoke Check"
# section is replaced, never duplicated. bash 3.2 compatible.

set -u
HANDOFF="${1:?usage: handoff-smoke-check.sh <handoff-file> [root]}"
ROOT="${2:-$(cd "$(dirname "$HANDOFF")" && pwd)}"

[ -f "$HANDOFF" ] || { echo "handoff-smoke-check: no such file: $HANDOFF" >&2; exit 0; }

WARNS=$(python3 - "$HANDOFF" "$ROOT" <<'PYEOF'
import os, re, sys
handoff, root = sys.argv[1], sys.argv[2]
s = open(handoff, encoding='utf-8', errors='replace').read()

def section(name):
    m = re.search(r'^## ' + re.escape(name) + r'\s*$(.*?)(?=^## |\Z)', s, re.M | re.S)
    return m.group(1) if m else ''

targets = []
na = section('Next Action')
if na:
    targets += [('Next Action', t) for t in re.findall(r'[A-Za-z0-9_./~-]+/[A-Za-z0-9_.~-]+\.[A-Za-z]{1,5}(?::\d+)?', na)]
bp = section('Build Plan')
for line in bp.splitlines():
    if '[in progress]' in line:
        targets += [('Build Plan in-progress', t) for t in re.findall(r'[A-Za-z0-9_./~-]+/[A-Za-z0-9_.~-]+\.[A-Za-z]{1,5}(?::\d+)?', line)]

seen = set()
for where, tok in targets:
    path = tok.split(':')[0]
    if path in seen: continue
    seen.add(path)
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(root, p)
    if not os.path.exists(p):
        print(f"WARN [{where}] referenced path does not exist: {tok}")
PYEOF
)

# Replace any prior Smoke Check section, then append the fresh one (before the
# END-OF-HANDOFF marker if present, else at EOF) only when there are warnings.
python3 - "$HANDOFF" <<PYEOF
import re, sys
handoff = sys.argv[1]
warns = """$WARNS""".strip()
s = open(handoff, encoding='utf-8', errors='replace').read()
s = re.sub(r'^## Smoke Check\s*$.*?(?=^## |^<!-- END-OF-HANDOFF|\Z)', '', s, flags=re.M | re.S)
if warns:
    block = "## Smoke Check\n(advisory - written by handoff-smoke-check.sh; a listed path was referenced above but does not exist on disk)\n" + warns + "\n\n"
    m = re.search(r'^<!-- END-OF-HANDOFF', s, re.M)
    if m:
        s = s[:m.start()] + block + s[m.start():]
    else:
        s = s.rstrip('\n') + '\n\n' + block
open(handoff, 'w', encoding='utf-8').write(s)
PYEOF

[ -n "$WARNS" ] && printf '%s\n' "$WARNS" >&2
exit 0
