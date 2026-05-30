# /gemini is currently NOT WORKING — debug note (2026-05-30)

**Status: BROKEN.** A `/gemini` call hangs indefinitely and never returns output. Written for a
fresh agent to debug. Treat this as untrusted notes — verify each claim yourself.

## Symptom (observed)
- Invoked the wrapper with a ~2KB free-text analysis prompt (no stdin context), best model:
  ```
  GEMINI_MODEL=gemini-3-pro-preview GEMINI_TIMEOUT=400 \
    bash ~/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh \
    /tmp/gemini-out.$$ "$(cat /tmp/gemini-prompt.$$)" "$PWD"
  ```
- Output file stayed **0 bytes** for many minutes.
- The wrapper processes were **still ALIVE and idle** long after (PIDs seen: 21734 parent zsh,
  21738/21747 the `gemini-invoke.sh` bash) — i.e. it HANGS, it does not crash or error out.
- `GEMINI_TIMEOUT=400` did NOT fire (process outlived it).

## Environment (verified)
- `gemini` = `/opt/homebrew/bin/gemini`, version **0.43.0**.
- Auth: OAuth present — `~/.gemini/oauth_creds.json` (1794B), `google_accounts.json`, `settings.json`.
  `GEMINI_API_KEY` is **NOT set** (relying on OAuth). Wrapper header notes OAuth works "as of
  2026-06-18 — after that, export GEMINI_API_KEY"; today is 2026-05-30, so OAuth *should* be valid.
- Wrapper relocates config to an isolated home (`$XDG_CACHE_HOME/claude-gemini-subagent/.gemini`,
  symlinks oauth/accounts/settings, strips GEMINI.md). That dir exists and is populated.

## Top hypotheses (ranked)
1. **Wrapper timeout is a no-op on macOS (HIGH).** Earlier, a bare `timeout ...` call returned
   `zsh: command not found: timeout` — stock macOS has no GNU `timeout` (it's `gtimeout` via
   `brew install coreutils`, or absent). If `gemini-invoke.sh` implements `GEMINI_TIMEOUT` via
   `timeout`/`gtimeout`, the cap silently never applies and any slow/hung `gemini` call hangs forever.
   → **`grep -n "timeout" ~/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh`** and check whether
   it uses `timeout`/`gtimeout` without a fallback. This is the most likely root cause of the *hang*
   (separate from whatever makes the underlying call slow).
2. **Invalid/unavailable model id `gemini-3-pro-preview` (HIGH).** This id was NEVER verified — a
   `gemini models list` attempt returned a *hallucinated prose* answer (the CLI treated "models list"
   as a prompt), not a real model list. A bad `-m` value may cause the CLI to retry/hang instead of
   erroring. → Test the id directly (below) against the account default and a known-good `gemini-2.5-pro`.
3. **OAuth token expired / quota / rate-limit on the frontier model (MED).** Silent retry/backoff loop.
4. **Frontier model genuinely slow on a 2KB prompt (LOW).** Possible but >several min at 0 bytes
   reads as a hang, not latency.

## Diagnostic steps for the next agent
1. **Inspect the timeout mechanism:** `grep -n "timeout\|gtimeout\|GEMINI_TIMEOUT" lib/gemini-invoke.sh`.
   If it relies on `timeout`, add a `gtimeout`-then-`perl`-alarm fallback, or background+kill. Confirm
   `command -v timeout gtimeout` on this Mac (both likely absent).
2. **Verify the model id** with a HARD wall-clock cap (don't trust the wrapper):
   ```bash
   # macOS-safe cap via perl alarm (no `timeout` dependency):
   for M in "" gemini-2.5-pro gemini-3-pro-preview; do
     echo "== model='${M:-default}' =="
     perl -e 'alarm shift; exec @ARGV' 40 gemini --approval-mode plan --skip-trust -o text \
       ${M:+-m "$M"} -p "reply with the single word OK" 2>&1 | head -5
     echo "(exit/elapsed above)"
   done
   ```
   - default or `gemini-2.5-pro` returns "OK" but `gemini-3-pro-preview` hangs/errors → bad model id.
     Fix: set `GEMINI_MODEL` to a real id (confirm via OpenRouter/Google docs or `gemini`'s real
     model-list command for v0.43.0), or fall back to default.
3. **Kill any stale hung procs:** `pkill -f gemini-invoke.sh` (and check `ps aux | grep gemini`).
4. **Auth sanity:** if even the default model hangs, run `gemini` interactively once to confirm the
   OAuth session is alive / re-auth, or `export GEMINI_API_KEY`.

## Fix priorities
- (a) Make the wrapper timeout actually enforce on macOS (no silent no-op) — a hung sub-agent should
  ALWAYS return `[timeout]`, never hang the caller.
- (b) Validate/whitelist `GEMINI_MODEL` ids (reject unknown ids fast instead of hanging).
- (c) Document the real best-model id for gemini CLI v0.43.0 in the README.

— left by the Claude session debugging the `/mission` design, where `/gemini` was being used for a
third-opinion model comparison and hung. The comparison proceeded without it.
