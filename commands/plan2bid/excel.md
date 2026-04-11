---
description: "Export a construction estimate to a styled Excel workbook — Summary tab plus per-trade breakdown tabs. Accepts output from /plan2bid:run or any estimate data."
argument-hint: "[path to estimate JSON, or 'export last estimate']"
---

# Export Estimate to Excel

## Locate estimate data

1. If the user provides a path to a JSON file, use that directly as `$FILE`.
2. If estimate data exists in the current conversation (from a prior `/plan2bid:run` or pasted by the user), structure it as valid JSON and write it to a temp file: `/tmp/plan2bid_estimate_<timestamp>.json`. Use that as `$FILE`.
3. If the user says "last estimate", look for the most recent `.json` file in `~/Desktop/Projects/Plan2BidAgent/output/` or the current working directory. Confirm the file with the user before proceeding.

If no estimate data can be found, stop and ask the user to provide it.

## Validate the JSON

Read `$FILE` and confirm it contains at minimum:
- A project name or identifier
- At least one line item with description, quantity, unit, and unit price

If fields are missing, warn the user and ask whether to proceed with defaults or fix the data first.

## Generate the workbook

Determine an output path. Default to `./estimate.xlsx` in the current directory unless the user specifies otherwise.

Run:

```
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python ~/Desktop/Projects/Plan2BidAgent/scripts/generate_excel.py --input $FILE --output $OUTPUT
```

Note: If `~/Desktop/Projects/Plan2BidAgent/scripts/` does not exist, use the Read tool directly on PDF files instead. The Read tool handles PDFs natively for text extraction. For vision-based analysis of drawings, read the PDF as an image file.

If the script exits non-zero, show the full error output and suggest fixes.

## Return result

Report the absolute path to the generated `.xlsx` file so the user can open or share it.
