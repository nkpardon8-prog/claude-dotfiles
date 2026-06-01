# /windows crd — LAYER-1 CRD UI by uid-label (+ status, disconnect)

LAYER-1 is **CRD's own chrome** — the options panel, dialogs, Disconnect,
Full-screen, "Synchronize clipboard", "Press Ctrl + Alt + Del", "Press PrtScr".
Unlike the Windows desktop (LAYER-2, opaque canvas), this is **real page DOM**:
drive it with `mcp.take_snapshot()` + `mcp.click({uid})`, matching the control
by its **LABEL text** each snapshot.

## Match by label, never hardcode uids

uids are **per-snapshot** — they change every `take_snapshot`. ALWAYS re-snapshot
and match the control by its visible label. **Never transcribe an example uid**
(the live test saw `2_7`, `2_8`, `2_43`, `2_44`, `2_62`, etc. — those are dead
on the next snapshot; do not paste them anywhere).

```
snap = mcp.take_snapshot()
target = uid in snap whose accessible label matches "<Label Text>"
mcp.click({ uid: target })
```

## a11y fallback (the `/macmini` conflict — re-check at runtime)

`/macmini` found CRD's a11y tree returns `ignored` for its controls. On THIS
Windows session, the controls exposed clickable uids. So **probe at runtime:**

```
snap = mcp.take_snapshot()
if snap exposes labeled CRD controls (the panel buttons are present):
    drive LAYER-1 by uid-label (above)
else (a11y returns 'ignored' — macmini's experience):
    fall back to coordinate click_at on the panel control's on-screen location
    (map via the rect helper in act.md), OR ask the user to perform the toggle
    manually. Note the fallback in your reasoning so the next agent knows.
```

(First session, run the "CRD a11y" smoke test from `windows.md` once to learn
which mode this session is in.)

## Controls (match these labels)

| Action | Label to match |
|---|---|
| Disconnect | `"Disconnect"` |
| Full-screen | `"Full-screen"` |
| Toggle clipboard sync | `"Synchronize clipboard"` |
| Send Ctrl+Alt+Del to host | `"Press Ctrl + Alt + Del"` |
| Send PrtScr to host | `"Press PrtScr"` |
| Close a CRD dialog / panel | `"Close"` |

These are the system combos that CRD swallows on LAYER-2 (`press_key` can't
forward them) — that's exactly why they exist as DOM buttons here.

## `/windows disconnect`

```
snap = mcp.take_snapshot()
# safety: confirm you are on the WINDOWS tab (title contains OpenDentalDev1, or
# the bound tab from connect) before clicking — never disconnect the Mac session.
click the uid whose label matches "Disconnect"
take_screenshot()    # confirm the session closed / overlay appeared
```

## `/windows status` — health audit

Report each line; don't act, just diagnose:

1. **Tab present?** `mcp.list_pages()` → is there a CRD tab
   (`remotedesktop.google.com/access/session/`)? If `list_pages` HANGS/errors →
   frozen-tab; recommend `/devtools` (user-gated). Report the hang itself as a
   finding.
2. **Title match + select the Windows tab READ-ONLY.** Does a CRD tab title
   contain `OpenDentalDev1`? If yes, `mcp.select_page({pageId, bringToFront:false})`
   so the rect/snapshot steps below read the **Windows** tab — never whatever is
   foreground (which could be the Mac session). If 2+ CRD tabs and none match →
   ambiguous: report it and **STOP — do NOT run steps 3–5** (a `take_snapshot`
   would read the wrong, possibly Mac, tab).
3. **Canvas rect ok?** (on the Windows tab from step 2) Run the act.md rect
   helper; does it return a non-error rect (remote canvas live)? If `error` → no
   live feed (reconnect/sign-in overlay likely).
4. **Clipboard sync state?** `take_snapshot` (Windows tab); is "Synchronize
   clipboard" present and `checked`? (Informational — clipboard bridge is v2; not
   load-bearing for ASCII typing.)
5. **a11y mode?** Did `take_snapshot` expose labeled CRD controls (uid mode) or
   return `ignored` (coordinate-fallback mode)?
6. **Frozen-tab / hang probe.** Did any call in this audit hang or error? If so,
   the connection is unhealthy → `/devtools` (user-gated reconnect).

## Invariants

- Match by label every snapshot; never reuse a uid.
- Confirm you're on the Windows tab before any LAYER-1 click — never act on the
  Mac CRD session.
- PIN / sign-in fields are user-only — never `fill` or click into them.
