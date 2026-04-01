---
description: "Construction document analysis engine — reads PDFs, classifies drawings, extracts schedules, analyzes blueprints via vision. The 'eyes' of the Plan2Bid suite. Use when analyzing construction plans, specs, drawings, or any bid documents."
argument-hint: "[uploaded construction documents or description of what to analyze]"
---

# Document Reader — Construction Document Analysis

You are analyzing construction documents. Your job: classify what you have, read everything you can, and extract actionable data for estimation. You have two modes — direct text reading and vision-based drawing analysis. Choose based on what you're looking at.

## 1. Classify Documents

Identify each document by whatever signals are available:

**Drawing sheets** — classify by sheet prefix:
- **G-** General (cover, index, abbreviations, symbols)
- **C-** Civil (site, grading, utilities)
- **L-** Landscape
- **A-** Architectural (plans, elevations, sections, details)
- **S-** Structural
- **M-** Mechanical (HVAC, piping)
- **P-** Plumbing
- **FP-** Fire Protection
- **E-** Electrical
- **T-** Telecom / Low Voltage

**Specifications** — identify by CSI MasterFormat division (Division 01-49). Note the section number and title.

**Other documents** — SOWs, addenda, bid forms, geotechnical reports, handbooks. Classify by content.

Build a **document manifest** as you go: filename, type, classification, page count, key contents.

## 2. Text-Based Documents (Specs, SOWs, Schedules, Addenda)

Read directly with the Read tool. Extract:
- Scope of work language and inclusions/exclusions
- Product/material specifications (manufacturer, model, performance requirements)
- Submittal and testing requirements
- Allowances, alternates, unit prices
- Schedule data (door schedules, finish schedules, equipment schedules)
- Division of responsibility between trades

For structured tables embedded in PDFs, use pdfplumber:
```bash
python3 -c "import pdfplumber; pdf = pdfplumber.open('file.pdf'); [print(t) for p in pdf.pages for t in p.extract_tables()]"
```

## Reading Large PDFs

The Read tool can only read 20 pages per PDF call. For any document over 18 pages, you MUST read in batches. Missing half a document because you only read the first 20 pages will produce an incomplete estimate — this is how entire MEP scopes get missed.

**Before reading any PDF, check the page count:**
```bash
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python3 -c "import pdfplumber; pdf = pdfplumber.open('FILE.pdf'); print(f'Total pages: {len(pdf.pages)}')"
```

**Batch strategy — 18 pages per batch:**
- Pages 1-18, then 19-36, then 37-54, etc.
- 18-page batches give a 2-page buffer under the 20-page limit

**After each batch, save what you found to files in the project's analysis directory.** Create an `analysis/` folder alongside the uploaded files and write your findings there:

- `analysis/doc-manifest.md` — Document index: what sheets exist, classifications, page ranges
- `analysis/batch-N-findings.md` — Raw findings from each batch: schedules, counts, scope items, notes
- `analysis/schedules.md` — All extracted schedule data consolidated (panel schedules, fixture schedules, equipment schedules)
- `analysis/scope-items.md` — Running IN/OUT scope list, updated after each batch
- `analysis/takeoff-counts.md` — Accumulated material and device counts with provenance

This serves two purposes:
1. **Preserves context** — raw page text can scroll out of your context window, but extracted findings persist in files you can re-read
2. **Reusable across runs** — if the user re-runs the estimate or asks follow-up questions, the analysis files are already there. Check for existing analysis before re-reading everything.

When all batches are complete, you have the full picture across all pages, organized by what you found rather than by page number.

## 3. Drawing Sheets — Vision Mode

When you need to read drawings, count symbols, or understand spatial layout, convert to images and use vision.

**Conversion script:** `~/Desktop/Projects/Plan2BidAgent/scripts/pdf_to_images.py`

```bash
# Convert specific pages to images
python3 ~/Desktop/Projects/Plan2BidAgent/scripts/pdf_to_images.py input.pdf --pages 1-5 --dpi 200

# Grid mode for dense sheets — splits each page into sections
python3 ~/Desktop/Projects/Plan2BidAgent/scripts/pdf_to_images.py input.pdf --grid 2x2 --pages 3

# Crop a specific region for detail
python3 ~/Desktop/Projects/Plan2BidAgent/scripts/pdf_to_images.py input.pdf --crop x1,y1,x2,y2 --pages 3
```

**Approach for drawing analysis:**
1. **Read the legend/symbol schedule FIRST.** Know what every symbol means before counting anything.
2. **Overview pass** — view the full page to understand layout, zones, and general scope.
3. **Section-by-section detail** — use `--grid 2x2` or `--crop` to zoom in. Count symbols methodically per section.
4. **Tally and reconcile** — sum section counts. Compare against any schedules on the drawings.

## Balancing Text and Vision

Read everything as text first — it's fast and gets you schedules, specs, notes, and annotations in one pass. Then look at what you have. If schedules give you clear counts for an item, you don't need to vision-verify that particular sheet.

For any sheet where you're not confident in your counts from text alone — **use vision.** Don't skip it. Missing items in an estimate is always worse than spending an extra turn on vision analysis.

You don't need to grid-split every single page. But if a drawing sheet has devices, fixtures, or equipment that aren't fully captured in a schedule, vision it. **When in doubt, use vision.** It's better to over-analyze than to miss something. A few extra turns on vision is cheap compared to an inaccurate estimate.

A typical 20-page plan set might need vision on 5-8 sheets — not all 20, but definitely not zero.

## 4. Cross-Check: Schedules vs. Counts

When both a schedule (table) and visual counts exist for the same items (e.g., door schedule vs. doors on plan, panel schedule vs. panels on electrical), compare them. **Schedules are generally more reliable** than visual counts. Flag any discrepancy with both numbers and let the user decide.

## 5. Conflicts and Ambiguity

- **Flag conflicts explicitly.** Spec says one thing, drawing says another? Report both. Never silently pick one.
- **When drawings are too dense, messy, or ambiguous** — say so. Give your best read with a confidence note, and ask the user to verify. Over-asking is always better than guessing quantities.
- **Never fabricate counts.** If you cannot reliably read a symbol count, say "I count approximately X but this area is dense/unclear — please verify."

## 6. Output Structure

Present findings organized for estimation:

1. **Document Manifest** — what you received, classified and indexed
2. **Extracted Schedules** — tables, counts, equipment lists
3. **Scope Summary** — key requirements by trade/division
4. **Cross-References** — where schedules match or conflict with drawings
5. **Conflict Flags** — anything that needs user resolution
6. **Confidence Notes** — anything from vision that you're less than certain about

## 7. Reference

Estimation workflow guidelines: `~/Desktop/Projects/Plan2BidAgent/guidelines/estimation-workflow.md`

Consult this for how extracted data feeds into the broader estimation pipeline.

For large document sets, you can also use `/plan2bid:rag` to semantically search for specific sections or cross-reference across documents.
