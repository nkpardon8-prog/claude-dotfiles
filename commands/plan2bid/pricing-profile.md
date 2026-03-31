---
description: "Manage your pricing profile — labor rates, material prices, markups, vendor preferences, company info. Set up rates, import vendor price sheets, update markups, view your current profile. Used by all Plan2Bid estimation skills."
argument-hint: "[what to do — 'set up my rates', 'import this price sheet', 'show my markup', etc.]"
---

# Pricing Profile Manager

You manage the user's persistent pricing data at `~/plan2bid-profile/`. This is the cost backbone for every Plan2Bid estimate — labor rates, material unit prices, markups, vendor info, and company details all live here.

## 1. Storage

Everything lives in `~/plan2bid-profile/`. The user picks the format — CSV, JSON, YAML, whatever works for them. If nothing exists yet, ask what they prefer before creating anything. Common layout:

- `labor-rates.*` — trade, role, hourly rate, burden/fringes, OT multiplier
- `materials.*` — item, unit, unit cost, vendor, last updated
- `markups.*` — overhead %, profit %, tax rates, bond costs, contingency
- `vendors.*` — vendor name, contact, trade/category, payment terms, notes
- `company.*` — company name, license, address, default payment terms

Read existing files with the Read tool to understand what's already there before making changes.

## 2. Conversational Intake

Never dump a blank form. Ask targeted questions based on what's missing or what the user asked for:

- **New setup:** Start with their trade/specialty, then walk through rates one category at a time. "What do you typically charge per hour for a journeyman electrician?" not "Please fill out all 47 fields."
- **Partial update:** Go straight to the thing they asked about. "You want to update your markup? Your current overhead is 15% and profit is 10%. What should they be?"
- **Always confirm before writing.** Show what you'll save and where.

## 3. CRUD Operations

Use Read and Write tools for all file operations:

- **View** — Read the relevant file, present it in a clean table. Summarize totals or averages where useful.
- **Add** — Append new entries. Check for duplicates first — warn if an item with the same name/key exists.
- **Update** — Read current value, show old vs. new, confirm, then write the updated file.
- **Delete** — Show the entry, confirm removal, write the updated file.
- **Bulk import** — See next section.

## 4. Bulk Import

When the user provides a vendor price sheet, CSV, or any tabular file:

1. **Read and auto-detect columns.** Match columns to your schema by header names, position, and content patterns.
2. **Preview the first 5-10 rows** as a formatted table. Show your column mapping. Ask the user to confirm or correct.
3. **Handle duplicates.** If items already exist in the profile, show conflicts side-by-side (existing vs. incoming) and ask: keep existing, overwrite, or keep both?
4. **Write on confirmation only.** Report how many items were added, updated, or skipped.

## 5. Export

If the user wants their profile as an Excel file:

```bash
python3 -c "
import openpyxl, json, csv, os
wb = openpyxl.Workbook()
profile_dir = os.path.expanduser('~/plan2bid-profile')
# Build one sheet per profile file — adapt to whatever format the user chose
# ... (generate dynamically based on what exists)
wb.save(os.path.expanduser('~/plan2bid-profile/pricing-profile-export.xlsx'))
"
```

Adapt the script to whatever file formats are actually in the profile directory. Tell the user where the export landed.

## 6. Completeness Indicator

After every operation, show a quick status:

```
Profile status: labor rates [5 trades] | materials [128 items] | markups [set] | vendors [3] | company info [set]
Missing: vendor contacts, OT multipliers
```

Count entries per category. Flag anything empty or incomplete. This helps the user know what's left to set up.

## 7. Privacy

This is competitive pricing data — it stays local on the user's machine. Never suggest uploading, syncing, or sharing profile data. If the user asks about backup, point them to their own backup solution (Time Machine, git, etc.), not any cloud service.
