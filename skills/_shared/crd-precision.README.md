# crd-precision — CRD LAYER-2 precise-clicking helpers

Canonical source: [`crd-precision.js`](./crd-precision.js). Proven live 2026-07-02
against the OpenDental Demo Database over Chrome Remote Desktop (chrome-devtools MCP,
port 9222): **96% hit-rate across 26 trials on 15-90px targets**. Full measurements,
transform derivation, and the stress-board results:
[`../windows/docs/FINDINGS-2026-07-02-precision.md`](../windows/docs/FINDINGS-2026-07-02-precision.md).

This directory is **authoring/reference only** — it is NOT loaded at runtime. The
helpers reach agents ONLY as the inline fenced block in the "## Precision targeting
(LAYER-2)" section of `commands/windows.md` and `commands/macmini.md`.

## What each helper does

| Helper | Purpose |
|---|---|
| `crdMeta()` | Live geometry of the largest remote canvas (rendered-area>40000 filter drops the decoy canvases): `{rectX,rectY,rectW,rectH,hostW,hostH,dpr,sx,sy}`. Returns an EXPLICIT flat shape because DOMRect exposes `.width/.height`, not `.w/.h`. `sx/sy` = CSS-px per host-px. |
| `crdMap(target, meta)` | Maps `{host}` \| `{norm}` \| `{shot}` → `{clickX,clickY,host}`. `clickX/clickY` feed `click_at`. **SHOT space is DEVICE px** (a native screenshot is innerW×DPR) so it divides by dpr. **Supersedes the old canvas-rect helper** — one callable for all three spaces. |
| `crdLoupe(cx,cy,half,zoom)` | Injects a magnifier overlay (id `__crd_loupe__`), `imageSmoothingEnabled=false`, drawing the host region around `(cx,cy)` at `zoom`×. Returns `{srcX,srcY,srcW,srcH,ovX,ovY,ovW,ovH}` for a no-hand-math inverse map. Placed top-right, below the CRD toolbar occlusion band. |
| `crdLoupeUnmap(px,py,loupe,dpr)` | Inverse-maps an in-loupe screenshot pixel (DEVICE px) back to host space. |
| `crdCrosshair(hx,hy)` | Injects a crosshair overlay (id `__crd_cross__`) at a host point; returns the `{clickX,clickY}` it marks. Pure DOM confirm-before-commit. |
| `crdClearOverlays()` | Removes both overlay ids. Call before every `click_at`. |

## The readback / loupe rationale

Eyeballing a full screenshot is off 20-40px against 12-20px targets. The loupe draws
the *same-origin* remote canvas into an in-page overlay with smoothing off, so a tiny
target becomes crisply readable in the next screenshot — the `drawImage` +
`getImageData` readback is non-black (same-origin, no taint). The crosshair is the
confirm-before-commit step: a pure-DOM marker at the proposed host point that a
screenshot verifies **before** any host interaction. Cursor-servoing was rejected —
the MCP `hover` tool is uid-only (no coordinate hover), so there is no streamed cursor
to servo against; the crosshair replaces it. Both overlays are `pointer-events:none`
so a missed clear can never swallow the click; the helpers return their own src/overlay
rects so the agent never does coordinate math by hand.

## The JPEG / batch rule (load-bearing — proven this session)

A PNG-screenshotting loop over many targets hits the chrome-devtools MCP **32MB
request limit and dies**. When running a precision loop, always
`take_screenshot({ format: 'jpeg', quality: 50 })` and cap the loop at
**~10 targets per batch**. The whole loop runs in ONE Sonnet-5 sub-agent (low/med
effort) that owns it end-to-end; Opus only orchestrates/recovers.

## How to re-embed into the .md files

The `.md` inline copies are the deployed artifact — the `skills/` tree is not loaded at
runtime. `~/.claude/commands` is a symlink to `~/.claude-dotfiles/commands`, so editing
the `.md` IS editing the deployed skill (no sync step).

1. Edit `crd-precision.js` here (single source of truth).
2. Copy the helper functions **verbatim** into the fenced ```js block inside the
   "## Precision targeting (LAYER-2)" section of BOTH `commands/windows.md` and
   `commands/macmini.md`. The two embedded copies MUST stay byte-identical to this file
   and to each other (single source, embedded twice).
3. The functions are injected via `mcp.evaluate_script`, which is **stateless for
   definitions** — each call re-includes the whole block, then `return` the one call you
   need (e.g. `() => { /* whole block */ ; return crdLoupe(277,47); }`). Overlay DOM
   persists across calls; function defs do not.
4. Never introduce `innerHTML` — the CRD page enforces Trusted Types and it throws. All
   overlay DOM is `createElement` + `appendChild` + `.style` only.

## Drift

The two embedded copies + this source are a silent-drift shape: an agent edits one .md
and forgets the twin. Keep them identical by hand-diffing the fenced block against this
file whenever either changes (a hash-compare check can be added to authoring if drift
recurs).
