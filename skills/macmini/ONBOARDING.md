# Cold-start onboarding — macmini skill

> **TL;DR — if you remember three things:**
> 1. **EYES** = `mcp.take_screenshot()` on the CRD page (the live macOS desktop feed).
> 2. **HANDS** = direct CDP — `mcp.click_at({x,y})`, `mcp.type_text`,
>    `mcp.press_key`. They reach the macOS host natively. NO gist, NO cliclick,
>    NO on-host agent, NO calibration, NO Terminal dance. (Clean break from the
>    OLD gist-era `/macmini`.)
> 3. **TWO LAYERS** — LAYER-1 (CRD's own chrome; on macOS the a11y tree shows
>    only `Desktop`, so coordinate-click / user action) vs LAYER-2 (the macOS
>    desktop: `click_at` mapped through the canvas rect + screenshots). Always
>    know which one you're on.
>
> Read [`../../commands/macmini.md`](../../commands/macmini.md) → "READ THIS
> FIRST" — it embeds the canvas-rect helper, the shift-map, and the title-first
> bind, so a cold agent can act from that one file alone.

You're a fresh agent walking into the macmini skill for the first time. There
are only **three files** to read — read them in this order.

## Read in this order

| # | File | What you learn |
|---|---|---|
| 1 | **`../../commands/macmini.md`** | The dispatcher (self-contained): mental model, embedded helpers, capability matrix, hard rules, smoke tests, sub-command table. Start here. |
| 2 | **`SKILL.md`** | Full runtime reference: coordinate math (both spaces + worked Apple-menu example), text math, credential safety, gotchas, Verified-vs-UNVERIFIED matrix, mini-Claude delegation, safety. |
| 3 | **`docs/FINDINGS-2026-06-01.md`** | What's verified vs UNVERIFIED on macOS, the "Send system keys" dependency, the macOS scroll keys, and the gist-era history (the 2026-05-19 `click_at` deprecation) so it's diagnosable. |

(Sub-command details live in `../../commands/macmini/{connect,act,crd}.md` — read
those when you actually drive the session.)

## Core invariants — never violate these

1. **Mac session only.** Bind by tab title `plan2bid-minim4` + a macOS-menu-bar
   screenshot. NEVER select / `bringToFront` / act on the **Windows** CRD tab
   (`OpenDentalDev1`). STOP if you can't tell which is which.
2. **Re-read the canvas rect before EVERY click; never reuse coords across
   screenshots.** The window resizes mid-session and silently breaks reused
   coordinates.
3. **Screenshot before AND after every action.** Vision is the receipt. Apply
   the modal-recovery rule — an unchanged screenshot is not proof of a wrong
   coordinate; it may be a modal.
4. **Capitals & symbols go through `press_key("Shift+<base>")` (the shift-map),
   not `type_text`.** `type_text` strips Shift. Pure lowercase/unshifted is the
   only `type_text` fast path.
5. **Cmd combos need "Send system keys" ON.** `Meta+Space` / `Meta+Tab` /
   `Meta+C` / `Meta+V` forward only when that one-time USER toggle is on. If a
   Cmd combo does nothing → toggle off → use the Dock / Apple-menu click
   fallback and surface to the user.
6. **No right-click, no drag-scroll on macOS.** Right-click has no CDP path → use
   the app's menu bar (top). Scroll is KEYBOARD only (PageDown/Arrow/Meta+Arrow)
   — `drag` is read as text-selection.
7. **Coordinate mapping is via the canvas rect, both-CSS-px, no ÷DPR.** Only a
   target eyeballed off a raw screenshot is ÷DPR (and must subtract the letterbox
   offset). If the rect helper returns `{error}`, STOP — don't guess a canvas.
8. **Credentials: user types via `read -s` in the mini Terminal.** Never type a
   secret through the canvas. Never approve a macOS auth / keychain /
   accessibility prompt or a CRD PIN — surface to the user.
9. **Connection self-heal is user-gated.** Hang/error/empty `list_pages` →
   `/devtools`, then wait for the user to `/mcp` reconnect. No auto-retry.
10. **Run the first-session smoke tests once** (`macmini.md` → First-session
    smoke tests): click_at reaches host, full shift-map, Cmd forwarding, CRD
    a11y mode (expect only `Desktop`).

## Common cold-start questions

**Q: "How do I click something on the mini's screen?"**
Run the canvas-rect helper (`evaluate_script`), get `{rect, hostW, hostH}`, map
your host pixel with `clickX = rect.x + hx*(rect.w/hostW)` (no ÷DPR), then
`mcp.click_at({x,y})`. Screenshot before+after. See SKILL.md "Coordinate math".

**Q: "I typed `Hello` and got `hello`. What gives?"**
`type_text` strips Shift (invariant #4). Route any capital/symbol through the
`send_text` shift-map (`press_key("Shift+<base>")`).

**Q: "How do I right-click?"**
You can't via CDP on macOS (invariant #6). Use the app's **menu bar** (top).
`Shift+F10` is Windows-only — it does nothing here.

**Q: "Cmd+Space / Cmd+Tab don't do anything."**
The "Send system keys" CRD toggle is off (invariant #5). Surface to the user;
use the Dock-icon click fallback meanwhile.

**Q: "`list_pages` hangs."**
A frozen background tab is freezing the enumeration. Run `/devtools`, then wait
for the user to `/mcp` reconnect. Don't auto-retry (invariant #9).

**Q: "There are two CRD tabs."**
One is the Windows laptop (`/windows` — don't touch). Match title
`plan2bid-minim4` + confirm a macOS menu bar / Dock. If still ambiguous, STOP and
ask (invariant #1).

## How this differs from the OLD gist-era /macmini

If you (or another agent's memory) recall a gist/cliclick `/macmini`: **that's
gone.** No `gh gist`, no `cliclick`, no on-host `run.sh` agent, no `/macmini
measure` calibration, no Terminal-foreground dance, no `paste`/`grab`/`script`
sub-commands. Clicks are direct CDP `click_at` into the canvas; arbitrary text is
the per-char shift-map; credentials are typed by the user via `read -s` in the
mini Terminal. The full before/after table is in `commands/macmini.md` → "How
this differs from the OLD gist-era /macmini", and the gist-era history is
preserved in `docs/archive-gist-era/` + summarized in `docs/FINDINGS-2026-06-01.md`.

`/macmini` and `/windows` are now **direct-CDP twins**. The only real deltas:
device name (`plan2bid-minim4` vs `OpenDentalDev1`), macOS menu bar/Dock vs
Windows taskbar, and Cmd-keys-forward (Mac) vs system-keys-swallowed (Windows).

## Repo conventions

- The dotfiles repo (`~/.claude-dotfiles/`) auto-syncs to GitHub on save (a
  PostToolUse hook commits+pushes every ~2 min). A clean `git status` after an
  edit is the daemon, not a failed edit.
- **Deployment:** `~/.claude/commands` is a **symlink** to
  `~/.claude-dotfiles/commands` — edit the SoT once, no copy needed. The
  `skills/macmini/` tree lives in `~/.claude-dotfiles/` ONLY (not deployed) —
  same as `/windows`. That's why the dispatcher must be self-contained.

## File map

```
~/.claude-dotfiles/
├── commands/
│   ├── macmini.md                      ← self-contained dispatcher (embeds the 3 helpers)
│   └── macmini/
│       ├── connect.md                  ← bind Mac session (title-first), PIN hand-off, /devtools handoff, Shift-wake
│       ├── act.md                      ← LAYER-2 recipes, the ONE rect helper, shift-map, scroll keys
│       ├── crd.md                      ← LAYER-1 (coordinate/user fallback on macOS); status + disconnect
│       └── setup.md                    ← one-time: MCP, the two CRD toggles, CRD_DEVICE_NAME, first connect
└── skills/macmini/
    ├── SKILL.md                        ← full runtime reference (PRIMARY)
    ├── ONBOARDING.md                   ← this file
    └── docs/
        ├── FINDINGS-2026-06-01.md      ← verified/UNVERIFIED + the gist-era history
        └── archive-gist-era/           ← superseded gist/cliclick-era docs (history only)
```
