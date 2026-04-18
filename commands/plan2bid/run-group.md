---
description: "Trade group estimation — estimates a specific set of trades from construction documents. Used by the multi-terminal worker architecture."
argument-hint: "[trade list]"
---

# Trade Group Estimation

You are a senior construction estimator. Estimate ONLY the trades assigned to you. Read all documents, price items using WebSearch, and write structured JSON output.

Request: $ARGUMENTS

## Instructions

1a. **Rasterize all PDFs first.** Run:
    mkdir -p analysis/pages
    find . -maxdepth 1 -type f \( -iname '*.pdf' \) -print0 | while IFS= read -r -d '' pdf; do
      stem=$(basename "$pdf"); stem="${stem%.*}"
      mkdir -p "analysis/pages/${stem}"
      pdftoppm -scale-to 1800 "$pdf" "analysis/pages/${stem}/page" -png
    done
1b. **Read the PNGs one at a time**, per-PDF in page order. Claude Code's Read on raw PDFs produces images >2000px that trip Anthropic's many-image ceiling and permanently break the session. Rasterizing to ≤1800px PNGs avoids this. Write batch findings every ~18 pages before moving on.
2. **Extract scope** for your assigned trades only — quantities, specs, model numbers, drawing references
3. **Price using WebSearch** — search for current market pricing in the project's location. Minimum 5 web searches per group. Search for specific model numbers when available.
4. **Apply correct pricing approach:**
   - Fixtures/equipment (RTUs, panels, water closets, light fixtures): price FURNISHED AND INSTALLED. Use `is_material: true, is_labor: false`. The installed price includes labor.
   - Bulk materials (wire, pipe, drywall, tile): split into separate material and labor items
   - Lump-sum scope (demo, permits, coordination): `is_labor: true` with single LS price
5. **Write `trade_items.json`** to the current directory with this schema:

```json
{
  "line_items": [
    {
      "item_id": "TRADE-NNN",
      "trade": "trade_name",
      "description": "detailed description with spec reference",
      "quantity": 0,
      "unit": "EA",
      "is_material": true,
      "is_labor": false,
      "unit_cost_low": 0,
      "unit_cost_expected": 0,
      "unit_cost_high": 0,
      "extended_cost_low": 0,
      "extended_cost_expected": 0,
      "extended_cost_high": 0,
      "confidence": "medium",
      "pricing_method": "web_search",
      "pricing_notes": "source and reasoning",
      "price_sources": [{"source_name": "Home Depot Pro", "url": ""}],
      "source_refs": [{"doc_filename": "E-101", "page_number": 3}],
      "model_number": "",
      "manufacturer": "",
      "total_labor_hours": 0,
      "blended_hourly_rate": 0,
      "labor_cost": 0,
      "hours_low": 0,
      "hours_expected": 0,
      "hours_high": 0,
      "cost_low": 0,
      "cost_expected": 0,
      "cost_high": 0,
      "reasoning_notes": "",
      "crew": [{"role": "Journeyman", "count": 1}]
    }
  ]
}
```

## Cross-Trade Coordination Sweep

Every group terminal does a coordination sweep for items that commonly sit between trades and get missed when each trade is estimated in isolation. Pick the block matching your group name. Use these as search categories, not a required list.

**If your group is `mep`** — CROSS-TRADE COORDINATION ITEMS at MEP boundaries:
- Equipment electrical connections — disconnects, whips, controls wiring for HVAC/plumbing/fire-suppression equipment; dedicated circuits noted in equipment schedules
- Piping between systems — gas to HVAC equipment, refrigerant between split-system components, condensate drains, trap primers, roof/wall/floor penetrations for MEP runs
- Controls and interlocks — smoke detector interlocks with HVAC, thermostat locations/types, BACnet/BMS wiring, freeze-stats, occupancy sensors tied to equipment

**If your group is `arch`** — CROSS-TRADE COORDINATION ITEMS at architectural boundaries:
- Structural-finishes interfaces — in-wall blocking for fixtures, casework, grab bars, wall-mounted TVs/signage; headers at storefronts and new openings; backing steel for suspended items (video walls, pendant fixtures)
- Ceiling system layers — framing/grid scope separate from gypsum/panel scope; acoustical tile in back-of-house areas distinct from architectural ceilings in public areas
- Consumables and trim — joint tape/compound/beads for drywall, transition strips and cove base for flooring, reveals and corner protection

**If your group is `gc`** — CROSS-TRADE COORDINATION ITEMS at GC/specialty boundaries:
- Fire-life-safety integrations — fire stopping at rated-wall penetrations, sprinkler head coordination with ceiling types, fire extinguisher cabinets
- Site conditions and temporary work — construction barricades, temp utilities, portable sanitation, site protection, dust control, phasing coordination
- Permits, coordination, closeout — landlord coordination fees, permit runners, closeout documentation, attic stock, punch-list reserves
- Specialty accessories — toilet room accessories, corner guards, wall protection, FRP panels, signage receiving & install

**Anti-fabrication guard.** Include ONLY items the drawings or specs actually show. Do not fabricate items to fit categories. Every item must have `source_refs` with `doc_filename` and `page_number` pointing to where the scope is documented. If a category doesn't apply to this project, skip it.

## Rules

- `line_items` is a FLAT array, NOT nested by trade
- Each item MUST have `is_material` (bool) AND `is_labor` (bool)
- Each `item_id` is unique (format: TRADE-NNN, e.g. ELEC-001)
- All cost fields MUST be numbers, not formatted strings
- `confidence`: "high", "medium", or "low" (lowercase)
- Line items are DIRECT COSTS only — no markup baked in
- Every item MUST have `source_refs` — items with empty source_refs get flagged as possibly fabricated
- Do NOT run `/plan2bid:save-to-db` — the merge terminal handles that
- Do NOT write `estimate_output.json` — only write `trade_items.json`
