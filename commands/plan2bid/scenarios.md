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
- Use WebSearch directly for current material pricing when rates are not on file.
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

## scenario_output.json Schema

Your output MUST be a JSON file with this exact structure:

```json
{
  "line_items": [
    {
      "item_id": "TRADE-NNN",
      "trade": "electrical",
      "description": "...",
      "quantity": 10,
      "unit": "EA",
      "is_material": true,
      "is_labor": true,
      "unit_cost_low": 8.0,
      "unit_cost_expected": 10.0,
      "unit_cost_high": 12.0,
      "extended_cost_low": 80.0,
      "extended_cost_expected": 100.0,
      "extended_cost_high": 120.0,
      "material_confidence": "medium",
      "pricing_method": "web_search",
      "material_reasoning": "...",
      "price_sources": [{"source_name": "...", "url": "..."}],
      "total_labor_hours": 0.5,
      "hours_expected": 0.5,
      "hours_low": 0.4,
      "hours_high": 0.7,
      "blended_hourly_rate": 65.0,
      "labor_cost": 32.5,
      "cost_expected": 32.5,
      "cost_low": 26.0,
      "cost_high": 45.5,
      "labor_confidence": "medium",
      "labor_reasoning": "...",
      "crew": [{"role": "...", "count": 1}],
      "site_adjustments": []
    }
  ],
  "summary": "One sentence summarizing the scenario impact",
  "reasoning": "2-3 sentences explaining the pricing logic",
  "anomalies": [
    {"trade": "electrical", "anomaly_type": "noted", "category": "...", "description": "...", "affected_items": ["TRADE-NNN"], "cost_impact": 0}
  ]
}
```

### CRITICAL RULES:
- `is_material` and `is_labor` MUST be boolean on every item
- `trade` MUST match the trade from the base estimate (on items AND anomalies)
- `item_id` MUST match the base estimate item IDs for items being modified
- Include ALL items from the base estimate (not just changed ones) -- copy unchanged items as-is
- Numbers must be numeric, never formatted strings
- Confidence: lowercase "high", "medium", "low" only

## 6. MANDATORY FINAL STEP — Save to Database

Save the scenario estimate as `scenario_output.json` in the current directory.

Then save to the database by running:

```
/plan2bid:save-scenario-to-db {scenario_id} {project_id}
```

The scenario_id and project_id are in your prompt (look for "Scenario ID:" and "Project ID:").

**The scenario is NOT complete until the save succeeds.**
