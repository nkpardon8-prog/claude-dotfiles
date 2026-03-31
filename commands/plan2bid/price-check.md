---
description: "Verify construction material pricing against web sources and your pricing profile. Flags low confidence items and significant variances. Use standalone or as a sanity check on an existing estimate."
argument-hint: "[material list + ZIP code, or 'check pricing on last estimate']"
---

# Price-Check Materials

## Gather inputs

1. **From an existing estimate**: If the user says "check pricing on last estimate" or provides a JSON path, extract the material line items (description, quantity, unit, unit price) and the project ZIP code.
2. **Standalone list**: Accept a list of materials with quantities and a ZIP code directly from the user.

A ZIP code is required for regional pricing. If missing, ask the user.

## Check local pricing profile first

Read files in `~/plan2bid-profile/` for any saved pricing data (unit costs, supplier quotes, historical bids). For each material in the list, check whether a matching entry exists in the profile. If found, record it as a **profile price** with high confidence.

## Web-verify remaining items

For each item that has no profile match or where the user wants verification, use the `/research-web` Skill tool to look up current market pricing. Construct a search query scoped to the material and location:

> `"{material description}" price per {unit} {ZIP code or city/state}`

### Limitations to keep in mind
- `/research-web` is good for material pricing by description and location (lumber, concrete, rebar, drywall, etc.).
- It is **not reliable** for exact labor rates. Do not attempt to web-verify labor line items; flag them as "labor — skip web check" instead.
- Prefer supplier and distributor sites (Home Depot Pro, ABC Supply, BuildersTrend) over generic results.

## Build the output table

For each material, produce a row with:

| Material | Qty | Unit | Estimate Price | Market Price | Source | Confidence | Variance |
|----------|-----|------|---------------|-------------|--------|------------|----------|

- **Confidence**: `high` (profile match or multiple corroborating sources), `medium` (single web source, recent), `low` (old data, vague match, or no source found).
- **Variance**: percentage difference between estimate price and market price. Flag any variance over 15% with a warning.

## Summarize findings

After the table, provide:
1. Count of items checked and how many came from profile vs. web.
2. Items flagged for significant variance (over 15%).
3. Items with low confidence that deserve manual verification.
4. Any labor items that were skipped.

If the user wants to update their pricing profile with the new data, offer to write the verified prices back to `~/plan2bid-profile/`.
