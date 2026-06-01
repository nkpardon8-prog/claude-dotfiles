# /macmini crd — LAYER-1 CRD UI (+ status, disconnect)

LAYER-1 is **CRD's own chrome** — the options panel, Disconnect, Full-screen,
"Synchronize clipboard", "Send system keys". Unlike the macOS desktop (LAYER-2,
opaque canvas), this is **real page DOM**. On `/windows`, `take_snapshot` +
`click({uid})` by label works. **On macOS it usually does NOT** — CRD's a11y
tree exposes only the `Desktop` textbox, so LAYER-1 defaults to a
**coordinate-click or user-action** fallback.

## Probe FIRST, then choose the mode (the macOS conflict)

This is the OPPOSITE of `/windows` (where uids worked). **Probe at runtime:**

```
snap = mcp.take_snapshot()
if snap exposes labeled CRD controls (Disconnect / the panel toggles are present as uids):
    # uid mode (unlikely on macOS, but check — CRD/Chrome may change):
    target = uid in snap whose accessible label matches "<Label Text>"
    mcp.click({ uid: target })            # match by LABEL each snapshot; never hardcode a uid
else (only the 'Desktop' textbox shows — the EXPECTED macOS case):
    # uid mode unavailable → coordinate fallback or user action:
    #  (a) hover the right edge of the canvas to slide the panel in, screenshot,
    #      map the on-screen control through the act.md rect helper, click_at it; OR
    #  (b) ask the user to perform the toggle manually (they persist across reconnects).
    # Note which fallback you used in your reasoning so the next agent knows.
```

(First session, run the "CRD a11y" smoke test from `macmini.md` once — on macOS
expect **only `Desktop`**, i.e. coordinate/user-fallback mode.)

## Controls (match these labels / find these on-screen)

| Action | Label |
|---|---|
| Disconnect | `"Disconnect"` |
| Full-screen | `"Full-screen"` |
| Toggle clipboard sync | `"Synchronize clipboard"` |
| Toggle system-key forwarding (load-bearing for Cmd) | `"Send system keys"` |
| Close a CRD dialog / panel | `"Close"` |

**"Send system keys" is load-bearing** — without it ON, `Cmd+Space` / `Cmd+Tab`
/ `Cmd+C` / `Cmd+V` do NOT reach the mini. It's a one-time USER gesture that
persists; the agent usually can't click it (a11y-only-`Desktop`) → ask the user
once (see `setup.md` / `connect.md`).

## `/macmini disconnect`

```
snap = mcp.take_snapshot()
# safety: confirm you are on the MAC tab (title contains plan2bid-minim4, or the
# bound tab from connect) before disconnecting — never disconnect the Windows session.
if "Disconnect" is an addressable uid:  click it
else:  map the on-screen Disconnect button through the act.md rect helper → click_at it
       (or ask the user to click Disconnect)
take_screenshot()    # confirm the session closed / overlay appeared
```

## `/macmini status` — health audit

Report each line; don't act, just diagnose:

1. **Tab present?** `mcp.list_pages()` → is there a CRD tab
   (`remotedesktop.google.com/access/session/`)? If `list_pages` HANGS/errors →
   frozen-tab; recommend `/devtools` (user-gated). Report the hang as a finding.
2. **Title match + select the Mac tab READ-ONLY.** Does a CRD tab title contain
   `plan2bid-minim4`? If yes, `mcp.select_page({pageId, bringToFront:false})` so
   the rect/snapshot steps below read the **Mac** tab — never whatever is
   foreground (which could be the Windows session). If 2+ CRD tabs and none
   match → ambiguous: report it and **STOP — do NOT run steps 3–5** (a
   `take_snapshot` would read the wrong, possibly Windows, tab).
3. **Canvas rect ok?** (on the Mac tab from step 2) Run the act.md rect helper;
   does it return a non-error rect (remote canvas live)? If `error` → no live
   feed (reconnect/sign-in overlay likely).
4. **"Send system keys" state?** This is the one that matters on macOS. If a
   labeled uid exists, report `checked`; otherwise report "a11y exposes only
   `Desktop` → cannot read toggle state programmatically; rely on the Cmd+Space
   smoke test (does `Meta+Space` open Spotlight on the mini?)."
5. **a11y mode?** Did `take_snapshot` expose labeled CRD controls (uid mode) or
   only `Desktop` (coordinate/user-fallback mode — the expected macOS case)?
6. **Frozen-tab / hang probe.** Did any call in this audit hang or error? If so,
   the connection is unhealthy → `/devtools` (user-gated reconnect).

## Invariants

- Probe a11y every session; match by label when uids exist; never reuse a uid.
- Confirm you're on the Mac tab before any LAYER-1 click — never act on the
  Windows CRD session.
- PIN / sign-in fields are user-only — never `fill` or click into them.
