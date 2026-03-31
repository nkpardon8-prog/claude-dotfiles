---
description: "Grade a construction estimate against a known-good human reference — scores across 5 categories with specific miss explanations and improvement recommendations."
argument-hint: "[estimate to grade + reference estimate]"
---

# Grade Estimate — Scored Evaluation Against Reference

You are grading a construction estimate against a known-good human reference. Your job: score it rigorously, explain every miss, and give actionable improvement advice.

## 1. Ingest Both Estimates

- **Estimate to grade** + **Reference estimate** (the known-good baseline).
- Saved JSON from `/plan2bid:run` — read directly with the Read tool. Primary path.
- Uploaded documents — call `/plan2bid:doc-reader` first.
- Pasted data — parse inline.

## 2. Score Five Categories (0-100 each)

**Scope Completeness** — Are all trades, line items, and scope elements from the reference present? Deduct for every missing item proportional to its cost weight.

**Quantity Accuracy** — For matched items, how close are quantities? Score based on average deviation. <5% avg = 90+, 5-15% = 70-89, 15-30% = 50-69, >30% = below 50.

**Pricing Accuracy** — For matched items, how close are unit prices and extended costs? Same deviation bands. Account for regional/temporal price differences if evident.

**Line-Item Granularity** — Does the estimate break work down to an appropriate level? Deduct for over-grouping that hides cost drivers. Deduct for missing sub-items that the reference itemizes.

**Structural Correctness** — Proper trade organization, correct units, logical cost flow (material + labor + equipment), appropriate markup/overhead structure.

## 3. Overall Letter Grade

Weighted average (scope 30%, quantities 25%, pricing 25%, granularity 10%, structure 10%):
- A: 90-100 | B: 80-89 | C: 70-79 | D: 60-69 | F: below 60

## 4. Explain Every Miss

For each missed or significantly wrong item, explain WHY it was likely missed. Common patterns:
- **Floor boxes / power poles** — easy to miss on reflected ceiling plans
- **Fire stopping / firesafety** — rarely shown clearly on drawings
- **Seismic bracing** — code-required but often not detailed
- **Temp services** — temp power, temp lighting, temp protection
- **Demo and debris** — removal, hauling, dumpsters
- **Patching and painting** — after-trade wall/ceiling repair
- **Permit fees and inspections** — often in Division 01 but forgotten
- **Equipment rental** — lifts, scaffolding, material handling
- **Existing conditions work** — surveys, exploratory demo, asbestos abatement
- **General conditions / supervision** — project management, site trailers, cleanup

## 5. Improvement Recommendations

Provide 3-5 specific, actionable recommendations to improve future estimates. Reference the patterns above and tie each recommendation to the scoring gaps found.

## 6. Export

Offer to export the grading report via `/plan2bid:excel` or `/plan2bid:pdf`.
