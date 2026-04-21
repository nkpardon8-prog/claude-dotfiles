---
description: "Manage Antigravity Google AI accounts — switch active profile, open profiles for authentication, show current status. Use for switching between google-pro-1/2/3 accounts for code review loops."
argument-hint: "[switch google-pro-1|2|3 | open google-pro-1|2|3 | status]"
---

# Antigravity Account Manager

Antigravity is a Google AI coding tool integrated into the hybrid review system. Three isolated profiles are configured: google-pro-1, google-pro-2, google-pro-3 — each with its own browser profile and Google account.

## Step 1: Determine the action

Parse `$ARGUMENTS`:

- `switch google-pro-1` / `switch google-pro-2` / `switch google-pro-3` → set active route to that profile
- `open google-pro-1` / `open google-pro-2` / `open google-pro-3` → open that profile in Antigravity for authentication/setup
- `status` or empty → show current active route and all profile states

## Step 2: Execute

### Show Status (default / "status")

```bash
# Read current state
cat /Users/nickpardon/claude-hybrid-control/state/router-state.json 2>/dev/null || echo "{}"
```

Then read `/Users/nickpardon/claude-hybrid-control/state/agent-router-status.md` for human-readable status.

Report to user:
```
Antigravity Profiles:
  google-pro-1  — Google Pro 1  — [active/inactive]
  google-pro-2  — Google Pro 2  — [active/inactive]
  google-pro-3  — Google Pro 3  — [active/inactive]

Active route: [provider] / [profile]
Reports: /Users/nickpardon/claude-hybrid-control/reports/
```

### Switch Profile ("switch google-pro-N")

```bash
/Users/nickpardon/claude-hybrid-control/bin/set-review-route.sh antigravity google-pro-N
```

Where N is 1, 2, or 3 based on the argument.

Report: "Active route set to: Antigravity / Google Pro N"

Remind the user: the SwiftBar taskbar will reflect the change on its next refresh (every 10s).

### Open Profile ("open google-pro-N")

```bash
/Users/nickpardon/claude-hybrid-control/bin/setup-review-profile.sh antigravity google-pro-N
```

This opens the Antigravity app with the isolated Google Pro N profile. Use this to sign into a Google account or verify the profile is authenticated.

Report: "Opened Antigravity with Google Pro N profile. Sign in if prompted, then close the window."

## Step 3: Show available commands

After any action, show a compact reference:
```
Commands:
  /antigravity status          — show current account status
  /antigravity switch google-pro-1  — set active to Google Pro 1
  /antigravity switch google-pro-2  — set active to Google Pro 2
  /antigravity switch google-pro-3  — set active to Google Pro 3
  /antigravity open google-pro-1    — open profile for auth
  /antigravity open google-pro-2    — open profile for auth
  /antigravity open google-pro-3    — open profile for auth
```

## Notes

- Each profile is fully isolated — separate Google accounts, cookies, and sessions
- Profile data lives at `/Users/nickpardon/claude-hybrid-control/profiles/antigravity/google-pro-N/`
- To clear a profile (log out / reset): use the SwiftBar menu → Accounts → Danger Zone → Clear Antigravity Google Pro N
- The active route is used by the single-route review system. The master-review loop always uses google-pro-1 AND google-pro-2 in parallel regardless of active route.
- To check recent review output: open `/Users/nickpardon/claude-hybrid-control/reports/`
