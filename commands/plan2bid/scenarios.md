---
description: "What-if scenario generator — re-prices an estimate with changed context (material swaps, scope changes, value engineering). Auto-compares against the base estimate."
argument-hint: "[scenario description, e.g. 'what if we used LED instead of fluorescent']"
---

# Scenarios — What-If Re-Pricing

You are running what-if scenarios on a construction estimate. Your job: apply the described change, re-price only affected items, and show the delta against the base.

## 1. Load the Base Estimate

Accept a saved JSON file from `/plan2bid:run` output — read with the Read tool. This is the base estimate all scenarios branch from. Confirm the base total before proceeding.

## 2. Parse the Scenario

Understand what the user is asking. Common scenario types:
- **Material swap** — substitute one product/material for another (LED vs fluorescent, copper vs PEX)
- **Scope change** — add or remove an area, floor, or system
- **Value engineering** — downgrade spec to reduce cost
- **Labor rate change** — different crew mix, overtime, prevailing wage
- **Quantity adjustment** — change an assumption (e.g., "what if the building is 10% larger")
- **Contingency/risk** — add or adjust contingency percentages

## 3. Re-Price Changed Items Only

Do NOT re-analyze documents or re-estimate from scratch. Only touch items affected by the scenario:
- Look up new pricing from `~/plan2bid-profile/` rate tables if available.
- Use `/research-web` for current material pricing when rates are not on file.
- Recalculate labor if crew composition or productivity changes.
- Cascade changes — if a material swap changes weight, check if structural or rigging costs are affected.

## 4. Auto-Compare Against Base

Show the comparison inline (do not call `/plan2bid:compare` as a separate skill):
- List every changed line item with base cost vs scenario cost.
- Show per-item delta ($ and %).
- Show total estimate delta ($ and %).
- Narrative: is this scenario worth pursuing? What are the trade-offs beyond cost (schedule, quality, risk)?

## 5. Branching

Scenarios can branch from other scenarios. When the user says "now what if we also...", apply the new change on top of the current scenario, not the original base. Track the chain: Base -> Scenario A -> Scenario A2.

## 6. Save

Save the scenario estimate as a new JSON file alongside the base so it can be used in future `/plan2bid:compare` or `/plan2bid:grade` calls.
