# Update Claude Docs

**Automatically update all CLAUDE.md files with current codebase patterns.**

Read-only analysis in each directory, updates documentation files.

## What This Does

Launches parallel subagents to update CLAUDE.md files across the codebase with current patterns, conventions, and architecture.

## Process

### 1. Discover CLAUDE.md Locations

First, discover all CLAUDE.md files in the project (excluding node_modules):

```bash
find . -name "CLAUDE.md" -not -path "*/node_modules/*"
```

Spawn one agent per discovered CLAUDE.md file.

### 2. Agent Task

Each agent in its relative directory:

**Analyze:**
- Current file structure
- Established patterns in code
- Import conventions
- Architecture decisions
- Tech stack versions

**Update:**
- Add missing patterns
- Update outdated conventions
- Include concrete examples from actual files
- Add references to exemplar implementations
- Remove obsolete information

**Preserve:**
- Existing structure
- Core instructions
- User-specific configurations
- Working conventions

### 3. Report Summary

After all agents complete:

```markdown
## Updates Summary

### Root CLAUDE.md
- Added: [patterns/sections]
- Updated: [outdated info]
- Preserved: [core instructions]

### <path>/CLAUDE.md
- Added: [patterns/sections]
- Updated: [outdated info]

[... for each discovered location ...]

## Next Steps
- Review git diff to verify changes
- Test that patterns reflect current codebase
- Commit updates if satisfied
```

## Command Arguments

- `--location <path>`: Update specific CLAUDE.md only
- `--dry-run`: Show what would be updated without modifying

## Example Usage

```bash
# Update all CLAUDE.md files (auto-discovered)
/update-claude-docs

# Update specific location
/update-claude-docs --location src/api
```

## Success Checklist

- [ ] CLAUDE.md files discovered via `find`
- [ ] Subagents launched in parallel (one per file)
- [ ] Each agent analyzes its relative directory
- [ ] Files updated with current patterns
- [ ] Summary report generated
- [ ] Changes reviewable via git diff

---

**Use this command periodically to keep documentation aligned with evolving codebase patterns.**
