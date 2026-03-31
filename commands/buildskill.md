---
description: Conductor skill for designing and building one new industry-specific command at a time. Loads SKILLSET.md context, reads base skill source files for orchestration design, asks targeted questions, saves a brief for /plan. Use after /skillset to build individual skills within an industry workflow.
argument-hint: "[skill name and/or description, e.g. 'estimate-job generates cost estimates from project specs']"
---

# Buildskill Agent

Design and build one new industry-specific skill. Loads context from `SKILLSET.md`, reads base skill source files to understand how they compose, asks targeted questions, designs the orchestration, and saves a brief for `/plan` to consume.

## CRITICAL: No Code Changes

This skill is for **conversation and brief-writing only**. You must **NEVER**:
- Edit, create, or delete any source code or command files
- Use the Edit, Write, or NotebookEdit tools on project files (except the brief in Step 5)
- Make implementation changes of any kind
- Create the skill `.md` file — that happens through `/plan` → `/implement`

You **may** read any files (skills, code, configs) to inform the design, write the brief file (Step 5), and — with explicit user permission — install or configure tools discovered during research (add MCPs to `~/.claude/mcp.json`, install packages via `npm`/`pip`, modify existing tool configuration files). Do not create new project source files during setup.

## Step 1: Gate Check

Try to read `./SKILLSET.md`.

If it does **not** exist:
```
No SKILLSET.md found in this directory.
Run /skillset first to initialize the skill registry before building skills.
```
**STOP** — do not proceed.

If it exists, continue to Step 2.

## Step 2: Load Context

### 2a. Read SKILLSET.md

Read `./SKILLSET.md` and extract:
- **Industry name** from the `# Skillset:` header
- **Base skills** from the `## Base Skills (Always Available)` table — skill names, categories, descriptions
- **Excluded skills** from the `## Excluded Skills (Permission Required)` table
- **Industry skills** from the `## Industry Skills (This Project)` table — what's already been built
- **Isolation rules** from the `## Isolation Rules` section

### 2b. Read SKILLSET-LOG.md

Read `./SKILLSET-LOG.md` and extract the last 3 `##` date entries for recent session context.

### 2c. Read Existing Briefs

Glob `./tmp/briefs/*.md` — read ALL briefs, not just `*buildskill*` ones. Someone may have used `/discussion` to discuss a skill idea before running `/buildskill`.

For each brief found, extract:
- Skill names being designed
- Orchestration decisions made
- Workflow connections proposed

These are other skills discussed or designed this session — critical for understanding workflow links.

### 2d. Present Context

Output to the user:
```
Context loaded for [industry_name].
Base skills: [N] available | Industry skills: [M] built | Excluded: [K]
Other skills discussed this session: [list from briefs, or 'none']
```

## Step 3: Understand the Skill

### 3a. Get Skill Name

If `$ARGUMENTS` is **empty or not provided**:
- Ask: **"What's the name for this skill? (e.g., 'estimate-job', 'safety-check')"**
- Use the answer as `skill_name`

If `$ARGUMENTS` is provided:
- Parse for the skill name (first word or hyphenated phrase) and initial description
- Output: `"Building: /[skill_name] — [description from args]"`

### 3b. Ask Targeted Questions

Only ask what's not already clear from `$ARGUMENTS`. Skip questions whose answers are obvious from the argument text.

1. **"What should this skill do? What problem does it solve?"**
2. **"When would someone run this? What's the trigger?"**
3. **"What inputs does it need? What outputs does it produce?"**
4. **"Does it need to read or write specific files/artifacts?"**

Gather answers before proceeding to Step 4.

## Step 4: Orchestration Design

### 4-pre. Deep Skill Research

Before designing the orchestration, research the specific problem this skill solves. Create `./tmp/research/` directory if it doesn't exist.

Use the skill description from Step 3 as the research topic and the industry name from Step 2a as the industry context.

Spawn 2-3 research agents in parallel via the Agent tool:

**Agent 1 (tools & integrations):**
  prompt: "Research tools for [skill description] in the [industry] industry.
   Use WebSearch to find and WebFetch to read about:
   - Existing tools, APIs, MCP servers, or libraries that solve this problem
   - Open-source projects that handle this or parts of it
   - SaaS/cloud services available for this
   - Claude MCP servers or AI-native tools for this
   Return: a table of tools (name, type, description, relevance, URL)."

**Agent 2 (best practices & workflows):**
  prompt: "Research best practices for [skill description] in [industry].
   Use WebSearch to find and WebFetch to read about:
   - Industry-standard approaches to solving this problem
   - Recommended workflows and methodologies
   - Common patterns experts use
   - Pitfalls and anti-patterns to avoid
   Return: numbered list of best practices with source URLs."

**Agent 3 (optional — spawn only if the problem involves integration or automation):**
  prompt: "Research integration patterns for [skill description] in [industry].
   Use WebSearch to find and WebFetch to read about:
   - How existing tools integrate with each other for this problem
   - Common automation patterns and pipelines
   - API-to-API workflows
   Return: integration patterns with tool combinations and URLs."

Save full results to: `./tmp/research/YYYY-MM-DD-buildskill-[skill_name].md` using this format:
```
---
date: YYYY-MM-DD
topic: [skill description]
type: buildskill-research
industry: [industry name]
---
# Research: [skill_name] in [industry]
## Executive Summary
[Key findings]
## Tools & Integrations
| Tool | Type | What It Does | Relevance | URL |
|------|------|-------------|-----------|-----|
## Best Practices
[Numbered list with sources]
## Methodologies & Workflows
[Standard workflows]
## Sources
[All URLs]
```

**IF research succeeds:**

Present findings as a batch table:
```
Research findings for [skill description]:

Tools & integrations found:
| # | Tool | Type | What It Does | Could Help With | Set up? | Integrate? |
|---|------|------|-------------|-----------------|---------|------------|
| 1 | [tool1] | MCP | [desc] | [how it helps] | y/n | y/n |
| 2 | [tool2] | API | [desc] | [how it helps] | y/n | y/n |

Best practices:
- [practice 1 with source]
- [practice 2 with source]

Recommended approach:
[Brief synthesis of how research should inform the skill design]

Full research: ./tmp/research/[filename]

Which tools should I set up? Which should be integrated into the skill design?
(e.g., 'set up 1, 3 — integrate 1, 2' or 'none')
```

Wait for user response.

For tools marked "set up":
- MCPs: add to `~/.claude/mcp.json`
- Packages: `npm install` / `pip install`
- Existing config files: modify as needed
- Credentials required: document steps for user
Do NOT create new project source files.

For tools marked "integrate":
Note them for the orchestration design in Steps 4a-4e. These tools become part of the skill's step flow.

Research findings feed directly into Steps 4a-4e:
- Tools to integrate → may become steps in the skill
- Best practices → inform step flow and constraints
- Integrations → shape how the skill connects to external systems

**IF research fails:**
Output: "Research encountered issues — proceeding without external research. You can run `/research-web [topic]` later for a deeper investigation."
Continue to Step 4a without research context.

### 4a. Identify Relevant Base Skills

Scan the base skills list extracted from `SKILLSET.md` in Step 2a. Based on the new skill's purpose and I/O from Step 3, select the skills most likely to be referenced or called by the new skill.

Rank by relevance — pick the **top 3-4** that the new skill will:
- Directly call or reference in its step flow
- Need to understand I/O contracts for (what artifacts they produce/consume)

If more than 4 seem relevant, note the extras — they'll be listed in the brief for `/plan` to read later.

### 4b. Read Source Files (max 3-4)

For each of the top 3-4 relevant base skills, read its actual source file at `~/dotfiles/claude/commands/[path].md`.

Extract from each:
- What it expects as input (arguments, files, context)
- What artifacts it produces (files saved, output format)
- Its step flow (what order things happen)
- Any sub-agents it spawns
- Key constraints or guardrails

If more than 4 skills seemed relevant in 4a, note:
```
Additional skills for /plan to read: /[skill5], /[skill6]
(Listed in the brief — /plan will read these during plan generation)
```

### 4c. Design Orchestration

Based on the source file analysis, design how the new skill should work:
- Which base skills should it call or reference?
- In what order? What can be run in parallel?
- What artifacts flow between steps?
- What user interaction points are needed (confirmations, questions)?
- Does it spawn sub-agents? If so, what type and when?

### 4d. Check Workflow Position

Reason about how this skill connects to other industry skills:
- Read the Industry Skills table from `SKILLSET.md` (what's been built)
- Read any briefs from this session (what's been designed)
- Consider: does this skill feed into, consume from, or run alongside other industry skills?
- Propose workflow connections where they make sense

If an **excluded or other-project skill** would be useful as a reference or pattern:
- Suggest it: "The [excluded-skill] has a pattern that could be useful here. Want me to reference it?"
- **Wait for explicit permission** before using it in the design

### 4e. Present Orchestration Proposal

Output a clear summary for the user:

```
Proposed orchestration for /[skill_name]:

Step flow:
1. [action] — calls /[base-skill] for [reason]
2. [action] — [sequential/parallel] with step 1
3. [action] — produces [artifact]

Base skills referenced: /[skill1], /[skill2], /[skill3]
Workflow links: [connections to other industry skills, or 'standalone']
Artifacts: reads [X], produces [Y]

Does this orchestration look right? Anything to adjust?
```

Wait for user confirmation or adjustments. Iterate until the user is satisfied with the design.

## Step 5: Save Brief

Once the user confirms the orchestration design, save the brief.

### 5a. Determine Filename

Filename: `./tmp/briefs/YYYY-MM-DD-buildskill-[skill_name].md`

If a file with that name already exists, append a counter: `-2`, `-3`, etc.

Create the `./tmp/briefs/` directory if it doesn't exist.

### 5b. Write the Brief

```markdown
# Brief: /[skill-name] Command

## Why
[Problem this skill solves, from Step 3 answers]

## Context
[Industry name and relevant context from SKILLSET.md]
[What industry skills have been built so far and how this skill relates]
[Other skills discussed this session and their workflow connections]

### Research Findings
- **Full research**: ./tmp/research/[filename]
- **Key tools recommended**: [list with brief reasons]
- **Best practices applied**: [practices that inform the skill design]
- **Tools integrated into design**: [tools the user approved for the orchestration]
- **Tools available but not integrated**: [noted for future consideration]

## Orchestration Design
- **Calls**: [list of base skills referenced, with reasons for each]
- **Order**: [step flow — sequential and parallel steps, numbered]
- **Artifacts**: reads [X], produces [Y]
- **Workflow links**: [connections to other industry skills, or 'standalone']
- **Additional skills for /plan to read**: [any beyond the 3-4 read here, or 'none']
- **External tools/APIs**: [any external tools the skill uses, discovered through research]

## Decisions
- [Decision 1] — [reasoning]
- [Decision 2] — [reasoning]

## Skill Specification
- **Name**: /[name]
- **File**: ~/dotfiles/claude/commands/[name].md (or subdirectory if appropriate)
- **Description**: [one-line for frontmatter description field]
- **Argument hint**: [what $ARGUMENTS expects]
- **Trigger**: [when would someone run this]

## REQUIRED: SKILLSET.md Update
> The implementation plan MUST include a final task that:
> 1. Adds this skill to the `## Industry Skills (This Project)` table in ./SKILLSET.md:
>    `| /[name] | [description] | Built | YYYY-MM-DD |`
> 2. Prepends a log entry to ./SKILLSET-LOG.md (using Read + Write, not Edit):
>    `## YYYY-MM-DD`
>    `- Built new skill: /[name]`
>    `- [brief description of what it does]`
> This is NOT optional. The registry must stay current after every skill is built.

## Direction
[1-3 sentences on the agreed approach]
```

If research returned no results or failed, use instead:
```markdown
### Research Findings
No relevant external tools or practices found — skill built from first principles.
```

## Step 6: Prompt Next Step

Output:
```
Brief saved to ./tmp/briefs/YYYY-MM-DD-buildskill-[skill_name].md

The brief includes:
- Skill specification and orchestration design
- Base skill I/O analysis for correct composition
- REQUIRED: SKILLSET.md update instruction (will execute during /implement)

Ready for planning? Run:
/plan [skill_name] skill

Note: When reviewing the generated plan, verify it includes a final
task to update SKILLSET.md and SKILLSET-LOG.md with the new skill entry.
```

---

## Notes

- This skill is **conversation only** — it never creates the skill file itself. That flows through `/plan` → `/implement`.
- The brief's `## REQUIRED: SKILLSET.md Update` section is the mechanism that keeps the skill registry current. If this section is missing or vague, the registry will drift.
- Read at most **3-4 base skill source files** during the conversation. If more are relevant, list them in the brief for `/plan` to read during plan generation.
- Read **all** briefs in `./tmp/briefs/`, not just `*buildskill*` ones — `/discussion` briefs about skills are equally important for workflow context.
- The isolation rules from `SKILLSET.md` apply: base skills are free to reference, excluded/other-project skills require permission.
- Deep research runs automatically before orchestration design. Results are saved to `./tmp/research/` and key findings are included in the brief for `/plan`.
- If research fails or returns no results, the skill is designed without external research. This is noted explicitly in the brief.
- Tool setup (MCPs, packages, existing configs) is allowed with explicit user permission, even though this is otherwise a conversation-only skill. Do not create new project source files during setup.

Skill to build: $ARGUMENTS
