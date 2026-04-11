---
description: "Export a construction estimate to a professional GC-submission-ready PDF. Three detail levels: summary, standard (default — protects competitive info), detailed. Accepts output from /plan2bid:run or any estimate data."
argument-hint: "[path to estimate JSON, or 'export last estimate as PDF']"
---

# Export Estimate to PDF

## Locate estimate data

1. If the user provides a JSON file path, use it directly as `$FILE`.
2. If estimate data is in conversation (from `/plan2bid:run` or pasted), write it as JSON to `/tmp/plan2bid_estimate_<timestamp>.json`.
3. If "last estimate", find the most recent `.json` in `~/Desktop/Projects/Plan2BidAgent/output/` or cwd. Confirm before proceeding.
If no data found, stop and ask.

## Determine detail level

Ask the user which level (default to **standard** if unspecified):
- **summary** — totals by trade only, no line items
- **standard** — line items with lump-sum pricing, no unit rates or markup breakdown
- **detailed** — full unit rates, markup percentages, and cost breakdown

**If detailed is selected, warn first:** "This exposes unit rates and markup breakdown. Standard mode protects competitive info." Only proceed after explicit confirmation.

## Embed company info

Read profile files from `~/plan2bid-profile/` (company name, logo, license, contact). Merge into the estimate JSON under a `"company"` key. Write enriched JSON back to `$FILE`.

## Generate the PDF

```
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python ~/Desktop/Projects/Plan2BidAgent/scripts/generate_pdf.py --input $FILE --output $OUTPUT --detail $LEVEL
```

Note: If `~/Desktop/Projects/Plan2BidAgent/scripts/` does not exist, use the Read tool directly on PDF files instead. The Read tool handles PDFs natively for text extraction. For vision-based analysis of drawings, read the PDF as an image file.

Default `$OUTPUT` to `./estimate.pdf`. `$LEVEL` is `summary`, `standard`, or `detailed`.
If the script fails, show the full error and suggest fixes.

## Return result

Report the absolute path to the generated `.pdf` file.
