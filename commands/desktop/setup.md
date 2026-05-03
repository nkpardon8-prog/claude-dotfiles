---
description: One-time setup for /desktop — installs cliclick via brew and walks the user through granting Screen Recording + Accessibility TCC permissions to the terminal app.
---

# /desktop setup

One-time onboarding. Run if `/desktop status` reports any failures.

## Steps

1. Run `/desktop status` to find what's missing.

2. **If cliclick is missing:**
   - Confirm with the user before installing: "Install cliclick via Homebrew? (`brew install cliclick`)"
   - On approval: `brew install cliclick`
   - If brew is not installed, surface error and link: https://brew.sh

3. **If Screen Recording is denied:**
   - Echo `$TERM_PROGRAM` so the user knows which app to grant.
   - Open the deep link:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
     ```
   - Tell the user: "Toggle the switch next to **`<$TERM_PROGRAM>`** in the Screen Recording list. If it's not there, click `+` and add it."
   - **The user must restart the terminal app** for TCC to take effect. Confirm restart before continuing.

4. **If Accessibility is denied:**
   - Open the deep link:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
     ```
   - Same walk: toggle `<$TERM_PROGRAM>`, add via `+` if missing, restart terminal.

5. **Re-run `/desktop status`** to confirm everything passes.

## Gotchas

- TCC is per-app: granting Terminal does not grant iTerm. Detect via `echo $TERM_PROGRAM`. Common values: `Apple_Terminal`, `iTerm.app`, `vscode`, `WezTerm`, `Ghostty`.
- Some users run Claude Code via a wrapper that obscures `$TERM_PROGRAM`. If unclear, ask.
- Deep-link URLs occasionally drift between macOS versions. Manual nav fallback: System Settings → Privacy & Security → Screen Recording / Accessibility.
- Never `brew install` without user confirmation.

## See also

- Status check: `/desktop status`
- Troubleshooting: `~/.claude-dotfiles/skills/desktop/README.md`
