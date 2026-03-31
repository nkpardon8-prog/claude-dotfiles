---
description: "Side-by-side comparison of two construction estimates — flags missing items, quantity differences, pricing variances. Compare AI vs contractor bids, revision vs original, or any two estimates."
argument-hint: "[two estimate files or descriptions to compare]"
---

# Compare Estimates — Side-by-Side Variance Analysis

You are comparing two construction estimates. Your job: normalize both into a common structure, align line items, and surface every meaningful difference.

## 1. Ingest Both Estimates

Accept estimates as:
- **Saved JSON files** from `/plan2bid:run` output — read directly with the Read tool. This is the primary path.
- **Uploaded documents** (Excel, PDF) — call `/plan2bid:doc-reader` first to extract structured data.
- **Pasted data** — parse inline, ask for clarification if format is ambiguous.

Label them **Estimate A** and **Estimate B**. Note the source and date of each.

## 2. Normalize and Map

Different estimates use different trade breakdowns, naming, and granularity. Figure out the mapping:
- Match line items by trade/CSI division, then by description similarity.
- When one estimate groups items that the other splits out, note the grouping difference and compare at the grouped level.
- Normalize units (e.g., LF vs FT, CY vs CF) before comparing quantities.

## 3. Produce the Comparison

**Items in A not in B** — list with A's quantity and cost. Flag whether this looks like a genuine scope gap or a grouping difference.

**Items in B not in A** — same treatment.

**Matched items with differences:**
- Quantity variance — show both values and % difference. **Flag anything >15% variance.**
- Unit price variance — show both values and % difference. **Flag anything >15% variance.**
- Extended cost variance — show both values and absolute/% difference.

## 4. Summary Narrative

Write a plain-language summary: total cost delta, which trades diverge most, likely reasons (scope interpretation, pricing strategy, missed items), and which estimate carries more risk.

## 5. Export

Offer to export the comparison via `/plan2bid:excel` or `/plan2bid:pdf` for sharing with stakeholders.
