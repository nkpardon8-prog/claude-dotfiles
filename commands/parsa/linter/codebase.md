---
allowed-tools: Task, Bash(npm run typecheck:*), Bash(npm run lint:*), Bash(npx tsc:*), Bash(npx eslint:*), TodoWrite
description: Fix all TypeScript type errors and ESLint warnings in parallel using multiple specialized agents
---

Fix all TypeScript type errors and ESLint warnings in the codebase using multiple specialized agents working in parallel.

## 1. Initial Analysis Phase

First, detect the project's available commands by reading `package.json`, then run diagnostics to identify all issues:

```bash
# Detect available scripts
cat package.json | grep -A 50 '"scripts"'

# Run TypeScript type checking (detect the correct command from package.json scripts,
# e.g., `npm run typecheck`, `npx tsc --noEmit`, or the project's equivalent)
<run the project's typecheck command>

# Run ESLint with warnings
# (detect from package.json scripts, e.g., `npm run lint`, `npx eslint . --max-warnings=0`)
<run the project's lint command> --max-warnings=0
```

Capture and categorize all errors and warnings by type:
- Type errors (TS2xxx errors)
- Unused variables and imports
- React Hooks dependency issues (if applicable)
- Missing type definitions
- Date/Time type mismatches
- Other linting warnings

## 2. Multi-Agent Parallel Fix Strategy

Launch multiple specialized agents IN PARALLEL to fix different categories of issues. Each agent should be given specific files and error types to focus on.

### Agent Task Definitions

**Type Safety Agent:**
```
Focus: Fix TypeScript type errors
Files: All files with TS2xxx errors
Tasks:
- Fix "used before declaration" errors (TS2448, TS2454)
- Fix "possibly undefined" errors (TS2532)
- Fix "property does not exist" errors (TS2339)
- Add proper type annotations
- Fix type mismatches and incompatible assignments
```

**Unused Code Cleanup Agent:**
```
Focus: Remove unused code
Files: All files with unused variable/import warnings
Tasks:
- Remove unused imports (organize imports)
- Remove unused variables
- Remove unused function parameters
- Clean up dead code
- Keep code that might be used in future (commented with TODO)
```

**React Optimization Agent (if project uses React):**
```
Focus: Fix React-specific issues
Files: All React component files with hook warnings
Tasks:
- Wrap functions in useCallback where needed
- Add proper dependency arrays to useEffect
- Fix exhaustive-deps warnings
- Optimize re-renders with useMemo where appropriate
- Fix component prop type issues
```

**Data Type Consistency Agent:**
```
Focus: Fix date/time and data type issues
Files: Data files, mock/fixture files, and any file with type mismatch errors
Tasks:
- Convert string dates to Date objects where required
- Fix type mismatches in mock/test data
- Ensure consistent data types across interfaces
- Fix buffer and binary type issues
```

**Code Quality Agent:**
```
Focus: General code quality improvements
Files: All remaining files with warnings
Tasks:
- Fix formatting issues
- Add missing semicolons
- Fix any remaining ESLint warnings
- Ensure consistent code style
- Fix import order
```

## 3. Parallel Execution

Use the Task tool to launch ALL agents simultaneously:

```
Launch all 5 agents in parallel with their specific file lists and error categories.
Each agent should:
1. Read the assigned files
2. Fix their specific category of issues
3. Verify fixes compile without errors
4. Return a summary of changes made
```

## 4. Verification Phase

After all agents complete, re-run the project's typecheck and lint commands (detected from `package.json` in step 1):

```bash
# Verify TypeScript compilation
<run the project's typecheck command>

# Verify no lint warnings remain
<run the project's lint command> --max-warnings=0
```

## 5. Summary Report

Generate a comprehensive report showing:
- Total issues fixed by category
- Files modified
- Any issues that couldn't be automatically fixed
- Suggestions for manual review

## Arguments Support

Handle optional arguments:
- `--errors-only`: Only fix TypeScript errors, skip warnings
- `--no-unused`: Don't remove unused code
- `--no-parallel`: Run agents sequentially instead of in parallel
- `--dry-run`: Show what would be fixed without making changes
- `--files=<pattern>`: Only fix files matching pattern

## Important Notes

1. **Preserve Functionality**: Never break existing functionality while fixing issues
2. **Respect Intent**: Keep commented code that has TODO markers
3. **Type Safety**: Prefer proper types over `any` type
4. **Performance**: Use React optimization hooks judiciously, not everywhere
5. **Verification**: Always verify changes compile and pass tests

Execute this comprehensive fix strategy now, ensuring all type and lint issues are resolved efficiently through parallel agent execution.
