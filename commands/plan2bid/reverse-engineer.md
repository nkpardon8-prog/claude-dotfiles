---
description: "Reverse-engineer a human estimator's methodology from their completed estimate — extracts trade structure, pricing strategy, labor assumptions, markup approach, and scope judgment calls."
argument-hint: "[completed human estimate file — Excel, PDF, or pasted data]"
---

# Reverse-Engineer Estimate — Methodology Extraction

You are reverse-engineering a human estimator's approach from their completed estimate. Your job: figure out HOW they built it and extract actionable insights for future estimation.

## 1. Ingest the Estimate

Accept a completed human estimate as:
- **Excel or PDF** — call `/plan2bid:doc-reader` first to extract structured data.
- **Pasted data** — parse inline.

Read every tab, section, and subtotal. The structure itself is data.

## 2. Analyze These Dimensions

**Trade Structure** — How did they organize work? By CSI division, by subcontractor, by building area, or hybrid? What level of detail per trade? Which trades are self-performed vs subbed out?

**Quantity Methodology** — Are quantities derived from takeoff (specific counts) or parametric ($/SF, $/unit)? Where did they measure precisely vs use allowances? What measurement units do they prefer?

**Pricing Strategy** — Are unit prices from recent quotes, published data (RSMeans), or internal history? Do prices include labor+material combined or break them out? How do they handle pricing uncertainty (allowances, contingency, escalation)?

**Labor Assumptions** — What labor rates are implied? Can you back-calculate productivity rates (units/hour)? What crew sizes are assumed? Is overtime or shift premium included? Prevailing wage or open shop?

**Existing Conditions Handling** — How do they account for unknowns? Exploratory demo allowances, asbestos/lead contingency, field verification notes?

**Markup Strategy** — What's the overhead percentage? Profit margin? Are markups applied per-trade or on the total? Bond and insurance treatment? How do they handle subcontractor markup vs self-performed markup?

**Risk Items** — What contingencies are carried? Where did they add padding vs hard numbers? Any exclusions or qualifications that shift risk?

**Scope Judgment Calls** — What did they include that wasn't explicitly shown on drawings? What did they exclude and why (noted exclusions)? Where did they interpret ambiguous scope?

## 3. Output: Methodology Report

Summarize findings as actionable insights that can inform future `/plan2bid:run` sessions:
- **Estimator profile** — their style, strengths, tendencies
- **Key takeaways** — what to replicate, what to question
- **Rate benchmarks** — extracted unit prices and labor rates worth saving
- **Scope patterns** — items they consistently include/exclude that are easy to miss

Offer to save extracted rates to `~/plan2bid-profile/` for use in future estimates.
