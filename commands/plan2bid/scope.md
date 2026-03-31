---
description: "Scope boundary analysis — reads construction documents and produces explicit IN/OUT scope lists per trade with source citations. Resolves document hierarchy and flags ambiguous items."
argument-hint: "[uploaded documents or 'analyze scope for electrical']"
---

# Scope — Boundary Analysis Per Trade

You are performing scope boundary analysis on construction documents. Your job: produce explicit IN SCOPE and OUT OF SCOPE lists per trade, with source citations for every item, by applying document hierarchy rules. Flag every ambiguous item with a clarifying question and its pricing impact.

Input: $ARGUMENTS

## Step 1: Read All Documents

Call `/plan2bid:doc-reader` via the Skill tool. You need the full document manifest, schedules, cross-references, and conflict flags before you can determine scope boundaries.

## Step 2: Establish Document Hierarchy

Rank documents by authority. When documents conflict, higher-ranked documents win:

1. **SOW / Contract** -- highest authority, defines what is and is not in scope
2. **Addenda / Bulletins** -- supersede anything they explicitly modify
3. **Specifications (CSI divisions)** -- define materials, methods, quality standards
4. **Existing condition plans / As-builts** -- define what is already there
5. **New / Proposed drawings** -- define what is being added or changed
6. **Handbooks / Standards / Reference docs** -- lowest authority, context only

For each document, note its rank and what it governs. When two documents address the same item differently, the higher-ranked document controls. Cite both and state which wins.

## Step 3: Scope Determination Per Trade

For each trade in scope (or the specific trade requested), walk through every item:

- **SOW includes it explicitly?** --> IN SCOPE. Cite the SOW clause.
- **SOW excludes it or assigns to others?** --> OUT OF SCOPE. Cite the exclusion.
- **SOW is silent, but drawings show it?** --> AMBIGUOUS. Flag it.
- **Shown on existing plans but not on new plans?** --> Likely demo or reuse. Flag it.
- **Shown on new plans but not in SOW?** --> Likely in scope but confirm. Flag it.
- **In specs but not on drawings?** --> Possible spec boilerplate vs. real scope. Flag it.

## Step 4: Produce Scope Lists

For each trade, output:

### IN SCOPE
| Item | Source | Page/Section | Notes |
|------|--------|-------------|-------|

### OUT OF SCOPE
| Item | Reason | Source | Page/Section |
|------|--------|--------|-------------|

### AMBIGUOUS -- Needs Clarification
| Item | Conflict | Sources | Pricing Impact | Question |
|------|----------|---------|---------------|----------|

Every row must have a source citation: which document, which page or section, which clause or detail number. "Electrical panel" is not acceptable -- "200A panel 'H' per Sheet E-101, Detail 3" is.

For ambiguous items, the **Question** column must be concrete and specific, and the **Pricing Impact** column must explain what happens if the item is in vs. out (e.g., "If Panel H is existing and reused: $0. If new: ~$4,200 installed.").

## Step 5: Cross-Reference Check

Compare your scope lists against:
- **Schedules** (door, finish, panel, fixture) -- every scheduled item should appear in a scope list
- **Drawing counts** -- items visible on drawings should be accounted for
- **Spec sections** -- every referenced CSI section relevant to the trade should map to scope items

Flag any orphaned items (in a schedule but not in your scope list, or vice versa).

## Reference

Estimation workflow guidelines: `~/Desktop/Projects/Plan2BidAgent/guidelines/estimation-workflow.md`
