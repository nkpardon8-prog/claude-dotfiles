# Cold-start onboarding — windows skill

> **TL;DR — if you remember three things:**
> 1. **EYES** = `mcp.take_screenshot()` on the CRD page (the live Windows desktop feed).
> 2. **HANDS** = direct CDP — `mcp.click_at({x,y})`, `mcp.type_text`,
>    `mcp.press_key`. They reach the Windows host natively. NO gist, NO cliclick,
>    NO on-host agent, NO calibration, NO Terminal dance. (The simplification
>    over `/macmini`.)
> 3. **TWO LAYERS** — LAYER-1 (CRD's own chrome: `take_snapshot` + `click({uid})`
>    by label) vs LAYER-2 (the Windows desktop: `click_at` mapped through the
>    canvas rect + screenshots). Always know which one you're on.
>
> Read [`../../commands/windows.md`](../../commands/windows.md) → "READ THIS
> FIRST" — it embeds the canvas-rect helper, the shift-map, and the title-first
> bind, so a cold agent can act from that one file alone.

You're a fresh agent walking into the windows skill for the first time. There
are only **three files** to read — read them in this order.

## Read in this order

| # | File | What you learn |
|---|---|---|
| 1 | **`../../commands/windows.md`** | The dispatcher (self-contained): mental model, embedded helpers, capability matrix, hard rules, smoke tests, sub-command table. Start here. |
| 2 | **`SKILL.md`** | Full runtime reference: coordinate math (both spaces + worked letterbox example), text math, gotchas table, Verified-vs-Assumed matrix, safety. |
| 3 | **`docs/FINDINGS-2026-05-31.md`** | What's verified vs assumed, and the two `/macmini` conflicts (`click_at` deprecation; CRD a11y `ignored`) — both worked here, re-check at runtime. |

(Sub-command details live in `../../commands/windows/{connect,act,crd}.md` — read
those when you actually drive the session.)

## Core invariants — never violate these

1. **Windows session only.** Bind by tab title `OpenDentalDev1` + a taskbar
   screenshot. NEVER select / `bringToFront` / act on the **Mac** CRD tab. STOP
   if you can't tell which is which.
2. **Re-read the canvas rect before EVERY click; never reuse coords across
   screenshots.** The window resizes mid-session and silently breaks reused
   coordinates (verified incident).
3. **Screenshot before AND after every action.** Vision is the receipt. Apply
   the modal-recovery rule — an unchanged screenshot is not proof of a wrong
   coordinate; it may be a Win32 modal.
4. **Capitals & symbols go through `press_key("Shift+<base>")` (the shift-map),
   not `type_text`.** `type_text` strips Shift. Pure lowercase/unshifted is the
   only `type_text` fast path.
5. **Clicks, not system keys.** Win / Alt+Tab / Ctrl+Alt+Del are swallowed by
   CRD. Launch = click Start orb; switch = click taskbar icon; Ctrl+Alt+Del /
   PrtScr = CRD DOM buttons.
6. **Coordinate mapping is via the canvas rect, both-CSS-px, no ÷DPR.** Only a
   target eyeballed off a raw screenshot is ÷DPR (and must subtract the letterbox
   offset). If the rect helper returns `{error}`, STOP — don't guess a canvas.
7. **OpenDental = live PHI by default.** Don't infer Demo from a screenshot.
   Never type into a Windows UAC / sign-in / credential prompt or a CRD PIN —
   surface to the user.
8. **Connection self-heal is user-gated.** Hang/error/empty `list_pages` →
   `/devtools`, then wait for the user to `/mcp` reconnect. No auto-retry.
9. **Run the first-session smoke tests once** (`windows.md` → First-session smoke
   tests): click_at reaches host, full shift-map, drag, CRD a11y mode.

## Common cold-start questions

**Q: "How do I click something on the Windows screen?"**
Run the canvas-rect helper (`evaluate_script`), get `{rect, hostW, hostH}`, map
your host pixel with `clickX = rect.x + hx*(rect.w/hostW)` (no ÷DPR), then
`mcp.click_at({x,y})`. Screenshot before+after. See SKILL.md "Coordinate math".

**Q: "I typed `Hello` and got `hello`. What gives?"**
`type_text` strips Shift (invariant #4). Route any capital/symbol through the
`send_text` shift-map (`press_key("Shift+<base>")`).

**Q: "How do I right-click?"**
`press_key("Shift+F10")` — there is NO right-click param on `click_at`.

**Q: "Win key / Alt+Tab don't do anything."**
CRD swallows system keys (invariant #5). Click the Start orb / taskbar icon
instead; Ctrl+Alt+Del / PrtScr are CRD DOM buttons (LAYER-1, `crd.md`).

**Q: "`list_pages` hangs."**
A frozen background tab is freezing the enumeration. Run `/devtools`, then wait
for the user to `/mcp` reconnect. Don't auto-retry (invariant #8).

**Q: "There are two CRD tabs."**
One is the Mac mini (`/macmini` — don't touch). Match title `OpenDentalDev1` +
confirm a Windows taskbar. If still ambiguous, STOP and ask (invariant #1).

## How this differs from /macmini

If you know `/macmini`, **negate its mechanics**: no `gh gist`, no `cliclick`, no
on-host run.sh agent, no `/macmini measure` calibration, no Terminal-foreground
dance. Clicks are direct CDP `click_at` into the canvas; arbitrary text is the
per-char shift-map. The full table is in `windows.md` → "How this differs from
/macmini", and the two conflicts to re-check are in
`docs/FINDINGS-2026-05-31.md`.

## Repo conventions

- The dotfiles repo (`~/.claude-dotfiles/`) auto-syncs to GitHub on save (a
  PostToolUse hook commits+pushes every ~2 min). A clean `git status` after an
  edit is the daemon, not a failed edit.
- **Deployment:** `commands/windows.md` + `commands/windows/` are copied to
  `~/.claude/commands/`. The `skills/windows/` tree lives in `~/.claude-dotfiles/`
  ONLY (matches `/macmini` — the deployed `~/.claude/skills/macmini` does not
  exist). That's why the dispatcher must be self-contained.

## File map

```
~/.claude-dotfiles/
├── commands/
│   ├── windows.md                       ← self-contained dispatcher (embeds the 3 helpers)
│   └── windows/
│       ├── connect.md                   ← bind Windows session (title-first), /devtools handoff, Shift-wake
│       ├── act.md                       ← LAYER-2 recipes, the ONE rect helper, shift-map
│       └── crd.md                       ← LAYER-1 uid-by-label + a11y fallback; status + disconnect
└── skills/windows/
    ├── SKILL.md                         ← full runtime reference (PRIMARY)
    ├── ONBOARDING.md                    ← this file
    └── docs/
        └── FINDINGS-2026-05-31.md       ← verified/assumed + the two /macmini conflicts
```
