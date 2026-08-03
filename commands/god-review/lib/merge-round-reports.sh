#!/bin/bash
# merge-round-reports.sh - derive tmp/god-review/report.md from the per-round
# tmp/god-review/report-round-N.md files written by Phase 2e STEP 4.
#
# Two modes, selected by GOD_REVIEW_MERGE_ROUNDS:
#
#   unset|false  CURRENT mode. report.md = a copy of report-round-$ROUND.md.
#                This is what /god-review's fix loop needs: Phase 3 acts on the
#                round it just reviewed, and must not be handed earlier rounds'
#                already-fixed findings.
#
#   true         UNION mode. report.md = hash-deduplicated union of every
#                report-round-*.md. This is what /god-report --rounds N needs:
#                N independent passes de-noised into one list, with findings
#                seen in 2+ rounds tagged "(consistent across rounds)".
#
# Dedup key is the pipeline-wide finding hash:
#   sha256(file | line_range_rounded_to_5 | category)
# read from each finding's "**Location**:" and "**Category**:" lines - the same
# triple compute_finding_hash() in env-helpers.sh uses, so a finding has one
# identity across 2e STEP 1, this merge, and Phase 3a's replay check.
#
# Env:
#   WORKDIR                  repo root (defaults to git toplevel / pwd)
#   ROUND                    current round number (default 1)
#   GOD_REVIEW_MERGE_ROUNDS  "true" for UNION mode
#
# bash 3.2 compatible. Writes atomically (.tmp -> mv). Never deletes a per-round file.

set -u

WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GRDIR="$WORKDIR/tmp/god-review"
ROUND="${ROUND:-1}"
MERGE="${GOD_REVIEW_MERGE_ROUNDS:-false}"

mkdir -p "$GRDIR"

CURRENT="$GRDIR/report-round-${ROUND}.md"

if [ "$MERGE" != "true" ]; then
  if [ ! -f "$CURRENT" ]; then
    echo "merge-round-reports: FAIL $CURRENT does not exist. Phase 2e STEP 4 must write the per-round report before STEP 5 runs." >&2
    exit 1
  fi
  cp "$CURRENT" "$GRDIR/report.md.tmp" && mv "$GRDIR/report.md.tmp" "$GRDIR/report.md"
  echo "merge-round-reports: CURRENT mode - report.md <- report-round-${ROUND}.md ($(grep -c '^### ' "$GRDIR/report.md" 2>/dev/null || echo 0) findings)"
  exit 0
fi

# --- UNION mode ---
ROUND_FILES=$(ls "$GRDIR"/report-round-*.md 2>/dev/null)
if [ -z "$ROUND_FILES" ]; then
  echo "merge-round-reports: FAIL no report-round-*.md files found in $GRDIR. Nothing to union." >&2
  exit 1
fi

python3 - "$GRDIR" << 'PYEOF'
import glob
import hashlib
import os
import re
import sys

grdir = sys.argv[1]

# Canonical section order, matching the Phase 2e STEP 4 template.
SECTIONS = [
    "Critical [must fix]",
    "Gaps [missing entirely]",
    "Important [should fix]",
    "Assumptions [verify these]",
    "Contradictions",
    "Minor [low priority]",
]


def round_num(path):
    m = re.search(r"report-round-(\d+)\.md$", path)
    return int(m.group(1)) if m else 0


files = sorted(glob.glob(os.path.join(grdir, "report-round-*.md")), key=round_num)


def norm_range(start, end):
    s, e = int(start), int(end)
    return "%d-%d" % ((s // 5) * 5, ((e + 4) // 5) * 5)


def finding_hash(body, heading):
    loc = re.search(
        r"\*\*Location\*\*:\s*`?([^`\s:]+):(\d+)(?:-(\d+))?`?", body)
    cat = re.search(r"\*\*Category\*\*:\s*([^\n]+)", body)
    if loc:
        f = loc.group(1)
        lr = norm_range(loc.group(2), loc.group(3) or loc.group(2))
    else:
        # No parseable location: fall back to the heading text so the finding
        # still dedupes against itself across rounds instead of collapsing all
        # location-less findings into one bucket.
        f, lr = "unknown:" + heading.strip()[:80], "0-0"
    c = cat.group(1).strip() if cat else "uncategorized"
    return hashlib.sha256(("%s|%s|%s" % (f, lr, c)).encode("utf-8")).hexdigest()


# section -> [ (hash, heading, body) ]  in first-seen order
collected = {s: [] for s in SECTIONS}
seen = {}          # hash -> set of round numbers
placement = {}     # hash -> (section, index)

for path in files:
    rnd = round_num(path)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    section = None
    for chunk in re.split(r"(?m)^(?=## )", text):
        m = re.match(r"## (.+)", chunk)
        if not m:
            continue
        section = m.group(1).strip()
        if section not in collected:
            continue  # Meta-Review Notes, HUMAN_GATE_QUEUE, headers - not merged
        for fblk in re.split(r"(?m)^(?=### )", chunk)[1:]:
            lines = fblk.split("\n", 1)
            heading = lines[0]
            body = lines[1] if len(lines) > 1 else ""
            # Drop the source section's trailing horizontal rule; STEP 5 emits
            # its own separators, and keeping these strands "---" mid-section.
            body = re.sub(r"(?:\n\s*-{3,}\s*)+\s*$", "", body)
            h = finding_hash(fblk, heading)
            if h in seen:
                seen[h].add(rnd)
                continue
            seen[h] = {rnd}
            placement[h] = (section, len(collected[section]))
            collected[section].append([h, heading, body])

# Tag anything that survived 2+ rounds.
multi = 0
for sec, items in collected.items():
    for item in items:
        if len(seen[item[0]]) >= 2:
            multi += 1
            if "(consistent across rounds)" not in item[1]:
                item[1] = item[1].rstrip() + " (consistent across rounds)"

total = sum(len(v) for v in collected.values())
out = []
out.append("# god-review Report (union of %d round%s)\n" % (len(files), "" if len(files) == 1 else "s"))
out.append("**Rounds merged**: %s" % ", ".join(str(round_num(p)) for p in files))
out.append("**Total findings after union-dedup**: %d" % total)
out.append("**Findings seen in 2+ rounds**: %d (tagged `(consistent across rounds)`)\n" % multi)
out.append("---\n")
for sec in SECTIONS:
    out.append("## %s\n" % sec)
    if not collected[sec]:
        out.append("(none)\n")
    for _h, heading, body in collected[sec]:
        out.append(heading)
        out.append(body.rstrip() + "\n")
    out.append("---\n")
out.append("## Meta-Review Notes")
out.append("- Union of %d independent rounds, deduplicated by sha256(file|line_range/5|category)." % len(files))
out.append("- Per-round reports retained at tmp/god-review/report-round-N.md.")

tmp = os.path.join(grdir, "report.md.tmp")
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
os.replace(tmp, os.path.join(grdir, "report.md"))
print("merge-round-reports: UNION mode - %d round(s), %d unique findings, %d consistent across rounds"
      % (len(files), total, multi))
PYEOF
