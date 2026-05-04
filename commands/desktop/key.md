---
description: Press a key or modifier combo via cliclick. Dialog-aware classifier — return/escape/delete reclassify to confirm when a dialog is on screen.
argument-hint: "[key name or combo, e.g. \"return\", \"esc\", \"cmd+w\", \"cmd+shift+s\"]"
---

# /desktop key

Press a key or combo. Dialog-aware safety.

## Steps

1. **Take a fresh screenshot** (or use one if < 2s old by `last.json.timestamp_ms`):
   - Read `/tmp/desktop/last.json` if present; if missing or stale, run `/desktop shot`.

2. **Vision-detect:** is a dialog/modal/sheet visible on screen?

3. **Apply key classifier** (canonical rules: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` → "Key-press classifier"):
   - **SAFE_KEYS** (tab, space, arrow-up/down/left/right, page-up/down, home, end) → fire immediately.
   - **DIALOG_SENSITIVE** (return, esc, delete, fwd-delete) → if dialog visible: confirm with user (show what dialog is focused); else: fire.
   - **Any modifier combo** (uses kd:cmd, kd:ctrl, kd:alt) → always confirm (cmd+w / cmd+q / cmd+a are destructive in the wrong context).

4. **Execute via cliclick:**
   - **`kp:` accepts ONLY named keys** — `return`, `esc`, `tab`, `space`, `arrow-up/down/left/right`, `page-up/down`, `home`, `end`, `delete`, `fwd-delete`, `enter`, `f1`–`f16`, `num-0`–`num-9`. **Letters and digits are NOT valid `kp:` args** — cliclick errors out.
   - **Letter / digit keystrokes use `t:` instead** (with optional held modifier for combos).
   - Single named key: `cliclick kp:<keyname>` — e.g. `cliclick kp:return`
   - Single letter: `cliclick t:'a'`
   - **Cmd+letter (e.g. Cmd+F):** `cliclick kd:cmd t:'f' ku:cmd`
   - **Multi-modifier + letter (e.g. Cmd+Shift+S):** `cliclick kd:cmd kd:shift t:'s' ku:shift ku:cmd` (release modifiers in reverse order).
   - **Cmd + named key (e.g. Cmd+Return):** `cliclick kd:cmd kp:return ku:cmd`
   - Modifier names: `cmd`, `ctrl`, `alt`, `shift`, `fn`.

5. **Sleep 0.4s** then verify via `/desktop shot`.

## Gotchas

- `return` confirms a focused destructive button — re-classify when a dialog is visible.
- `esc` cancels open forms, sometimes destructively.
- cliclick has no chord sugar — explicit `kd:`/`ku:` stacking required, **release in reverse order** of press, otherwise modifiers can stick down on some macOS versions.

## See also

- Key-press classifier (full table): `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
- Screenshot primitive: `/desktop shot`
