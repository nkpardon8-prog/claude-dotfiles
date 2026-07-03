// crd-precision.js — canonical source for the CRD LAYER-2 precise-clicking helpers.
//
// PROVEN LIVE 2026-07-02 against the OpenDental Demo Database over Chrome Remote
// Desktop (chrome-devtools MCP, port 9222): 96% hit-rate across 26 trials on
// 15-90px targets. Findings + math: skills/windows/docs/FINDINGS-2026-07-02-precision.md.
//
// These functions run in PAGE context via `mcp.evaluate_script({ function: "..." })`.
// evaluate_script is STATELESS for definitions — each call must re-include the whole
// block, then `return <theOneCall>` at the end. Overlay DOM (ids below) DOES persist
// across calls. Example injection:
//     () => { /* paste this entire file */ ; return crdMeta(); }
//     () => { /* paste this entire file */ ; return crdLoupe(277, 47); }
//
// HARD CONSTRAINT — the CRD page enforces Trusted Types: `element.innerHTML = ...`
// THROWS. Every overlay here is built with createElement + appendChild + .style ONLY.
// Never introduce innerHTML / insertAdjacentHTML / outerHTML in these helpers.
//
// This file is the SINGLE SOURCE. It is embedded verbatim (identical bytes) into the
// "## Precision targeting (LAYER-2)" section of BOTH commands/windows.md and
// commands/macmini.md — those inline copies are the only thing an agent loads at
// runtime (the symlink `~/.claude/commands` → `~/.claude-dotfiles/commands` means
// editing the .md IS editing the deployed skill; there is no sync step). If you edit
// here, re-embed both. See crd-precision.README.md for the re-embed + drift rule.

/** Select the remote CRD canvas: largest element by RENDERED area, decoys excluded
 *  (OpenDental's page carries 32x32 and 300x150 decoy canvases that render 0x0, so an
 *  area>40000 filter on the getBoundingClientRect area cleanly drops them). */
function _crdPickCanvas() {
  return [...document.querySelectorAll('canvas')]
    .map(e => { const r = e.getBoundingClientRect();
                return { e, x:r.x, y:r.y, w:r.width, h:r.height, bw:e.width, bh:e.height }; })
    .filter(o => o.w * o.h > 40000)          // rendered area; decoys render 0x0
    .sort((a, b) => b.w * b.h - a.w * a.h)[0];
}

/** Live geometry of the remote canvas. Returns an EXPLICIT flat shape — DOMRect
 *  exposes .width/.height (not .w/.h), so we copy fields by name to avoid the footgun.
 *  sx/sy are CSS-px per host-px (uniform ~0.816 on the measured Windows canvas).
 *  @returns {{rectX,rectY,rectW,rectH,hostW,hostH,dpr,sx,sy}|{error:string}} */
function crdMeta() {
  const c = _crdPickCanvas();
  if (!c) return { error: 'no remote canvas found' };
  return {
    rectX: c.x, rectY: c.y, rectW: c.w, rectH: c.h,   // CSS-px canvas rect
    hostW: c.bw, hostH: c.bh,                          // backing store == host stream res
    dpr: window.devicePixelRatio,
    sx: c.w / c.bw, sy: c.h / c.bh                     // CSS-px per host-px
  };
}

/** Map a target in host | normalized | screenshot space to a click point.
 *  SHOT space is DEVICE px (a native screenshot is innerW x DPR) → divide by dpr.
 *  This SUPERSEDES the old canvas-rect helper (one callable for all three spaces).
 *  @param {{host:{x,y}}|{norm:{x,y}}|{shot:{x,y}}} target
 *  @param {object} [meta] result of crdMeta(); read live if omitted
 *  @returns {{clickX,clickY,host:{x,y}}|{error:string}} clickX/clickY feed click_at */
function crdMap(target, meta) {
  const m = meta || crdMeta();
  if (m.error) return m;
  let hx, hy;
  if (target.host)      { hx = target.host.x;             hy = target.host.y; }
  else if (target.norm) { hx = target.norm.x * m.hostW;   hy = target.norm.y * m.hostH; }
  else if (target.shot) { hx = (target.shot.x / m.dpr - m.rectX) / m.sx;   // SHOT = DEVICE px
                          hy = (target.shot.y / m.dpr - m.rectY) / m.sy; }
  else return { error: 'target needs {host}|{norm}|{shot}' };
  return { clickX: m.rectX + hx * m.sx, clickY: m.rectY + hy * m.sy, host: { x: hx, y: hy } };
}

/** Inject a magnifier overlay (id __crd_loupe__) that draws a host-space region
 *  around (cx,cy) at `zoom`x with imageSmoothing OFF, so tiny targets become readable
 *  in the next screenshot. Returns its own src/overlay rects so the agent does NO hand
 *  math — feed an in-loupe screenshot pixel straight into crdLoupeUnmap.
 *  Placed TOP-RIGHT, anchored below the CRD auto-hiding-toolbar occlusion band (the
 *  toolbar can sit over the top ~60px / bottom ~30px of the canvas), so it never hides
 *  the target row it is magnifying.
 *  Tuning: sub-20px targets → half=40, zoom=8 (crisp digit/button separation);
 *          larger targets   → half=90, zoom=5 (wide catch for 20-40px coarse error).
 *  @param {number} cx @param {number} cy  host-space center of the region
 *  @param {number} [half=40] half-width of the host crop (crop = 2*half square)
 *  @param {number} [zoom=8]  magnification
 *  @returns {{srcX,srcY,srcW,srcH,ovX,ovY,ovW,ovH}|{error:string}} */
function crdLoupe(cx, cy, half, zoom) {
  if (half == null) half = 40;
  if (zoom == null) zoom = 8;
  const c = _crdPickCanvas();
  if (!c) return { error: 'no remote canvas found' };
  const srcX = cx - half, srcY = cy - half, srcW = 2 * half, srcH = 2 * half;
  const ovW = srcW * zoom, ovH = srcH * zoom;
  const ovX = Math.max(10, window.innerWidth - ovW - 10);   // top-RIGHT
  const ovY = 70;                                           // clear of the top ~60px band
  const old = document.getElementById('__crd_loupe__');
  if (old) old.remove();
  const cv = document.createElement('canvas');
  cv.id = '__crd_loupe__';
  cv.width = ovW; cv.height = ovH;
  Object.assign(cv.style, {
    position: 'fixed', left: ovX + 'px', top: ovY + 'px',
    width: ovW + 'px', height: ovH + 'px',
    zIndex: '2147483647', pointerEvents: 'none',
    border: '2px solid #ff2d55', boxShadow: '0 0 0 1px #000'
  });
  const ctx = cv.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(c.e, srcX, srcY, srcW, srcH, 0, 0, ovW, ovH);
  document.body.appendChild(cv);
  return { srcX, srcY, srcW, srcH, ovX, ovY, ovW, ovH };
}

/** Inverse-map an in-loupe screenshot pixel (DEVICE px) back to host space.
 *  @param {number} px @param {number} py  device-px coords read off the loupe overlay
 *  @param {{srcX,srcY,srcW,srcH,ovX,ovY,ovW,ovH}} loupe  the crdLoupe() return
 *  @param {number} dpr  crdMeta().dpr
 *  @returns {{x,y}} host-space coords (feed to crdMap({host}) / crdCrosshair) */
function crdLoupeUnmap(px, py, loupe, dpr) {
  const cssX = px / dpr, cssY = py / dpr;                 // device px -> CSS px
  const fx = (cssX - loupe.ovX) / loupe.ovW;             // fraction across the overlay
  const fy = (cssY - loupe.ovY) / loupe.ovH;
  return { x: loupe.srcX + fx * loupe.srcW, y: loupe.srcY + fy * loupe.srcH };
}

/** Inject a crosshair overlay (id __crd_cross__) at a HOST point so a screenshot can
 *  confirm on-target BEFORE any click (pure DOM, zero host interaction — safer than
 *  cursor-servoing, which isn't tool-supported: `hover` is uid-only, no coordinate hover).
 *  @param {number} hx @param {number} hy  host-space point
 *  @returns {{clickX,clickY}|{error:string}} the CSS-px click point it marks */
function crdCrosshair(hx, hy) {
  const m = crdMeta();
  if (m.error) return m;
  const clickX = m.rectX + hx * m.sx, clickY = m.rectY + hy * m.sy;
  const old = document.getElementById('__crd_cross__');
  if (old) old.remove();
  const bar = (w, h, l, t, color) => {
    const d = document.createElement('div');
    Object.assign(d.style, {
      position: 'fixed', left: l + 'px', top: t + 'px', width: w + 'px', height: h + 'px',
      background: color, zIndex: '2147483647', pointerEvents: 'none'
    });
    return d;
  };
  const box = document.createElement('div');
  box.id = '__crd_cross__';
  Object.assign(box.style, { position: 'fixed', left: '0', top: '0', zIndex: '2147483647', pointerEvents: 'none' });
  const arm = 12;
  box.appendChild(bar(2 * arm, 1, clickX - arm, clickY, '#ff2d55'));   // horizontal arm
  box.appendChild(bar(1, 2 * arm, clickX, clickY - arm, '#ff2d55'));   // vertical arm
  box.appendChild(bar(3, 3, clickX - 1, clickY - 1, '#00e5ff'));       // center dot
  document.body.appendChild(box);
  return { clickX, clickY };
}

/** Remove both overlays. ALWAYS call this before click_at (an overlay is
 *  pointer-events:none so it can't swallow the click, but clear anyway to keep the
 *  post-click "after" screenshot honest). @returns {{cleared:true}} */
function crdClearOverlays() {
  const l = document.getElementById('__crd_loupe__'); if (l) l.remove();
  const x = document.getElementById('__crd_cross__'); if (x) x.remove();
  return { cleared: true };
}
