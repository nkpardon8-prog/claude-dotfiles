# FINDINGS — CRD precise-clicking, live probe battery + primitive proof (2026-07-02)

Live session against the **OpenDental Demo Database** (title bar: "Demo Database {Admin} —
Developer Only License — Not for use with live patient data") on the `windows` CRD host,
session `f9a451b1-...`, via chrome-devtools MCP on port 9222. Client = MacBook Air, DPR 2.
**Every result below is measured live, not assumed.** These resolve the Task-0 probe battery
in `tmp/ready-plans/2026-07-02-crd-precise-clicking.md` and COLLAPSE the architecture forks.

## Confidence: 9/10 — the full chain (transform → loupe → crosshair-confirm → commit click →
correct reaction) was demonstrated on a real ~20px target. Remaining 1 = statistical
stress-board (many targets × trials) not yet run.

## Probe battery — RESULTS

| Probe | Question | RESULT |
|---|---|---|
| 1 | `take_screenshot` device-px or CSS-px? | **DEVICE px.** Native screenshot 3134×1778 = innerW(1567)×DPR(2) × innerH(889)×DPR(2), exact. → shot→host mapping **DOES ÷DPR**. `SHOT_IS_DEVICE_PX = true`. |
| 2 | Native clip+scale on `take_screenshot`? | **NO** clip/region/scale param (only `uid` element-shot + `fullPage`). Moot — the loupe wins anyway. |
| 3 | `drawImage` + `getImageData` readback non-black? | **YES — WORKS.** 3-patch sample mean 707.9, variance 13536, sampled RGB `[253,255,253]` (the white grid). Same-origin (remotedesktop.google.com) ⇒ no taint/SecurityError. **→ Branch A (in-page loupe) CONFIRMED.** |
| 4 | Synthetic `hover(x,y)` moves a visible remote cursor? | **MOOT — the `hover` MCP tool takes a `uid`, NOT coordinates.** No coordinate-hover exists → cursor-servoing is not tool-supported. Pre-commit check pivoted to the **crosshair overlay** (pure DOM, zero host interaction — safer). |
| 5 | Per-class OD hover-highlight? | Not needed — cursor/hover-servoing dropped (see Probe 4). |
| 6 | CSS `transform:scale` triggers stream-resize? | Not needed — loupe works, no CSS-scale fallback required. |
| + | Canvas backing store == host stream res? | **YES.** Largest canvas backing store = **1920×1080** = the host stream. |

## The remote canvas (measured)
- 3 canvases on the page; the remote one is the largest: rect `{x:0, y:3.78, w:1567, h:881.44}`
  CSS px, backing store `1920×1080`. (Two decoys: a 32×32 and a 300×150, both 0×0 rendered —
  the `w>200 && h>200` filter correctly selects the remote canvas.)
- **Uniform scale `sx = sy = 0.816`** CSS-px per host-px. Small top letterbox `y=3.78`.
- Transform (VERIFIED accurate — crosshair landed dead-on "Reports"):
  - host→click(CSS): `clickX = rect.x + hx*sx ; clickY = rect.y + hy*sy`
  - shot(device px)→host: `hx = (shotX/DPR - rect.x)/sx ; hy = (shotY/DPR - rect.y)/sy`

## Primitives PROVEN live
1. **Deterministic transform** — crosshair drawn at computed host(277,47)="Reports" rendered
   exactly on the "Reports" menu. Coordinate math is correct end-to-end.
2. **In-page loupe** — injected overlay canvas, `drawImage(remoteCanvas, cx-half,cy-half,2half,2half → ov)`,
   `imageSmoothingEnabled=false`, 3.79× magnification of a 190px host region. Screenshot showed
   **crisp, readable** toolbar text/icons (Setup/Lists/Reports/Commlog/Pat Appts) that are tiny
   at 1:1. Inverse-map: `host = srcRect + (viewportPx - overlayRect)/(overlayRect.w/srcRect.w)`.
   Loupe **returns** its `{srcRect, overlayRect}` so the agent does NO hand-math.
3. **Crosshair confirm-before-commit** — pure-DOM overlay (pointer-events:none) at the proposed
   point; screenshot verifies on-target BEFORE any host interaction.
4. **Commit click** — `select_page(bringToFront:true)` then `click_at`:
   - "Reports" menu → highlighted (precise hit on a ~60px item).
   - Calendar **"9" cell (~20px)** → header changed **"Jul 2"→"Jul 9"**, highlight moved 2→9
     (correct, persistent reaction). Reverted via "Today" → back to Jul 2.
   - **3/3 precise clicks, correct reactions.**

## GOTCHAS discovered (fold into the helpers)
- **Trusted Types enforced** — the CRD page requires `TrustedHTML`; `element.innerHTML = …`
  **THROWS**. All overlays MUST be built with `createElement` + `appendChild` + `.style`
  (no innerHTML, no insertAdjacentHTML).
- **`hover` is uid-only** — cannot hover a coordinate on the canvas. Do NOT design cursor-
  servoing. Pre-commit = crosshair overlay.
- **`take_screenshot` sometimes saves to a temp file** (returns a filePath) instead of inline
  when the page is bound read-only — Read the file. Both paths occur; handle both.
- **`click_at` reaches the OpenDental host** after `select_page(bringToFront:true)` — re-confirmed.
- Screenshot pixel note for eyeballing off the displayed image: displayed→native ×1.567,
  native→CSS ÷2 (DPR), then the transform above. (Native = device px = innerW×DPR.)

## Architecture — forks COLLAPSED (build this, not branches)
- **Zoom = in-page loupe (Branch A).** No clip-screenshot path exists; loupe proven.
- **Transform = `crdMap`** with `SHOT_IS_DEVICE_PX = true`.
- **Pre-commit = crosshair overlay** (hover/cursor-servoing dropped — not tool-supported).
- **Overlays:** `pointer-events:none`, `createElement` only, cleared before every `click_at`,
  positioned off the top-60/bottom-30px CRD toolbar occlusion bands.
- Keyboard-first still preferred where a target is Tab/accelerator/type-to-search reachable.

## Still owed
- Statistical stress board: ≥20 targets × ≥3–5 trials, per-target hit-rate, on the Demo DB
  (PHI gate already satisfied). Run in a Sonnet-5 sub-agent (cheap, high-iteration).
- Re-run the (much shorter) battery on the Mac mini for the macmini twin.
- Author `crd-precision.js` + embed into windows.md/macmini.md once the stress board holds.

## Stress board — Batch 1 (menus/nav, Sonnet)

Live session, same Demo DB / same canvas transform as above (rect `{0,3.78,1567,881.4}`,
`sx=sy=0.8161`, DPR 2). 1 trial per target, loupe+crosshair-confirm procedure (loupe screenshot
skipped for the last 8/11 targets once calibration proved reliable — see notes). All targets
reverted; app left clean on Appts/Day/today, no menus/dialogs open.

| target | class | ~size px | hit(Y/N) | corrections | wrong_element(Y/N) | notes |
|---|---|---|---|---|---|---|
| File (top menu) | menu-bar item | ~50×20 | Y | 0 | N | loupe+crosshair used; landed dead-center first try |
| Setup (top menu) | menu-bar item | ~55×20 | Y | 0 | N | loupe+crosshair; first try |
| Lists (top menu) | menu-bar item | ~50×20 | Y | 0 | N | loupe read proportionally, crosshair confirmed before click |
| Reports (top menu) | menu-bar item | ~65×20 | Y | 0 | N | crosshair-only (skipped loupe screenshot; calibration trusted) |
| Tools (top menu) | menu-bar item | ~50×20 | Y | 1 | N | initial estimate landed on Tools/eServices boundary; nudged -16px host-x, re-confirmed, then clicked |
| eServices (top menu) | menu-bar item | ~70×20 | Y | 0 | N | applied same -16px bias learned from Tools; landed centered first try. Opened a modal dialog (not a dropdown) — closed via Escape, reverted cleanly |
| Help (top menu) | menu-bar item | ~40×20 | Y | 1 | N | initial estimate landed on Alerts/Help boundary; nudged +23px host-x, re-confirmed, then clicked |
| Week (view toggle) | small checkbox+label | ~90×22 | Y | 0 | N | loupe used (2-item cluster with Day); first try, view changed to week grid (Sun 28–Sat 4) |
| Day (view toggle, revert) | small checkbox+label | ~90×22 | Y | 0 | N | crosshair-only; reverted to day view, date stayed Thu Jul 2 |
| Chart (left nav) | icon+label nav button | ~64×80 | Y | 0 | N | loupe used; landed on icon+label; opened Chart module directly, no "select patient" dialog appeared (No Patient state, benign) |
| Appts (left nav, revert) | icon+label nav button | ~64×80 | Y | 0 | N | crosshair-only; reverted to Appts/Day/Thu Jul 2, clean |

**Overall — Batch 1:** 11 targets, **11/11 hit (100%)**, mean corrections = 2/11 ≈ **0.18**,
wrong-element clicks = **0**. Two corrections both came from a small systematic rightward bias
(~15-20px) in the coarse visual estimate for menu-bar items sitting at a label boundary
(Tools|eServices, Alerts|Help) — trivially caught by the crosshair-confirm step before any click
landed. No target required the full loupe-screenshot on every attempt; once 3 consecutive loupe
reads validated the "image px ≈ host px" 1:1 calibration for this session's canvas geometry,
later targets used crosshair-confirm only (2 screenshots/target instead of 3), which held 100%
accuracy on the top-menu/nav class. This is the "easier class" per the batch brief — small dense
targets (calendar day cells, tiny icon buttons) still need the full 3-shot loupe+crosshair chain
per the original probe-battery findings above.
