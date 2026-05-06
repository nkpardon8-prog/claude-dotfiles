---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for violations of the Self-Contained Components principle (stack-gated: HAS_UI_PROJECT)
argument-hint: "[scope]"
---

# /god-review:principles:self-contained — Self-Contained Components

**Stack gate:** This principle self-skips if `HAS_UI_PROJECT` is not detected.

## Stack Gate Check

In Phase 1, run:
```bash
HAS_UI_PROJECT=$(find . -name "*.tsx" -o -name "*.jsx" 2>/dev/null | grep -v node_modules | grep -v .git | head -1)
```

If `HAS_UI_PROJECT` is empty: output "(skipped — no UI project detected)" and exit.

## The Principle

Temporary, optional, or removable UI elements should be self-contained. Removing or adding the component should only require touching ONE file (the parent that renders it). If deletion requires reverting changes in three or more unrelated files, the component was not self-contained.

**Self-contained = easy to add, trivial to remove.**

**Problems with non-self-contained components:**
- Removing a feature requires changes across multiple files — easy to miss one
- Creates hidden dependencies between files that appear unrelated
- Makes A/B testing or feature flags harder to implement safely
- Increases regression risk when removing temporary features

## Why This Matters

- Failure mode #9 (dead-code danger): if a component touches 5 files when added, removing it also requires reverting all 5 — agents miss the side-effect files and leave orphaned offsets/padding/state
- Failure mode #5 (no rollback): non-self-contained components make rollback multi-file → multi-file → HUMAN_GATE territory
- Failure mode #13 (tangled commits): adding a "simple banner" that silently modifies navbar, layout padding, and CSS becomes a tangled multi-concern change

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #5, #9, #13

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Run stack gate check above — if `HAS_UI_PROJECT` is empty, skip and output "(skipped)"
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only`

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.jsx" | grep -v node_modules | grep -v .git | head -200
# Look for temporary/optional component keywords
git diff main...HEAD 2>/dev/null | grep -i -E "(banner|promo|temporary|feature.?flag|announcement|modal|toast|overlay|alert)" || true
```

Use TodoWrite to track candidates to analyze.

## Phase 2: Identify Candidates

### 2.1 Identify Temporary/Optional Components

Look for:
- Promotional banners
- Announcement bars
- Feature flags or toggles
- A/B test components
- Seasonal or event-specific UI
- Beta/alpha badges
- Temporary notices or warnings
- Modals that may be removed later

### 2.2 Check for Cross-File Dependencies

For each temporary component, ask:
- Does adding this component require changes to OTHER files?
- If this component file were deleted, what other files would need reverting?
- Are there hardcoded offsets, paddings, or margins in other files because of this?
- Are there imported constants from this component used in other components?
- Is there state threaded through multiple parent levels to accommodate this?

**Common violation patterns:**

```tsx
// VIOLATION — Banner requires manual offset in Navbar
// Banner.tsx
export function Banner() {
  return <div className="fixed top-0">...</div>;
}

// Navbar.tsx — MANUALLY changed from top-0 to top-10
<nav className="fixed top-10">...</nav>

// Layout.tsx — MANUALLY changed padding
<div className="pt-28">...</div>
```

```tsx
// CORRECT — Banner sets CSS variable, other components use fallback
// Banner.tsx
useEffect(() => {
  document.documentElement.style.setProperty('--banner-height', '2.5rem');
  return () => document.documentElement.style.removeProperty('--banner-height');
}, []);

// Navbar.tsx — uses fallback, NO changes needed when banner is added/removed
<nav style={{ top: 'var(--banner-height, 0px)' }}>...</nav>
```

**Other violation patterns:**
- Scattered configuration: feature height constant in `constants.ts` imported by both `Navbar.tsx` and `Layout.tsx`
- Required prop threading: parent passes `hasBanner` prop down to child, child adjusts layout based on it
- Global CSS class added to `globals.css` specifically for this one component

### 2.3 Evaluate Removal Complexity

Simulate removal:
1. If this component file were deleted, what would immediately break?
2. How many files reference this component or its constants directly?
3. Are there CSS or style changes in unrelated files that depend on this component's presence?
4. Count files needing changes for removal: 1 = good, 2-3 = warn, 4+ = fail

## Phase 3: Deep Analysis

For each candidate:
1. Read the component file and all files it was noted to touch
2. Confirm the coupling is real (not just a coincidental nearby change)
3. Assess whether CSS variables, spacer elements, or cleanup-on-unmount patterns would eliminate the cross-file dependencies
4. Consider if the component is genuinely permanent vs temporary — permanent shared components naturally couple with other files (a global `Navbar` IS meant to affect layout)

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Self-Contained Components Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL | skipped}

## Summary

{One sentence assessment}

## Temporary/Optional Components Found

| Component | File | Purpose |
|-----------|------|---------|
| {name} | {path} | {what it does} |

## Self-Containment Analysis

### {Component Name}

**Files that would need changes if removed:**
- {file1}: {what would need reverting}
- {file2}: {what would need reverting}

**Removal complexity:** {1 file | 2-3 files | 4+ files}

**Issues Found:**
| Issue | Location | Fix | Severity |
|-------|----------|-----|----------|
| Hardcoded offset | {file:line} | Use CSS variable with fallback | likely |
| Manual padding | {file:line} | Component should include spacer | investigate |

## Recommendations

### Required Changes

{List specific changes to make component self-contained}

### Self-Containment Techniques

**CSS Variables with Fallbacks:**
```tsx
// Component sets variable
document.documentElement.style.setProperty('--component-height', '40px');
// Other components use fallback — no changes needed
style={{ top: 'var(--component-height, 0px)' }}
```

**Spacer Elements:**
```tsx
// Component includes its own spacer
<>
  <div className="fixed top-0">Content</div>
  <div style={{ height: COMPONENT_HEIGHT }} aria-hidden="true" />
</>
```

**Cleanup on Unmount:**
```tsx
useEffect(() => {
  document.documentElement.style.setProperty('--my-var', value);
  return () => document.documentElement.style.removeProperty('--my-var');
}, []);
```
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/self-contained-findings.md`
2. Print PASS/WARN/FAIL/skipped summary with number of non-self-contained components and files required for removal

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: All temporary components can be removed by deleting one file and one import line in the parent; no cross-file CSS/state coupling
- WARN: Minor dependencies exist (1-2 additional files) and are documented; CSS variable approach not used but coupling is low-risk
- FAIL: Removing the component requires changes to 3 or more files; hardcoded offsets or constants scattered across unrelated files; state threaded through multiple levels of the component tree

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full UI file set if empty).
