# Session-correlation assumption tests

Narrow-and-deep **assumption tests** (not unit tests) that prove the load-bearing runtime contracts
behind the bulletproof `pre-compact ↔ /compact ↔ /post-compact-resume` session-correlation fix
(plan: `tmp/ready-plans/2026-05-31-bulletproof-session-correlation.md`). They run against the **real
macOS process table + Terminal.app**, so they live here (not in a normal test suite) and are gated by
an explicit env var.

## What each test proves
| Test | Assumption | Load-bearing because |
|---|---|---|
| `01-own-claude-pid-resolution.sh` | **A1** — anchored-ERE ancestry walk resolves the session's real TUI `claude` (not a node wrapper / `.claude-dotfiles` path / `ucomm`), + its `/dev/ttysN` | the fire-time own-ancestry primary depends on resolving the right process |
| `02-foreground-leader-pid-pinned.sh` | **A3** — pid-pinned foreground-leader check; rejects dead / non-claude / wrong-tty / **sibling-session** pids | rejecting a *sibling* claude on this tty is the exact 04:42Z incident the fix exists to kill |
| `03-pid-identity-reuse-defense.sh` | **A5** — pid+start-time identity; `lstart` normalizer is byte-stable | defeats macOS pid-reuse; a jittery normalizer would false-abort EVERY fire (silent self-DoS) |
| `04-pid-tty-derivation-edge.sh` | **A4** — `ps -o tty=` derivation; no-controlling-tty → fail-closed | a severed/disowned proc must never yield a stale `ttysN` to type into |
| `05-resume-idempotency-marker.sh` | **A6** — one-shot `(sid,nonce)` marker | self-invoke + typed backstop must produce exactly ONE resume; a stale marker must not block the next overnight resume |
| `06-toctou-tty-format-parity.sh` | **P1/P2** — AppleScript `tty of t` == `/dev/`-prefixed `ps` form; verify→match window | format mismatch = EVERY fire silently returns no-matching-tab (single point of total failure) |

## How to run
```bash
# whole suite (halts on first FAIL):
CORRELATION_TESTS_ALLOW_DEV=true bash scripts/hooks/session-correlation-assumptions/run-all.sh

# one test:
CORRELATION_TESTS_ALLOW_DEV=true bash scripts/hooks/session-correlation-assumptions/01-own-claude-pid-resolution.sh
```
Must be run **inside a live Claude Code session in Terminal.app** (tests 01/02/04/06 resolve the
running `claude` process). Test 02's sibling-negatives only exercise when ≥2 sessions are live (it
logs `INFO` and skips them otherwise — not a failure).

## Exit codes
`0` PASS · `1` FAIL (≥1 assertion) · `2` REFUSED (env gate unset) · `3` INFRASTRUCTURE (no claude
ancestor / Terminal not scriptable / hang→124|142).

## Gates
- **Pre-implementation:** all must PASS before `/implement`. A1's outcome (`01`) decides whether the
  fallback registry is needed (per the plan's open fork).
- **Post-ship regression:** re-run after each change to `auto-compact-after-pre-compact.sh`,
  `arm-auto-compact.sh`, `post-compact-primer.sh`, or `lib/auto-compact-sentinel.sh`.

## Fingerprints
Each test writes `<NN>-*.fingerprint.json` with the assumption-relevant facts at PASS time (hop-depth,
tty form, normalized `lstart` sample, format-parity, verify→match window). A future re-run that sees a
changed fingerprint (e.g. ancestry depth > 1, tty form drift) should **re-validate**, not auto-trust.

## Safety
Read-only `ps` probes + temp-dir file logic + a short-lived background `sleep` (test 04, killed on
exit). No production/state mutation. The env gate is an explicit "yes, run against this live machine"
acknowledgement.
