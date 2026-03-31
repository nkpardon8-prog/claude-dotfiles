---
description: "Export a construction estimate to a professional GC-submission-ready PDF. Three detail levels: summary, standard (default — protects competitive info), detailed. Accepts output from /plan2bid:run or any estimate data."
argument-hint: "[path to estimate JSON, or 'export last estimate as PDF']"
---

# Export Estimate to PDF

## Locate estimate data

1. If the user provides a path to a JSON file, use that directly as `$FILE`.
2. If estimate data exists in the current conversation (from a prior `/plan2bid:run` or pasted by the user), structure it as valid JSON and write it to a temp file: `/tmp/plan2bid_estimate_<timestamp>.json`. Use that as `$FILE`.
3. If the user says "last estimate", look for the most recent `.json` file in `~/Desktop/Projects/Plan2BidAgent/output/` or the current directory. Confirm with the user before proceeding.

If no estimate data can be found, stop and ask the user to provide it.

## Determine detail level

Ask the user which detail level they want:
- **summary** — totals by trade only, no line items
- **standard** (default) — line items with lump-sum pricing, no unit rates or markup breakdown
- **detailed** — full unit rates, markup percentages, and cost breakdown

**If the user picks detailed, warn before proceeding:**
> "This exposes unit rates and markup breakdown. Standard mode protects competitive info."

Only continue with detailed after explicit confirmation.

## Embed company info

Read any profile files from `~/plan2bid-profile/` (company name, logo path, license number, contact info). Merge this data into the estimate JSON under a `"company"` key before calling the script. Write the enriched JSON back to `$FILE`.

## Generate the PDF

Run:

```
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python ~/Desktop/Projects/Plan2BidAgent/scripts/generate_pdf.py --input $FILE --output $OUTPUT --detail $LEVEL
```

Default `$OUTPUT` to `./estimate.pdf` unless the user specifies otherwise. `$LEVEL` is one of `summary`, `standard`, `detailed`.

If the script exits non-zero, show the full error and suggest fixes.

## Return result

Report the absolute path to the generated `.pdf` file.
