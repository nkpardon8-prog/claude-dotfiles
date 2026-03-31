---
description: "Pre-flight validation for construction estimation — checks project description for 6 critical gaps that cause silent pricing failures. Run before /plan2bid:run to catch missing info early."
argument-hint: "[project description or 'check my docs']"
---

# Validate — Pre-Flight Estimation Check

You are reviewing a project description (and optionally uploaded documents) for 6 critical gaps that cause silent pricing failures downstream. Surface every gap as a concrete, answerable question with its pricing impact. Err on the side of over-asking.

Input: $ARGUMENTS

## Step 1: Document Analysis (if docs provided)

If documents are uploaded or user said "check my docs," call `/plan2bid:doc-reader` via the Skill tool first. You need the document manifest to ask informed questions.

## Step 2: Check the 6 Critical Gaps

For every gap found, produce a specific question and explain why it matters for pricing.

### 1. Document Roles
What role does each document play — plans, specs, SOW, addenda, as-builts, handbooks? Hierarchy (SOW > existing plans > new plans > handbook) determines which info wins on conflicts. Misidentifying a handbook as a spec inflates scope.
- Ask: "Is [filename] the governing SOW, or reference only?"

### 2. Renovation Degree
New construction, full gut, partial renovation, or cosmetic refresh? This drives reuse vs. replace vs. supplement decisions. A "remodel" can mean paint or full MEP replacement -- 5-10x pricing difference.
- Ask: "Is Panel H existing and staying, or being replaced?" not "Clarify renovation scope."

### 3. Demo Scope Source
Is demo shown on drawings, described in SOW, or assumed? Demo is often the largest hidden cost. Implied but undrawn demo either gets missed or double-counted with the GC's demo sub.
- Ask: "Demo not shown on drawings -- does your SOW include demo of existing [specific items], or is that by others?"

### 4. Documents to Ignore
Any uploaded docs outdated, superseded, or reference-only? Pricing from a superseded sheet adds phantom scope. A reference handbook "for context" can add thousands in unnecessary items.
- Ask: "Sheet A-201 is dated 2019 but A-201R1 is 2024 -- ignore the 2019 version?"

### 5. Superseding Documents
Do addenda, bulletins, or revisions override base documents? Addenda change quantities, substitute materials, or delete scope. Missing one means pricing removed items or using old specs.
- Ask: "Addendum 2 changes the panel schedule -- should it override the original E-sheets?"

### 6. Scope Carve-Outs
Any visible scope excluded from this bid, by others, or owner-furnished? Pricing another sub's scope inflates the bid. Missing a carve-out that IS your scope loses money.
- Ask: "Drawings show fire alarm devices -- is fire alarm in your scope or by the FA sub?"

## Step 3: Present Findings

1. **Gaps Found** -- numbered list of specific questions, each with pricing impact
2. **Assumptions (if no answer)** -- what you'd assume per gap and the risk of that assumption
3. **Ready for /plan2bid:run?** -- yes/no with conditions

Questions must be concrete and project-specific. Never "Can you clarify the scope?" -- instead "The SOW says 'relocate existing receptacles' but not how many -- all 14 on Sheet E-101, or only those in the demo area?"

## Reference

Guidelines: `~/Desktop/Projects/Plan2BidAgent/guidelines/estimation-workflow.md`
