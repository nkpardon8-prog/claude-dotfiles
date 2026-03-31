---
description: "Pre-flight validation for construction estimation — checks project description for 6 critical gaps that cause silent pricing failures. Run before /plan2bid:run to catch missing info early."
argument-hint: "[project description or 'check my docs']"
---

# Validate — Pre-Flight Estimation Check

You are reviewing a project description (and optionally uploaded documents) for 6 critical gaps that cause silent pricing failures downstream. Your job: surface every gap as a concrete, answerable question with its pricing impact explained. Err on the side of over-asking.

Input: $ARGUMENTS

## Step 1: Document Analysis (if documents provided)

If the user uploaded construction documents or said "check my docs," call `/plan2bid:doc-reader` via the Skill tool to classify and read them before proceeding. You need the document manifest to ask informed questions.

## Step 2: Check the 6 Critical Gaps

Work through each condition. For every gap found, produce a specific question and explain why it matters for pricing.

### 1. Document Roles
What role does each document play? Plans, specs, SOW, addenda, as-builts, handbooks?
- **Why it matters:** Document hierarchy (SOW > existing plans > new plans > handbook) determines which information wins when docs conflict. Misidentifying a handbook as a spec inflates scope.
- Ask: "Is [filename] the governing SOW, or reference only?"

### 2. Renovation Degree
Is this new construction, full gut renovation, partial renovation, or cosmetic refresh?
- **Why it matters:** Renovation degree drives whether existing infrastructure is reused, replaced, or supplemented. A "remodel" can mean drywall paint or full MEP replacement -- the pricing difference is 5-10x.
- Ask: "Is Panel H existing and staying, or being replaced?" not "Clarify renovation scope."

### 3. Demo Scope Source
Where does demolition scope come from? Is it shown on drawings, described in SOW, or assumed?
- **Why it matters:** Demo is often the largest hidden cost. If demo scope is implied but not drawn, the estimate either misses it entirely or double-counts with the GC's demo subcontractor.
- Ask: "Demo is not shown on drawings -- does your SOW include demo of existing [specific items], or is that by others?"

### 4. Documents to Ignore
Are any uploaded documents outdated, superseded, or included only for reference?
- **Why it matters:** Pricing from a superseded plan sheet adds phantom scope. A reference-only handbook included "for context" can add thousands in unnecessary items.
- Ask: "Sheet A-201 is dated 2019 but A-201R1 is dated 2024 -- should I ignore the 2019 version?"

### 5. Superseding Documents
Do any addenda, bulletins, or revisions override base documents?
- **Why it matters:** Addenda typically change quantities, substitute materials, or delete scope. Missing an addendum means pricing items that were removed or using old specs.
- Ask: "Addendum 2 changes the panel schedule -- should it override the original E-sheets?"

### 6. Scope Carve-Outs
Is any visible scope explicitly excluded from this bid, handled by others, or owner-furnished?
- **Why it matters:** Pricing owner-furnished equipment or another sub's scope inflates the bid. Missing a carve-out that IS your scope loses money.
- Ask: "The drawings show fire alarm devices -- is fire alarm in your scope or by the FA sub?"

## Step 3: Present Findings

Organize output as:

1. **Gaps Found** -- numbered list of specific questions, each with its pricing impact
2. **Assumptions (if no answer)** -- what you would assume for each gap if the user doesn't respond, and the risk of that assumption
3. **Ready for /plan2bid:run?** -- yes/no with conditions

Questions must be concrete and specific to THIS project. Never ask "Can you clarify the scope?" -- instead ask "The SOW mentions 'relocate existing receptacles' but doesn't say how many -- are all 14 receptacles on Sheet E-101 being relocated, or only those in the demo area?"

## Reference

Estimation workflow guidelines: `~/Desktop/Projects/Plan2BidAgent/guidelines/estimation-workflow.md`
