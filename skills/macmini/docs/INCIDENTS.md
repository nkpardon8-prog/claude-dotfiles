# Incident log — design decisions driven by real-world failures

This file is the institutional memory for the macmini skill. Every entry below is something that broke in production and shaped the current design. Read this BEFORE proposing a "simplification" — most of the seemingly-redundant defenses in this skill exist because of a specific incident.

Entries are reverse-chronological (newest first). Each follows the format:
- **What broke**, **Root cause**, **Fix**, **Why we kept the fix**.

---

## 2026-05-19 — `mcp.click_at(x,y)` deprecated — cliclick-via-paste promoted to primary (DESIGN PIVOT)

**What broke.** After 2026-04-30 validation, the chrome-devtools-mcp
`--experimental-vision` channel that ships `click_at(x, y)` went
unreliable upstream — the MCP server itself wedged on certain
sequences, requiring the `/devtools` kill + npx-hash-dir scrub
(commits `ce75b7c` and `24e33b4`) to recover. Even after recovery,
the agent could not assume `click_at` would survive a session. The
synthetic-CDP-click design was always fragile (relied on CRD's
canvas accepting non-isTrusted mouse events), and the user explicitly
preferred clicks that execute on the mini, not as dev-side synthetic
events on the canvas.

**Root cause.** `--experimental-vision` is a beta flag in chrome-
devtools-mcp; its stability is not contractually guaranteed and
regressed without a rollback path on our side. The architectural
issue is deeper: any click channel that originates as a synthetic
event on the dev side, regardless of MCP, depends on CRD's canvas
not enforcing `isTrusted`. CRD has tightened the canvas event
acceptance over time; the same drift that broke programmatic
clipboard sync (2026-04-27 incident in this log) was always going to
catch up with click_at eventually.

**Fix (this commit).** New /macmini sub-commands click, rclick,
dblclick, drag, and script — all routed through the existing gist
transport (paste.md mechanics) with cliclick or osascript as the
run.sh body. One-time calibration via /macmini measure writes
~/.config/claude/macmini-calibration.json. Click_at references
removed from SKILL.md, README.md, AGENT-GUIDE.md, setup.md, and
HARDWARE-FINDINGS-2026-04-27.md (the 2026-04-30 row in
HARDWARE-FINDINGS is annotated as deprecated; this incident log
entry preserves the historical context). The
`scripts/enable-experimental-vision.sh` installer is deleted.

**Why we kept the design.** Cliclick runs on the mini's OS — it is
NOT a synthetic event in the CRD canvas, so it bypasses every isTrusted
gate. The gist transport is already battle-tested as the back-channel.
Round-trip cost is ~6s/click vs ~100ms for click_at, but the
trade-off is reliability + "from within" architecture the user asked
for. For latency-sensitive iterative work, the documented path is
delegation to a Claude session running on the mini directly.

**Pattern, not bug.** Going forward: any new control primitive
should execute ON THE MINI, dispatched via the existing gist
channel, with vision as the receipt. Synthetic dev-side events into
the CRD canvas are an architectural dead end for anything past
plain-keyboard typing.

---

## 2026-04-30 — click_at(x,y) validated through CRD canvas (PREVENTIVE — NOT a failure)

**What "broke" / preventive validation.** Before this date, off-center clicking on the CRD canvas was unavailable — `mcp.click({uid})` could only hit the canvas centerpoint because CRD strips its own a11y tree. Anything more granular needed keyboard navigation (Spotlight + Tab + arrow keys). Vision-feedback agents wanted pixel-precise clicking on whatever's visible, like a human pointing and clicking.

**Root cause / opportunity.** chrome-devtools-mcp ships `click_at(x, y)` natively but gates it behind the `--experimental-vision` CLI flag. We had documented the flag as unavailable in earlier HARDWARE-FINDINGS — that was wrong; we just hadn't enabled it. One CLI flag in `~/.claude.json` + Claude Code restart unlocks the tool.

**Fix (commits leading up to validation; HEAD ~`a7084bc..`).** Added `--experimental-vision` to chrome-devtools-mcp args in `~/.claude.json`. Created idempotent installer at `scripts/enable-experimental-vision.sh` (with JSON validation + atomic write + backup). Documented `click_at` as a regular tool in SKILL.md channel matrix (NOT a slash command — keep elastic). Added a four-step recipe to AGENT-GUIDE.md → "Clicking on the canvas": screenshot → fetch geometry (DPR + zoom + canvas rect) → convert + verify on-canvas + verify non-occluded via `elementFromPoint` → click. Added cliclick fallback documentation for drag/right-click/modifier+click/CRD-doesn't-forward edge cases. Plus mandatory verify-after contexts list (OAuth/payment/destructive/send-message/file-overwrite/2FA). 3 plan-review rounds + 2 implementation-reviewer rounds caught and fixed: stale "click_at unavailable" paragraph in SKILL.md, missing JSON validation in installer script, gitignore not covering CLAUDE.local.md handoff, modifier-click race condition, off-by-one rect bounds, browser-zoom formula, multi-canvas null guard, CRD UI overlay edge case.

**Outcome (validated 2026-04-30).** End-to-end test against live CRD session into `plan2bid-minim4`:
- Smoke 0–5 + 9 + bonus mini-Claude conversation: ALL PASS or expected behavior. See [HARDWARE-FINDINGS-2026-04-27.md → "click_at(x, y) forwarding through CRD canvas (validated 2026-04-30)"](./HARDWARE-FINDINGS-2026-04-27.md) for the per-test outcome table with latencies.
- Critical-path validation: `click_at(250, 500)` focused the LEFT Terminal on the mini, subsequent `type_text("date", Enter)` ran on mini, output visible in screenshot.
- Real-world bonus: clicked into Mac mini Claude TUI, sent a message, mini Claude responded "confirmed" — full dev → mini → dev round-trip.
- Off-canvas refusal: recipe correctly refused (600, 50) — `inside: false`, `isCanvas: false`, occluding element was a CRD-UI `<div>`.

**Why we kept the design.** CDP-injected mouse events forward through CRD's canvas as predicted (canvas mouse handlers don't enforce `isTrusted`, unlike clipboard onPaste — that's why the credential incident needed `--secure` mode but click_at didn't need anything special). Click latency is ~50ms, ~100× faster than gist transport for non-text interactions. The agent now reaches for click_at elastically (no slash command wrapper, just like `take_screenshot` or `type_text`).

**Pattern, not bug.** Pixel-precise clicking is now an always-available primitive in the agent's toolbox. The geometry recipe (DPR conversion, rect-bounds check, occlusion check) is mandatory; the verify-after-click is recommended for small targets and mandatory for destructive actions. The cliclick fallback is documented but unused so far — preserve it for drag/right-click/modifier+click cases the click_at tool can't do alone.

---

## 2026-04-27 — Credential leak via gist transport (CRITICAL)

**What broke.** A field agent ran `/macmini paste` with a deploy script that had `OPENROUTER_API_KEY=sk-or-v1-...` baked in. The agent uploaded the script to a SECRET gist, the mini cloned it, the deploy started — and the OpenRouter key was dead within 10 minutes. A second key burned the same way before the team understood what was happening.

**Root cause.** GitHub runs secret-scanning on every gist, including unlisted/secret gists. Detected credentials are forwarded to issuer partners (OpenAI, Anthropic, OpenRouter, AWS, Google Cloud, Stripe, Twilio, Slack, ~50 others — see [GitHub secret-scanning partner program](https://docs.github.com/en/code-security/secret-scanning/secret-scanning-partner-program)) within minutes. Issuers auto-revoke. Deleting the gist after use does NOT unwind partner notification or revocation.

The skill's existing pre-scan was advisory ("BLOCKED: payload contains apparent credential, see docs") and the agent silently fell through to the docs path instead of refusing — so the leak proceeded.

**Fix (commits `4fb6f69..d68f905`):**
- Step 0 of `paste.md` is now a HARD GATE with a loud `═══ BLOCKED ═══` banner naming the threat model.
- New `--secure <ENV_VAR_NAME>` mode: gist contains ONLY a `read -s` prompt; user pastes secret directly into mini Terminal; lands at `~/.config/claude/secrets/<NAME>` mode 0600 via atomic `mv`. Value never enters a gist.
- New `--repaste` mode for re-firing existing clipboard into a different focused app.
- Threat model surfaced at top of `paste.md`, in `commands/macmini.md` "Hard rules", and in `SKILL.md` channel matrix.
- 11 named credential patterns (PCRE) checked in priority order: anthropic-key before openai-key, AWS extended to `AKIA|ASIA`, private-key includes `ENCRYPTED`, auth-header covers Bearer/Token/X-API-Key/Proxy-Auth, op://-resolved is a real regex, high-entropy-env-credential excludes ~10 placeholder strings.

**Why we kept the fix.** The default mode is great for the 95% case (deploy scripts, code patches, multi-line bash). But the auto-revoke threat is fundamental to gist transport — you cannot route credentials through a gist, full stop. The hard gate prevents the failure mode; `--secure` provides the legitimate alternative. Removing either re-opens the leak path.

**Pattern, not bug.** This is THE central invariant of the skill: **gist = no secrets, ever**. If a future change weakens Step 0 or sneaks a value into a gist via a new code path, you've reintroduced the leak.

---

## 2026-04-27 — `gh gist create -f run.sh "$TMPFILE"` ignored the `-f` flag (HIGH)

**What broke.** Live test of `/macmini paste` showed clone succeeded but `bash /tmp/macmini-paste/run.sh` failed with `No such file or directory`.

**Root cause.** `gh gist create -f` is documented for stdin mode (`gh gist create -f name.ext - < file`). When you pass `-f` AND a file path argument, gh silently ignores `-f` and uses the local basename as the gist filename. The local tempfile was named `macmini-paste.XXXXXX-tYPxC0`, so the gist filename was that, not `run.sh`.

**Fix (commit `5ed3bd9`).** Build `run.sh` inside a fresh tempdir (`mktemp -d`), then `gh gist create "$TMPDIR_LOCAL/run.sh"` — basename is now exactly `run.sh`. Also fixed `gh gist delete --yes` (non-interactive shells need the flag).

**Why we kept the fix.** The `bash /tmp/macmini-paste/run.sh` clone target is hardcoded; the gist filename invariant is load-bearing. Documented as a "filename invariant" callout in paste.md Step 3.

---

## 2026-04-27 — CRD strips Shift on outbound keystrokes (CRITICAL — design constraint)

**What broke.** During Phase E hardware validation, `mcp.type_text("HELLO_WORLD")` arrived at the Mac mini as `hello-world`. Capitals lowercased; `_` became `-`; `$@!#%^&*()` got remapped to wrong chars; `(` arrived as `;`.

**Root cause.** Long-standing Chromium bug ([issue 40355503](https://issues.chromium.org/issues/40355503), [issue 40933947](https://issues.chromium.org/issues/40933947)). CRD's keyboard pipeline drops the Shift modifier between dev and Mac mini. NOT a DevTools MCP defect — `press_key` produces CDP-trusted events; the strip happens inside CRD's WebRTC layer.

**Fix.** Designed AROUND it:
- All typed strings on the mini side must contain only `[a-z0-9 /.;:_-]` (Step 5 of paste.md validates this with `LC_ALL=C` `case` glob).
- For arbitrary text, route through `gh gist clone` (filename and ID are hex, all unshifted-safe).
- For credentials, the user types directly into the mini at the `read -s` prompt — bypasses dev keyboard entirely.

**Why we kept the workaround.** No fix in our power; relying on Chromium / Google CRD upstream is not an option. Every keystroke the agent types must be unshifted-safe by construction.

---

## 2026-04-27 — Programmatic clipboard sync (dev → mini) doesn't trigger CRD's onPaste (HIGH)

**What broke.** Tested `pbcopy` on dev followed by `mcp.press_key("Meta+v")` on the canvas — the paste landed whatever was in the mini's LOCAL clipboard, not what dev just copied. Verified across multiple attempts.

**Root cause.** CRD's `onPaste` handler requires real user gestures (`isTrusted=true` events). CDP-injected events are synthetic (`isTrusted=false`), so they don't trigger CRD's clipboard sync.

**Fix.** Use `gh gist` transport instead. The mini-side `pbcopy < /tmp/macmini-paste/run.sh` (executed by `bash run.sh`) is a real local pbcopy, so the mini's pasteboard updates correctly; subsequent `Meta+v` on a focused mini-side app pastes the right bytes.

**Why we kept the fix.** Same as Shift-strip — no upstream fix available. Documented in HARDWARE-FINDINGS-2026-04-27.md.

---

## 2026-04-27 — CRD's a11y tree is stripped (HIGH — design constraint)

**What broke.** `mcp.take_snapshot()` returns `ignored` for nearly every CRD control (Begin, Synchronize clipboard, Send system keys, Show remote keyboard, Pin options panel). Only the canvas wrapper textbox is exposed.

**Root cause.** CRD intentionally strips its own a11y tree as an automation barrier. Synthetic clicks fail the `isTrusted` check anyway.

**Fix.** The user clicks "Synchronize clipboard" + "Send system keys" toggles ONCE manually at first connect; both persist across reconnects. The agent never tries to click them. Documented in setup.md and connect.md.

**Why we kept the fix.** One manual click per profile lifetime is acceptable; it would take an AppleScript / cliclick coordinate-based workaround to automate, which is brittle and worse UX than the one-time click.

---

## 2026-04-27 — CRD PIN entry is intentionally user-only (DESIGN DECISION)

**What broke.** Storing the CRD PIN in 1Password and replaying it through the canvas is technically doable — but adds a credential the user has to maintain, and the value is never useful elsewhere.

**Decision.** PIN entry stays user-only. The agent locates the device tile, clicks it, and prints `PIN page open. Type your CRD PIN now. I'll pick back up automatically once the canvas appears.` then waits 120s for the canvas-mounted signal (`Send system keys` / `Synchronize clipboard` labels appear).

**Why we kept the decision.** Six digits of typing per session is cheap; one less stored credential is a real security win. The agent never types, stores, or reads the CRD PIN.

---

## 2026-04-26 → 2026-04-27 — Mac mini Phase E architectural decisions

**Original design** (pre-strip): Tailscale + Go HTTPS server on the mini, dev curls JSON over WireGuard, persistent LaunchAgent.

**What broke.** Two compiled binaries to maintain, MagSafe-style cert renewal pain, Tailscale account dependency, and the hardware reality test showed CRD's keyboard pipeline + clipboard quirks dominate the UX anyway. Didn't justify its own complexity.

**Decision (commit `macmini-strip` branch → merged into main `5ed3bd9`).** Stripped Tailscale + Go server entirely. Skill is now a thin wrapper around chrome-devtools MCP attached to the user's running Chrome. No daemons, no binaries on the mini side beyond `gh` CLI.

**Why we kept the strip.** Operational complexity halved; user-onboarding 4 steps shorter; no auth tokens to rotate. Cost: the gist round-trip is ~6s end-to-end instead of ~200ms over Tailscale, but day-to-day flow works fine.

The old version is preserved on the pre-strip commits if rollback is ever needed; `cleanup-mini.sh` removes the LaunchAgent + binaries from minis that had the old version installed.

---

## How to extend this log

When you ship a fix that's driven by a real-world failure (not just a code review nit):

1. Add a new entry at the top with today's date and a CRITICAL/HIGH/MEDIUM tag.
2. Use the same four-section template: What broke / Root cause / Fix / Why we kept the fix.
3. Reference the commit hash(es) so future readers can see the actual diff.
4. If the fix introduces a new invariant (like "gist = no secrets, ever"), state it explicitly in the entry — that way a future "simplification" can't accidentally regress it.

Don't add entries for code-review-only feedback (nits, style, internal contradictions) — those go in the commit message. INCIDENTS.md is for failures the team learned something from.
