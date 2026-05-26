# Gemini wrapper — assumption tests

These prove the **runtime contract** of `lib/gemini-invoke.sh` against the real Gemini
CLI — the things text review and `gemini --help` cannot settle. They are both a
**pre-flight gate** (run before trusting the wrapper) and a **regression catcher**
(re-run after any change to the wrapper or after a Gemini CLI upgrade).

## Run

```bash
GEMINI_ATEST_ALLOW_DEV=true bash run-all.sh        # all, halts on first problem
GEMINI_ATEST_ALLOW_DEV=true bash 00-unavailable-fallback.sh   # one
```

All PASS = green light. The suite halts on the first FAIL or INFRA.

## What each proves

| # | Proves | Needs auth? |
|---|--------|-------------|
| 00 | `[unavailable]`/`[empty]` fallback + "never block a caller" (exits 0 on missing/silent binary) | No — always runnable |
| 01 | Headless `-p` returns real text on the configured auth (free AI Pro OAuth / `GEMINI_API_KEY`) | Yes |
| 02 | `--approval-mode plan` actually suppresses tool execution (with a `--yolo` positive control proving execution is otherwise possible) | Yes |
| 03 | Wrapper does not hang on an untrusted workspace dir (`--skip-trust` + timeout) | Partial |
| 04 | Wrapper's stdin→context channel works (non-TTY branch + `head -c` cap), with a no-stdin negative control | Yes |

## Exit codes

- `0` PASS · `1` FAIL (contract broken) · `2` REFUSED (gate not set) · `3` INFRA / not-authenticated (couldn't run).

Before you authenticate, expect `00` to PASS and the suite to halt at `01` with an
**INFRA** message telling you to log in. That is correct — it separates "not set up
yet" from "set up but broken."

## Authenticate first

```bash
gemini            # choose "Sign in with Google", use your AI Pro account
```
Then re-run `run-all.sh`. (After 2026-06-18, the free CLI path ends — `export
GEMINI_API_KEY=...` instead. See `../README.md`.)

## Safety

Gated by `GEMINI_ATEST_ALLOW_DEV=true`. Test 02 runs `--yolo` ONLY inside a fresh
`mktemp` dir with a narrow create-a-file prompt, cleaned in a trap. All tests are
idempotent, self-cleaning (`mktemp` + trap), and use per-run UUIDs.

## Deferred (intentionally not tested)

- **Config-dir isolation / foreign `GEMINI.md` canary.** Originally proposed, deferred
  because `--approval-mode plan` makes tool execution structurally impossible — a foreign
  `GEMINI.md` can at most bias review *text*, never execute. The global `~/.gemini/GEMINI.md`
  was also sanitized. Relocating the config dir (`GEMINI_CLI_HOME`) risks breaking OAuth
  for no safety gain, so it's not the default. Test 02 covers the actual hazard (execution).
