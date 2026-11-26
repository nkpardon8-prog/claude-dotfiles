# Code Quality - how we write, fix and test code

Name the task type first and follow its recipe. Report the proof, not the effort.

## Recipes
- **Bug fix:** reproduce it; write the smallest test that fails for the right reason and watch it fail;
  make the smallest fix; watch it pass. No cheap test path: use the closest executable check (script,
  repro command, browser run). No new test beats a bad one.
- **Refactor:** behavior stays the same. Pin it first (characterization test or equivalence check; a
  type-check is not a pin). Delete before you add. When an API changes, migrate every caller and delete
  the old one in the same change; a shim only when rollout order forces it, with an owner and a removal
  task. Prove equivalence on the real artifact. If the result is not easier to read, revert it.
- **Feature:** name the data shape first and make invalid states unrepresentable (a union or state
  machine over loose booleans, a table over branching). Then build, then verify on the real surface.

## Tests
Judge each test with two imagined edits: break the behavior (it must fail) and change only the
internals (it must still pass). Assert what callers observe; derive expected values from the
requirement, not from the code under test.

## Root causes
Fix where the system first went wrong. Retries, timers, extra guards, swallowed errors and clamped
values usually hide a bug. Fix the pattern everywhere it occurs. After two failed fixes, write down the
premise they shared and test it before a third.

## Types
No casts to silence the compiler (`as any`, `as unknown as`). Parse outside data at the boundary into a
typed model. Handle every variant exhaustively.

## Comments
A comment says what the code cannot: an outside system's quirk, or a safety, privacy or clinical
reason, linked to the test or doc that proves it. No history: no dates, review rounds, phase tags or
line numbers. "For now" or "known limitation" names the tracked item.

## Claims and loops
Label claims as measured, inferred or guessed. A repeated agent loop needs an honest completion test, a
hard iteration cap, and a fresh agent per round with its state kept in files.
