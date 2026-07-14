# /testplan — golden-reference examples

Two committed exemplars that anchor the skill's load-bearing behavior. They are validation goldens (proof
the skill both *scales down* and *scales up*), not runtime inputs — and they live under `docs/` (NOT
`commands/`) so they are never mistaken for skills.

- **`trivial-static-page.example.md`** — proves the **collapse-to-core**: a trivial read-only target must
  omit the ordering/fault catalog, contract-pinning, and mutating recipe fields, with each omission
  justified. *Lean is a success, not a shortfall.*
- **`rich-account-settings.example.md`** — proves the **full machinery**: a mutating + external-boundary
  target derives lenses, authors a real user journey with a business outcome, produces an ordering+fault
  catalog, at least one `BLOCKED` row, and a `READY / NOT-READY` verdict.

A vacuous plan of present-but-empty headings is a FAIL, not a pass — the skill's self-lint (adequacy check)
exists to reject it.
