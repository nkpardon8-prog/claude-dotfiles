---
description: "Merge trade group results into a final estimate. Validates, deduplicates, and saves to database."
argument-hint: "[project_id]"
---

# Merge Trade Group Results

You are assembling a construction estimate from multiple trade group files. Read all group results, merge, validate, and save to the database.

Project ID: $ARGUMENTS

## Instructions

1. **Find group results** — look for `trade_items.json` files in sibling directories (e.g., `../group_mep/trade_items.json`, `../group_arch/trade_items.json`, `../group_gc/trade_items.json`). Use Glob to find them.

2. **Read and merge** — load each file's `line_items` array. Combine into a single flat array.

3. **Deduplicate** — if the same `item_id` appears in multiple groups, keep the version with more detail (more fields populated, higher confidence).

4. **Validate the merged estimate:**
   - **$/SF check**: total / project_SF should be reasonable for the project's facility type. Common ranges: retail/restaurant $150-400/SF, office TI $80-250/SF, medical $300-600/SF, residential $200-500/SF, warehouse $60-120/SF, industrial highly variable, demo-only $5-25/SF. If well below the low end for your project type, flag missing scope — don't invent items to reach a threshold.
   - **Labor ratio**: labor / (labor + material) should be 35-55%. Outside 25-65% means pricing approach is wrong.
   - **Trade coverage**: every expected trade should have at least 2 line items. If a trade has 0 items and it's in the documents, estimate it.
   - **No $0 items**: remove or re-price any item with zero cost.
   - **GC standard items**: ensure these exist: superintendent/supervision, permits, dumpster/waste, barricade/dust wall, final cleaning, project closeout. Add if missing.

5. **Write `estimate_output.json`** to the current directory (`./estimate_output.json`):

```json
{
  "line_items": [],
  "anomalies": [],
  "site_intelligence": {
    "project_findings": {},
    "procurement_intel": {},
    "estimation_guidance": {}
  },
  "brief_data": {
    "project_classification": "",
    "scope_summary": "",
    "generation_notes": ""
  },
  "warnings": []
}
```

6. **Save to database** — this is MANDATORY:
```
/plan2bid:save-to-db {project_id}
```

The estimation is NOT complete until the save succeeds.

## Rules

- `line_items` MUST be a flat top-level array
- Each item MUST have `is_material` and `is_labor` boolean flags
- All cost fields MUST be numbers
- If a group file is missing or corrupt, note it in `warnings` and estimate those trades yourself
- Do NOT modify the group files — only read them
