# Gemini sub-agent — changelog

Mirrors the format used by `god-review/CHANGELOG.md`: dated entries, newest first,
each explaining *what* changed and *why* it mattered.

## 2026-05-26

### Output hygiene: relocate `GEMINI_CLI_HOME` to suppress global `GEMINI.md` leak
- **What:** The wrapper now sets `GEMINI_CLI_HOME=$GEMINI_SUBAGENT_HOME`
  (default `~/.cache/claude-gemini-subagent`), symlinking `oauth_creds.json`,
  `google_accounts.json`, and `settings.json` from `~/.gemini/` but omitting `GEMINI.md`.
  Each call refreshes the symlinks (idempotent), so re-auth / token rotation Just Works.
- **Why:** The CLI auto-loads `~/.gemini/GEMINI.md` as "memory" on every call, which was
  injecting unrelated global preferences ("consider mobile versions too…") into every
  review and draft. Verified live: leak gone, auth survives, all 5 assumption tests still
  PASS. The user's real `~/.gemini` is untouched, so other Gemini / Antigravity use is
  unaffected.
- **Files:** `lib/gemini-invoke.sh`, `README.md`, `assumptions/README.md`.

### Initial release
- **What ships:**
  - `lib/gemini-invoke.sh` — single-source-of-truth headless wrapper around
    `@google/gemini-cli` (v0.43.0 at time of writing). Always read-only
    (`--approval-mode plan`), never blocks a caller, exits 0 with `[unavailable]` /
    `[empty]` / `[timeout]` markers. Context on stdin, instruction in `-p`. bash-3.2 safe;
    perl-based timeout (no `gtimeout` dependency).
  - `lib/prompts/review.md` — read-only second-opinion review framing.
  - `lib/prompts/draft.md` — drafting/generation framing.
  - `../gemini.md` — `/gemini [review|draft] [path|diff|task]` slash command (orchestrator).
  - `assumptions/{00–04,run-all,README}.sh|md` — 5 assumption tests proving the runtime
    contract: safety fallback (auth-independent), headless auth/quota, `--approval-mode
    plan` actually suppresses tool execution (with a `--yolo` positive control), no-hang
    on untrusted dirs, stdin context channel works (with no-stdin negative control).
- **Design decisions** (carried from `tmp/done-plans/2026-05-26-gemini-subagent.md`):
  - **Wrapper + README one-liner, not a Claude `Agent` definition file** — mirrors how
    `codex-invoke.sh` is reused across god-review/master-review, keeps "one way to do
    things."
  - **Auth-agnostic by design** — CLI picks `GEMINI_API_KEY` if set, else cached OAuth.
    Same code survives the **2026-06-18 free-tier cliff** (after which the OAuth path
    stops; export `GEMINI_API_KEY` then).
  - **No flock / no two-profile alternation** (unlike `codex-invoke.sh`) — Gemini's
    headless `-p` is stateless; parallel calls are safe reads.
  - **Read-only is structural, not behavioral** — `--approval-mode plan` is an EXPLICIT
    sandbox flag, not a hopeful default; this is the safety lynchpin, proven by test 02.
- **Hazard removed alongside this build:** `~/.gemini/GEMINI.md` previously contained an
  auto-instruction to `git push --force` to `integrateapi2` with a plaintext password
  (`"omid"`) "after every action." Sanitized on 2026-05-26 to a single benign line.
