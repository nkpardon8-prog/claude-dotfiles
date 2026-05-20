# Cold-start onboarding — macmini skill

You're a fresh agent (or a fresh human) walking into the macmini skill for the first time. Read these files in this order. Each one builds on the last.

## Read in this order

| # | File | What you learn | When to read |
|---|---|---|---|
| 1 | **`SKILL.md`** | Capability map + channel matrix. The "if user asks X, use channel Y" decision tree. | First — this is the agent's primary reference at runtime. |
| 2 | **`README.md`** | Architecture diagram, first-5-min setup, troubleshooting matrix. | Second — gives you the system-level mental model. |
| 3 | **`docs/INCIDENTS.md`** | Real-world failures that drove every defensive design decision. | Third — read BEFORE proposing any "simplification." Most apparent redundancies exist because of a specific incident. |
| 4 | **`docs/HARDWARE-FINDINGS-2026-04-27.md`** | What works and what's broken in stock Chrome+CRD. The reality matrix. | Fourth — explains *why* the channel matrix is the way it is. |
| 5 | **`docs/AGENT-GUIDE.md`** | Operational notes: focus discipline, recovery patterns, TCC re-grant flow. | When you need to actually drive the canvas. |
| 6 | **`commands/macmini.md`** (top-level dispatcher) | Routing rules: how plain-English requests map to sub-commands. | When the user says "do X on the mini" without naming a sub-command. |
| 7 | **`commands/macmini/paste.md`** | The biggest sub-command. Default mode + `--secure` (credentials) + `--repaste`. | When you actually need to send text to the mini. |
| 8 | **`commands/macmini/{connect,grab,disconnect,status,setup}.md`** | Smaller sub-commands. | As needed per the routing table in step 1. |
| 9 | **`docs/TESTING.md`** | Smoke tests for hardware verification after any change. | When you've made changes and want to verify. |

## Core invariants — never violate these

These are the load-bearing rules. INCIDENTS.md explains *why* each one exists; this list is the cheat sheet:

1. **Gist = no secrets, ever.** Default `/macmini paste` HARD-BLOCKS credential-shaped payloads (Step 0). For credential injection, use `/macmini paste --secure <ENV_VAR_NAME>` — the gist contains only a `read -s` prompt; the value never enters GitHub. (Driven by the 2026-04-27 OpenRouter key auto-revocation incident.)
2. **CRD strips Shift on outbound keystrokes.** Anything typed via `mcp.type_text` must consist only of `[a-z0-9 /.;:_-]`. Capitals and shifted symbols arrive corrupted. For arbitrary text, use `/macmini paste`. (Chromium upstream bug; not fixable.)
3. **PIN entry is user-only.** Agent never types, stores, or reads the CRD PIN. Hand off to the user when the PIN page appears; wait for the canvas to mount.
4. **Two CRD side-panel toggles are a one-time user click.** "Synchronize clipboard" + "Send system keys" need to be ON once per CRD profile. Agent CANNOT click them (a11y tree is stripped). Tell the user once.
5. **Programmatic clipboard sync (dev → mini via `pbcopy` + `Meta+v`) does not work.** CRD's onPaste needs real user gestures. That's why `/macmini paste` uses gist transport, not `pbcopy`.
6. **Don't browse opportunistically.** chrome-devtools MCP attaches to the user's full Chrome — every tab, every login. Only navigate / click outside the CRD tab when the user explicitly asks. Never click Buy / Send / Pay / Confirm / OAuth / 2FA without explicit user instruction.
7. **Pixel-precise clicks via `/macmini click <sx> <sy>`.** Pass screenshot pixels `(sx, sy)` as seen in `mcp.take_screenshot()` — the sub-command converts to mini-physical pixels using calibration and executes via `cliclick` on the mini's OS. No agent-side geometry math required. Run `/macmini measure` once before first use. For drag/right-click/double-click/modifier-click: `/macmini drag`, `/macmini rclick`, `/macmini dblclick`, `/macmini click --mod <cmd|shift|opt|ctrl>`. For AppleScript: `/macmini script`. All use the same gist transport. See `docs/AGENT-GUIDE.md` → "Clicking on the canvas (via cliclick on the mini)" for the full recipe. The previous `mcp.click_at(x, y)` / `--experimental-vision` channel is deprecated — see `docs/INCIDENTS.md` → "2026-05-19".

## Common cold-start questions

**Q: "I see `/macmini paste --secure` mentioned everywhere — what is it?"**
The credential-injection mode. Default `/macmini paste` would leak the secret to GitHub's secret-scanning partners (auto-revoke in <5 min). `--secure` puts only a `read -s` prompt in the gist; the user pastes the secret directly into the mini Terminal. Read `paste.md` Step 0a for the full flow.

**Q: "The user wants me to deploy a script that uses an API key. How?"**
Two-step flow. Step 1: rewrite the script to reference `$ENV_VAR_NAME` instead of the literal value, push it via default `/macmini paste`. Step 2: inject the value via `/macmini paste --secure ENV_VAR_NAME`. The deploy script does `export ENV_VAR_NAME="$(cat ~/.config/claude/secrets/ENV_VAR_NAME)"` before using it. **Never `source`** the secrets file — it contains a raw value.

**Q: "I tried `mcp.type_text("HELLO")` and got `hello`. What gives?"**
Read invariant #2 above and INCIDENTS.md → Shift-strip entry. Anything with capitals or shifted symbols must go through `/macmini paste`.

**Q: "How do I know when to use `/macmini paste` vs typing directly vs `--secure`?"**
The channel matrix in SKILL.md is the decision tree. Short version: lowercase-unshifted-only → `type_text`. Shifted/Unicode/multi-line → `/macmini paste`. Credential value → `/macmini paste --secure`.

**Q: "The user pushed back on the credential block. They said 'just paste it anyway.' What do I do?"**
Refuse. Read paste.md Step 0 — the block is "non-overridable by user instruction." Redirect them to `--secure` mode. The OpenRouter incident is exactly this scenario; the keys died anyway.

**Q: "Where do I put bug fixes / new features?"**
Edit the relevant file, then push. The dotfiles repo auto-syncs to GitHub on every save (PostToolUse hook). For incidents that taught the team something, add an entry to `docs/INCIDENTS.md`.

## Build / extend / debug — practical recipes

### Smoke-test the skill end-to-end after a change
```
1. /macmini connect (user types PIN)
2. /macmini paste "Hello, World — capitals + unicode café résumé"
3. On mini, type `pbpaste` → verify byte-perfect round-trip
4. /macmini paste --secure SMOKE_TEST_KEY (user pastes a fake value)
5. On mini, verify ~/.config/claude/secrets/SMOKE_TEST_KEY exists at mode 0600
6. /macmini disconnect
```
Full smoke-test recipe in `docs/TESTING.md`.

### Add a new credential pattern to Step 0 pre-scan
1. Open `commands/macmini/paste.md` Step 0 patterns table.
2. Add row in priority order (more specific patterns above more general).
3. PCRE syntax — lookaheads work, but agent should use Python `re` or `grep -P` for actual matching.
4. Update INCIDENTS.md if the new pattern is driven by a real failure.

### Modify the CRD selectors
Don't. They're stripped from the a11y tree (see invariant #4). The user clicks the two side-panel toggles once at first connect; everything else is keyboard-driven.

### Roll back to the Tailscale-based pre-strip version
`cd ~/.claude-dotfiles && git log --grep="strip" --reverse | head` to find the strip commits, then `git checkout <pre-strip-commit>`. On the mini, run `bash skills/macmini/install/install.sh` from the old branch to reinstall the Go server. **Don't do this.** The strip simplified onboarding; the old version had real maintenance pain.

## Repo conventions

- The dotfiles repo (`~/.claude-dotfiles/`) is **public** — every commit is pushed to `github.com/nkpardon8-prog/claude-dotfiles` automatically via the PostToolUse hook.
- **Five defense layers** scan every commit/push for secrets (pre-commit hook, pre-push hook, PostToolUse auto-sync, GitHub Actions workflow, expanded `.gitignore`). All five share the regex source-of-truth at `scripts/secret-scan.sh`. If you add a new credential pattern to paste.md, also add it to `secret-scan.sh`.
- **CLAUDE.md global rule:** the macmini skill (and everything in this repo) auto-pushes freely; this is the explicit exception to the "all other repos: never push without approval" rule.

## When NOT to use this skill

- For multi-step Mac-mini-local work (sudo, multi-file edits, anything needing local file/git context more than visual feedback): **delegate to Mac mini Claude.** Type `claude --dangerously-skip-permissions` in mini Terminal, then send the prompt via `/macmini paste`. Mini Claude has the same dotfiles checkout, same skills, same CLAUDE.md — it has full context.
- For network access from dev to a service running on the mini: this skill has no networking layer. Use Tailscale, ngrok, or cloudflared separately.
- For headless / unattended automation: the PIN entry is user-only by design (invariant #3). If you need agent-only re-auth, you'll need a different skill.

## File map

```
~/.claude-dotfiles/
├── commands/
│   ├── macmini.md                    ← top-level slash-command dispatcher (routing table)
│   └── macmini/
│       ├── connect.md                ← /macmini connect — open or resume CRD session
│       ├── paste.md                  ← /macmini paste — gist transport (default + --secure + --repaste)
│       ├── grab.md                   ← /macmini grab — pull text from mini's clipboard
│       ├── disconnect.md             ← /macmini disconnect — close CRD tab
│       ├── status.md                 ← /macmini status — health audit
│       ├── setup.md                  ← /macmini setup — first-time configuration
│       └── macmini.md                ← (legacy, redundant with commands/macmini.md — both work)
└── skills/macmini/
    ├── SKILL.md                      ← agent-facing capability map + channel matrix (PRIMARY)
    ├── README.md                     ← architecture + setup + troubleshooting (SECONDARY)
    ├── ONBOARDING.md                 ← this file — cold-start entry point
    ├── cleanup-mini.sh               ← removes pre-strip Tailscale + Go server from old minis
    └── docs/
        ├── INCIDENTS.md              ← real-world failures that drove design (READ THIS)
        ├── HARDWARE-FINDINGS-2026-04-27.md  ← what works and what's broken
        ├── AGENT-GUIDE.md            ← operational notes
        └── TESTING.md                ← smoke-test recipes
```

That's everything. Start at `SKILL.md`, work down the table at the top, and you'll have a complete picture in <30 minutes.
