---
description: Session initializer and skill registry manager for industry-specific projects. Creates or loads SKILLSET.md + SKILLSET-LOG.md, dynamically scans available skills, enforces cross-industry isolation rules. Use at the start of any industry skill-building session.
argument-hint: "[optional: industry name for first-run, e.g. 'construction']"
---

# Skillset Agent

Initialize or resume an industry-specific skill-building session. Manages two project-level files:
- `SKILLSET.md` — Skill registry, isolation rules, industry context
- `SKILLSET-LOG.md` — Running session history

## Step 1: Detect Mode

Check for existing files in the current working directory:

1. Try to read `./SKILLSET.md`
2. Try to read `./SKILLSET-LOG.md`

**Determine mode:**
- **Neither exists** → FIRST-RUN mode (go to Step 2)
- **Both exist** → RESUME mode (go to Step 3)
- **One exists, other missing** → RECOVERY mode:
  - Read the existing file and extract the industry name from the `# Skillset:` or `# Skillset Log:` header
  - Recreate the missing file using the extracted industry name and the appropriate template from Step 2
  - Then proceed as RESUME mode (go to Step 3)

## Step 2: First-Run Flow

### 2a. Get Industry Info

If `$ARGUMENTS` is provided and this is a first run:
- Use `$ARGUMENTS` as the industry name (skip the industry prompt)

Otherwise:
- Ask the user: **"What industry/domain is this skillset for?"**

Then ask: **"Brief description of what you're building in this space?"**

### 2b. Run Dynamic Skill Scan

Execute the scan from Step 4 to build the initial base skills table.

### 2c. Create SKILLSET.md

Write `./SKILLSET.md` using this template, populated with scan results:

```markdown
# Skillset: [Industry Name]

## Industry Context
[User-provided description from 2a]

## Base Skills (Always Available)
| Skill | Category | Description |
|-------|----------|-------------|
| [populated from dynamic scan — one row per base skill] | | |

## Excluded Skills (Permission Required)
> These skills are not available by default. Claude must ask for explicit
> permission before referencing or integrating any of these.

| Skill | Reason |
|-------|--------|
| [populated from exclusion list] | |

## Industry Skills (This Project)
| Skill | Description | Status | Date Added |
|-------|-------------|--------|------------|
| (none yet) | | | |

## Other Industry Skills (Available With Permission)
> Skills from other projects are visible for inspiration but cannot be
> referenced or integrated without explicit user permission.

| Project | Skills Available | Notes |
|---------|-----------------|-------|
| (none tracked yet) | | |

## Isolation Rules
- **Base skills**: Free to reference, use, and build upon in any new skill
- **This project's skills**: Free to extend, modify, and compose
- **Other project skills**: Ask before referencing. Claude may suggest cross-references but must get permission before acting on them
- **Excluded skills**: Require explicit permission to reference. Claude may ask "Would [excluded-skill] be useful here?" but must not use it without a yes
```

### 2d. Create SKILLSET-LOG.md

Write `./SKILLSET-LOG.md` using this template:

```markdown
# Skillset Log: [Industry Name]

> Running history of sessions, decisions, and skills built for this project.
> Newest entries first. Referenced by `/skillset` on each load.

---

## [TODAY'S DATE: YYYY-MM-DD]
- Initialized skillset for [Industry Name]
- Base skills: [N] loaded
- Industry skills: 0
- Excluded skills: [K]
- Notes: [Industry context from user]
```

Then proceed to Step 5 (skip Steps 3, 4, and 6 — scan already ran in 2b, and the log was just created in 2d with the initial entry).

## Step 3: Resume Flow

### 3a. Load Context

Read `./SKILLSET.md` and extract:
- Industry name (from `# Skillset:` header)
- Current base skills (from `## Base Skills` table)
- Current exclusions (from `## Excluded Skills` table)
- Industry skills built so far (from `## Industry Skills` table)

Read `./SKILLSET-LOG.md` and extract the last 3 `##` entries for recent context.

### 3b. Present Loaded State

Output to user:
```
Loaded [industry] skillset.
Base skills: [N] | Industry skills: [M] | Excluded: [K]

Recent activity:
- [last 3 log entries, one line each]
```

Then proceed to Step 4.

## Step 4: Dynamic Skill Scan

**This step runs on EVERY invocation** (both first-run via Step 2b, and resume after Step 3).

### 4a. Scan All Skills

```bash
Glob ~/dotfiles/claude/commands/**/*.md
```

For each file found:

1. **Convert file path to skill name:**
   - Strip everything up to and including `commands/`
   - Strip the `.md` suffix
   - Replace all `/` with `:`
   - Prepend `/`
   - Examples:
     - `commands/commit.md` → `/commit`
     - `commands/parsa/cl/create_plan.md` → `/parsa:cl:create_plan`
     - `commands/parsa/review/principles/clarity.md` → `/parsa:review:principles:clarity`

2. **Extract description:**
   - Read the first 10 lines of the file
   - If YAML frontmatter exists (starts with `---`), extract the `description:` field
   - If no frontmatter, use the first `# heading` text as description
   - Fallback: "(no description)"

3. **Infer category from path and description:**
   - Path contains `linter` → Quality
   - Path contains `refactor` → Refactor
   - Path contains `review` → Review
   - Path contains `cl/commit` or top-level `commit` or `prepare-pr` or `checkpoint` → Git
   - Description contains "plan" or "architect" → Planning
   - Description contains "implement" or "execute" → Execution
   - Description contains "research" or "learn" → Research
   - Description contains "deploy" or "netlify" → Deploy
   - Description contains "bug" or "investigate" or "debug" → Debug
   - Description contains "test" or "tdd" or "verify" → Quality
   - Description contains "discuss" → Planning
   - Description contains "docs" or "documentation" → Docs
   - Fallback: General

### 4b. Default Exclusion List

The following skills are **always excluded by default** — never prompt the user about these:

```
/dock, /admet, /prep-target, /screen, /dashboard
```

Reason: MoleCopilot medical/molecular docking tools.

Also exclude the `/skillset` command itself from the table (don't list yourself).

### 4c. Compare and Detect Changes

Compare the scanned skills against the current `SKILLSET.md` content:
- Skills in the scan but NOT in the base table and NOT in the exclusion table → **new/unclassified**
- Skills in the base table but NOT in the scan → **removed from dotfiles**
- Skills in the exclusion table but NOT in the scan → **removed from dotfiles**

### 4d. Handle New Skills

If new/unclassified skills are found, present them as a **batch**:

```
New skills detected since last scan:

| # | Skill | Description | Classify as |
|---|-------|-------------|-------------|
| 1 | /new-skill | Does X | base / excluded ? |
| 2 | /other-skill | Does Y | base / excluded ? |

For each, should it be BASE (available in all projects) or EXCLUDED (requires permission)?
Example response: "1 base, 2 excluded" or "all base"
```

Wait for user response. Update `SKILLSET.md`:
- Add new base skills to the `## Base Skills` table
- Add new exclusions to the `## Excluded Skills` table

### 4e. Handle Removed Skills

If skills were removed from dotfiles:
- Output: "Note: `/old-skill` no longer found in dotfiles — removing from registry."
- Remove from whichever table they were in

### 4f. Update SKILLSET.md

After classification, update the `## Base Skills` and `## Excluded Skills` tables in `./SKILLSET.md`.

**Important:** Do NOT overwrite the `## Industry Context`, `## Industry Skills`, `## Other Industry Skills`, or `## Isolation Rules` sections — those are user-managed content. Only update the Base Skills and Excluded Skills tables.

Use `Read` to get the current file, then `Write` to save the updated version.

## Step 5: Inject Isolation Rules

Read the `## Isolation Rules` section from `./SKILLSET.md` and output it as active session context:

```
ISOLATION RULES ACTIVE FOR THIS SESSION
(loaded from ./SKILLSET.md)

- Base skills: Free to reference, use, and build upon
- This project's industry skills: Free to extend and compose
- Other project/industry skills: Visible for inspiration. I will suggest
  cross-references when potentially useful, but will NOT reference or
  integrate without your explicit permission
- Excluded skills (medical/molecular + any user-excluded): Require explicit
  permission to reference
```

These rules govern behavior for the remainder of this session.

## Step 6: Update SKILLSET-LOG.md

Read `./SKILLSET-LOG.md` in full.

Prepend a new entry **after the header block** (after the `---` separator, before the first `##` entry):

```markdown
## [TODAY'S DATE: YYYY-MM-DD]
- Session loaded for [industry]
- Base skills: [N] | Industry skills: [M] | Excluded: [K]
- New skills detected: [list of new skill names, or 'none']
- Changes: [skills added/removed/reclassified, or 'none']
```

**Write the entire file back** using `Read` + `Write` (not `Edit`). This avoids fragile string-matching for prepend operations.

## Step 7: Output Summary

```
Skillset loaded: [Industry Name]
Base skills: [N] available
Industry skills: [M] built
Excluded skills: [K]
New skills detected: [list or 'none']

Isolation active — base skills are free to use. Other industry skills
require permission. I'll suggest cross-references when helpful.

Ready to work. What are we building?
```

---

## Notes

- `SKILLSET.md` lives in the **project working directory** (not `~/.claude/`). It is the source of truth for this project's skill context and should be git-tracked.
- The dynamic scan always uses `~/dotfiles/claude/commands/` as the source for available skills.
- On resume, preserve all user-written sections (`Industry Context`, `Industry Skills`, `Other Industry Skills`, `Isolation Rules`). Only the `Base Skills` and `Excluded Skills` tables are machine-managed.
- If both files are perfectly up to date and no new skills are detected, the command simply loads context and updates the log — minimal output, fast resume.
