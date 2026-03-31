---
description: "Scope boundary analysis — reads construction documents and produces explicit IN/OUT scope lists per trade with source citations. Resolves document hierarchy and flags ambiguous items."
argument-hint: "[uploaded documents or 'analyze scope for electrical']"
---

# Scope — Boundary Analysis Per Trade

Produce explicit IN SCOPE and OUT OF SCOPE lists per trade with source citations for every item. Apply document hierarchy rules. Flag every ambiguous item with a clarifying question and pricing impact.

Input: $ARGUMENTS

## Step 1: Read All Documents

Call `/plan2bid:doc-reader` via the Skill tool. You need the full document manifest, schedules, cross-references, and conflict flags before determining scope boundaries.

## Step 2: Establish Document Hierarchy

Rank by authority -- higher-ranked documents win on conflicts:

1. **SOW / Contract** -- highest authority, defines what is and is not in scope
2. **Addenda / Bulletins** -- supersede anything they explicitly modify
3. **Specifications (CSI divisions)** -- materials, methods, quality standards
4. **Existing condition plans / As-builts** -- what is already there
5. **New / Proposed drawings** -- what is being added or changed
6. **Handbooks / Standards / Reference docs** -- lowest authority, context only

When two documents address the same item differently, cite both and state which wins.

## Step 3: Scope Determination Per Trade

For each trade (or the specific trade requested), walk through every item:

- **SOW includes explicitly?** --> IN SCOPE. Cite the SOW clause.
- **SOW excludes or assigns to others?** --> OUT OF SCOPE. Cite the exclusion.
- **SOW silent, drawings show it?** --> AMBIGUOUS. Flag it.
- **On existing plans but not new?** --> Likely demo or reuse. Flag it.
- **On new plans but not in SOW?** --> Likely in scope, confirm. Flag it.
- **In specs but not on drawings?** --> Possible boilerplate vs. real scope. Flag it.

## Step 4: Produce Scope Lists

For each trade, output three tables:

**IN SCOPE:** Item | Source | Page/Section | Notes
**OUT OF SCOPE:** Item | Reason | Source | Page/Section
**AMBIGUOUS:** Item | Conflict | Sources | Pricing Impact | Question

Every row needs a source citation -- document, page/section, clause or detail number. "Electrical panel" is not acceptable; "200A panel 'H' per Sheet E-101, Detail 3" is.

Ambiguous items: the Question must be concrete, and Pricing Impact must show both outcomes (e.g., "Panel H existing and reused: $0. If new: ~$4,200 installed.").

## Step 5: Cross-Reference Check

Compare scope lists against schedules (door, finish, panel, fixture), drawing counts, and spec sections. Every scheduled item should appear in a scope list. Flag orphaned items -- in a schedule but missing from scope, or vice versa.

## Reference

Guidelines: `~/Desktop/Projects/Plan2BidAgent/guidelines/estimation-workflow.md`
