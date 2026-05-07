# god-review changelog

## 2026-05-06 — Phase E fix pass
- Fixed Phase 3 while-loop split-across-fences (catastrophic)
- Fixed glob_to_regex algorithm + added self-test (catastrophic)
- Wired --ruthless spawn block to actual Agent invocation (catastrophic)
- Added round-loop counters to write_env whitelist
- Wired 4 new failure-class principles (dead-end, info-loss, contradiction, gap) into ALWAYS_ON_PRINCIPLES
- Fixed HAS_BENCH_SCRIPT python paren imbalance (audit was wrong, ast.parse confirmed)
- Fixed FROZEN_UNITS_CAP self-referential default
- Renamed phantom ARCH_JSON references to ARCH_OUTPUT

## 2026-05-05 — Initial fix pass + 4 new failure-class lenses
- 21 commits across Wave 1 + Wave 2 (Implementer S Groups 1-4)
- See plan: tmp/done-plans/2026-05-05-god-review-fixes-plus-second-review.md

## 2026-05-04 — Initial /god-review v1 ship
- See plan: tmp/done-plans/2026-05-04-god-review-command.md
