# /user:tdd — Test-Driven Development Workflow

Enforce a RED→GREEN→REFACTOR cycle for implementing a feature or fix.

## Usage

`/user:tdd [feature description]` — describe what you're building via $ARGUMENTS

If no description provided, ask: "What feature or fix are you implementing?"

## Phase 1: RED — Write a Failing Test

Write a test that describes the desired behavior BEFORE writing any implementation code.

1. Identify the right test file (create if needed, follow project conventions)
2. Write the test(s) that assert the expected behavior
3. Run the test suite to confirm it FAILS:

```bash
# Detect and run test command
npm test / bun test / cargo test / pytest
```

**GATE:** The test MUST fail. If it passes, the test isn't testing new behavior — rewrite it.

Show the user: "RED phase complete. Test fails as expected: [failure message]"

## Phase 2: GREEN — Write Minimum Code to Pass

Write the simplest implementation that makes the failing test pass. Do NOT:
- Add features beyond what the test requires
- Optimize prematurely
- Refactor existing code
- Write additional tests

Run the test suite again:

```bash
npm test / bun test / cargo test / pytest
```

**GATE:** All tests MUST pass (not just the new one). If any test fails, fix the implementation.

Show the user: "GREEN phase complete. All tests passing."

## Phase 3: REFACTOR — Clean Up While Green

Now improve the code quality while keeping all tests green:
- Remove duplication
- Improve naming
- Simplify logic
- Extract functions if needed

After each refactoring change, re-run tests:

```bash
npm test / bun test / cargo test / pytest
```

**GATE:** Tests must stay green throughout refactoring. If a test breaks, undo the last change.

## Cycle Complete

Report:
- What was tested
- What was implemented
- What was refactored
- Test count (new tests added / total)
- Coverage (if available: `npx c8 report` / `cargo tarpaulin` / `pytest --cov`)

Ask: "Ready for another TDD cycle, or are we done with this feature?"
