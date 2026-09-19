// quality-drive.mjs - RAW-CDP driver for `/ui-audit --quality` (UI quality + consistency mode).
//
//   node quality-drive.mjs --base <URL> --out <DIR> [--routes=a,b,c] [--max-routes N]
//                          [--desktop] [--expand] [--read-only] [--port N]
//
// For each route, at a MOBILE viewport (390x844 @2x, touch) and optionally DESKTOP (1440x900):
//   navigate -> open <details> disclosures (DOM property only, no click) -> inject lib/quality-scan.js
//   via Runtime.evaluate -> full-page screenshot + viewport-height tiles -> write the scan JSON.
// Then merge every route's format/variant census into one cross-screen consistency file.
//
// READ-ONLY BY CONSTRUCTION: this driver only navigates and sets `details.open = true`. It never
// clicks, types, or submits. `--expand` additionally clicks `[aria-expanded="false"]` disclosure
// toggles, and ONLY with the wire-level read-only guard installed (every non-GET aborted), so a
// mislabeled toggle cannot mutate data. `--read-only` installs that same guard for the whole run
// (use it when even page-load POSTs must not fire; note it can break apps that fetch data over POST).
// Without the guard, every non-GET the page itself fires on load is logged to quality-network.log.
//
// It opens ONE new tab, never touches existing tabs, and closes its tab on exit.
//
// Writes under <DIR>:
//   quality/<slug>.<viewport>.scan.json      one scan per route per viewport
//   quality/census.json                      cross-screen format + button-variant census
//   quality/manifest.json                    routes, viewports, screenshots, errors, auth redirects
//   screenshots/<slug>.<viewport>.png        full page
//   screenshots/<slug>.<viewport>.tile-N.png viewport-height tiles (legible for vision on tall pages)
//   quality-network.log                      non-GET requests fired (or blocked) during the run

import { mkdirSync, writeFileSync, appendFileSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { openTab, InfraError, installReadOnlyGuard, installMutationLogger } from './cdp.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCAN_SRC = readFileSync(join(HERE, 'quality-scan.js'), 'utf8');

function parseArgs(argv) {
  const a = { base: '', out: '', routes: '', maxRoutes: 12, desktop: false, expand: false, readOnly: false, port: undefined, maxTiles: 8 };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    const val = (name) => (t === name ? argv[++i] : t.startsWith(name + '=') ? t.slice(name.length + 1) : undefined);
    let v;
    if ((v = val('--base')) !== undefined) a.base = v;
    else if ((v = val('--out')) !== undefined) a.out = v;
    else if ((v = val('--routes')) !== undefined) a.routes = v;
    else if ((v = val('--max-routes')) !== undefined) a.maxRoutes = Number(v);
    else if ((v = val('--max-tiles')) !== undefined) a.maxTiles = Number(v);
    else if ((v = val('--port')) !== undefined) a.port = Number(v);
    else if (t === '--desktop') a.desktop = true;
    else if (t === '--expand') a.expand = true;
    else if (t === '--read-only') a.readOnly = true;
    else { console.error(`quality-drive: unknown arg ${t}`); process.exit(2); }
  }
  return a;
}

const args = parseArgs(process.argv.slice(2));
if (!args.base || !args.out) {
  console.error('usage: node quality-drive.mjs --base <URL> --out <DIR> [--routes=a,b,c] [--max-routes N] [--desktop] [--expand] [--read-only] [--port N]');
  process.exit(2);
}

const OUT = args.out;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const VIEWPORTS = [{ name: 'mobile', width: 390, height: 844, dsf: 2, mobile: true }];
if (args.desktop) VIEWPORTS.push({ name: 'desktop', width: 1440, height: 900, dsf: 1, mobile: false });

const slugOf = (u) => {
  const p = new URL(u);
  const s = (p.pathname + (p.search || '')).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  return (s || 'root').slice(0, 60);
};

// Links we never follow while crawling: session-ending or destructive-sounding, downloads, non-http.
const SKIP_HREF = /(log-?out|sign-?out|signoff|delete|remove|destroy|unsubscribe|deactivate|\/api\/|\.(pdf|zip|csv|png|jpe?g|ics)(\?|$))/i;

const CRAWL_EXPR = `(() => {
  const vis = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const grab = (sel) => Array.from(document.querySelectorAll(sel)).filter((a) => !a.hasAttribute('download') && (!a.target || a.target === '_self')).map((a) => ({ href: a.href, text: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 60), visible: vis(a) }));
  const nav = grab('nav a[href], header a[href], [role="navigation"] a[href], [role="tablist"] a[href], footer a[href], [class*="tabbar" i] a[href], [class*="sidebar" i] a[href]');
  const rest = grab('a[href]');
  return { nav, rest };
})()`;

// Scroll the whole page once (viewport steps, bounded) so lazy images and scroll-reveal sections
// render before the scan + screenshot, then return to the top. Scrolling is read-only.
// `documentElement` can be momentarily null while a client-side route swap is in flight, which used
// to throw and lose the whole route. Re-read the height each step and bail out instead of throwing.
const SCROLL_PASS_EXPR = `(async () => {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const docH = () => { const d = document.documentElement, b = document.body; return Math.max(d ? d.scrollHeight : 0, b ? b.scrollHeight : 0); };
  let steps = 0;
  for (let y = 0; y < docH() && steps < 40; y += Math.max(1, Math.round(window.innerHeight * 0.8))) { window.scrollTo(0, y); steps++; await wait(120); }
  window.scrollTo(0, 0); await wait(400);
  return steps;
})()`;

// Opening <details> is a pure DOM property write: no click handler runs, no request fires.
const OPEN_DETAILS_EXPR = `(() => { const d = Array.from(document.querySelectorAll('details:not([open])')); d.forEach((x) => { x.open = true; }); return d.length; })()`;

// --expand only: click collapsed disclosure toggles. Conservative target set - a real disclosure
// (aria-controls or a <summary>-like button), not in a form, not a link, not destructive-sounding.
const EXPAND_EXPR = `(() => {
  const DENY = /(delete|remove|cancel|submit|approve|reject|send|pay|book|confirm|sign|log ?out|save)/i;
  let n = 0;
  for (const el of Array.from(document.querySelectorAll('[aria-expanded="false"]'))) {
    if (el.tagName === 'A' || el.closest('form') || el.getAttribute('type') === 'submit') continue;
    if (!el.getAttribute('aria-controls') && el.getAttribute('role') !== 'button' && el.tagName !== 'BUTTON') continue;
    if (DENY.test((el.innerText || '') + ' ' + (el.getAttribute('aria-label') || ''))) continue;
    if (el.getAttribute('aria-haspopup')) continue; // menus/dialogs cover the screen; keep the base state
    const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) continue;
    el.click(); n++;
    if (n >= 25) break;
  }
  return n;
})()`;

async function setViewport(tab, vp) {
  await tab.send('Emulation.setDeviceMetricsOverride', { width: vp.width, height: vp.height, deviceScaleFactor: vp.dsf, mobile: vp.mobile });
  await tab.send('Emulation.setTouchEmulationEnabled', { enabled: vp.mobile, maxTouchPoints: vp.mobile ? 5 : 1 });
  if (vp.mobile) await tab.send('Emulation.setUserAgentOverride', { userAgent: MOBILE_UA, platform: 'iPhone' });
  else await tab.send('Emulation.setUserAgentOverride', { userAgent: '' }).catch(() => {});
}

async function shoot(tab, path, clip) {
  const params = { format: 'png', captureBeyondViewport: true };
  if (clip) params.clip = { ...clip, scale: 1 };
  const r = await tab.send('Page.captureScreenshot', params, 45000);
  if (!r?.data) throw new Error('Page.captureScreenshot returned no data');
  writeFileSync(path, Buffer.from(r.data, 'base64'));
  return path;
}

// Tiles are captured by SCROLLING to the offset and shooting the real viewport - never with
// captureBeyondViewport. A site with scroll-reveal animations (opacity/transform driven by an
// IntersectionObserver) paints everything below the fold at opacity 0 under captureBeyondViewport,
// which silently blinds the vision half of the pass. Scrolling makes the reveal actually fire.
async function shootViewport(tab, path, y) {
  await tab.evaluate(`window.scrollTo(0, ${Number(y)}); null`);
  await sleep(650); // let reveal transitions settle
  const r = await tab.send('Page.captureScreenshot', { format: 'png' }, 45000);
  if (!r?.data) throw new Error('Page.captureScreenshot returned no data');
  writeFileSync(path, Buffer.from(r.data, 'base64'));
  return path;
}

function mergeCensus(scans) {
  const kinds = ['phones', 'dates', 'times', 'money'];
  const out = { formats: {}, buttonVariants: [], machineTextByKind: {}, crossScreenInconsistencies: [] };
  for (const k of kinds) {
    const styles = {};
    for (const s of scans) {
      for (const [style, v] of Object.entries(s.scan.formatCensus?.[k]?.styles || {})) {
        const slot = styles[style] || (styles[style] = { count: 0, routes: [], samples: [] });
        slot.count += v.count;
        if (!slot.routes.includes(s.route)) slot.routes.push(s.route);
        for (const smp of v.samples) if (slot.samples.length < 6) slot.samples.push({ route: s.route, ...smp });
      }
    }
    out.formats[k] = { distinctStyles: Object.keys(styles).length, styles };
    // relative + absolute dates legitimately coexist; every other mix of styles for one datum is a finding candidate
    const meaningful = Object.keys(styles).filter((st) => !(k === 'dates' && st === 'relative'));
    if (meaningful.length > 1) {
      out.crossScreenInconsistencies.push({ datum: k, styles: meaningful, routes: [...new Set(meaningful.flatMap((st) => styles[st].routes))], dominantStyle: meaningful.sort((a, b) => styles[b].count - styles[a].count)[0] });
    }
  }
  const sigs = new Map();
  for (const s of scans) {
    for (const v of s.scan.buttonVariants || []) {
      const e = sigs.get(v.signature) || { signature: v.signature, count: 0, routes: [], samples: [] };
      e.count += v.count;
      if (!e.routes.includes(s.route)) e.routes.push(s.route);
      for (const smp of v.samples) if (e.samples.length < 6) e.samples.push({ route: s.route, ...smp });
      sigs.set(v.signature, e);
    }
    for (const m of s.scan.machineText || []) {
      const e = out.machineTextByKind[m.kind] || (out.machineTextByKind[m.kind] = { count: 0, routes: [] });
      e.count++; if (!e.routes.includes(s.route)) e.routes.push(s.route);
    }
  }
  out.buttonVariants = [...sigs.values()].sort((a, b) => b.count - a.count);
  // Same label, different look, across screens = the strongest machine signal for "two styles for one role".
  const byLabel = new Map();
  for (const v of out.buttonVariants) for (const smp of v.samples) {
    const key = (smp.label || '').toLowerCase(); if (!key) continue;
    const set = byLabel.get(key) || new Set(); set.add(v.signature); byLabel.set(key, set);
  }
  for (const [label, set] of byLabel) if (set.size > 1) out.crossScreenInconsistencies.push({ datum: 'button-variant', label, signatures: [...set] });
  return out;
}

async function main() {
  mkdirSync(join(OUT, 'quality'), { recursive: true });
  mkdirSync(join(OUT, 'screenshots'), { recursive: true });
  const netLog = join(OUT, 'quality-network.log');
  writeFileSync(netLog, '');

  const base = new URL(args.base);
  const tab = await openTab('about:blank', { port: args.port });
  const manifest = { schema: 'ui-audit.quality-manifest/1', base: base.href, startedAt: new Date().toISOString(), viewports: VIEWPORTS, mode: { expand: args.expand, wireGuard: args.readOnly || args.expand }, routes: [], errors: [] };
  try {
    await tab.send('Page.enable'); await tab.send('Runtime.enable');
    if (args.readOnly || args.expand) await installReadOnlyGuard(tab, (r) => appendFileSync(netLog, `BLOCKED ${r.method} ${r.url}\n`));
    else await installMutationLogger(tab, (r) => appendFileSync(netLog, `FIRED ${r.method} ${r.url}\n`));
    // Never let a page dialog (alert/confirm/beforeunload) wedge the run.
    tab.on('Page.javascriptDialogOpening', () => { tab.send('Page.handleJavaScriptDialog', { accept: false }).catch(() => {}); });

    // ---- resolve the route list
    let routes = [];
    if (args.routes) {
      routes = args.routes.split(',').map((s) => s.trim()).filter(Boolean).map((r) => new URL(r, base).href);
    } else {
      await setViewport(tab, VIEWPORTS[0]);
      await tab.navigate(base.href);
      const found = await tab.evaluate(CRAWL_EXPR);
      const seen = new Set(); routes = [base.href]; seen.add(base.pathname.replace(/\/$/, '') || '/');
      for (const l of [...found.nav, ...found.rest]) {
        let u; try { u = new URL(l.href); } catch { continue; }
        if (!/^https?:$/.test(u.protocol) || u.origin !== base.origin || SKIP_HREF.test(u.pathname + u.search)) continue;
        const key = u.pathname.replace(/\/$/, '') || '/';
        if (seen.has(key)) continue;
        seen.add(key); routes.push(u.origin + u.pathname + u.search);
        if (routes.length >= args.maxRoutes) break;
      }
      manifest.crawled = true;
    }
    routes = routes.slice(0, args.maxRoutes);
    console.log(`quality-drive: ${routes.length} route(s) x ${VIEWPORTS.length} viewport(s)`);

    // ---- scan each route at each viewport
    const scans = [];
    for (const vp of VIEWPORTS) {
      await setViewport(tab, vp);
      for (const route of routes) {
        const slug = slugOf(route);
        const rec = { route, slug, viewport: vp.name };
        try {
          await tab.navigate(route);
          rec.scrollSteps = await tab.evaluate(SCROLL_PASS_EXPR, 40000);
          const landed = await tab.evaluate('location.href');
          rec.landedUrl = landed;
          const lp = new URL(landed);
          if (lp.pathname !== new URL(route).pathname && /(log-?in|sign-?in|auth|sso)/i.test(lp.pathname + lp.hostname)) {
            rec.authRedirect = true;
            console.log(`  AUTH REDIRECT ${route} -> ${landed} (sign into ${base.origin} in the :9222 profile, then re-run)`);
          }
          rec.detailsOpened = await tab.evaluate(OPEN_DETAILS_EXPR);
          if (args.expand) { rec.togglesClicked = await tab.evaluate(EXPAND_EXPR); await sleep(500); }
          const scan = await tab.evaluate(SCAN_SRC, 30000);
          if (!scan || scan.schema !== 'ui-audit.quality-scan/1') throw new Error('quality-scan.js returned an unexpected value');
          const scanPath = join(OUT, 'quality', `${slug}.${vp.name}.scan.json`);
          writeFileSync(scanPath, JSON.stringify(scan, null, 2));
          rec.scan = scanPath; rec.summary = scan.summary;

          const full = join(OUT, 'screenshots', `${slug}.${vp.name}.png`);
          const pageH = Math.min(scan.document.scrollHeight, 16000); // Chrome's capture ceiling; taller pages are tiled only
          await shoot(tab, full, { x: 0, y: 0, width: vp.width, height: pageH });
          rec.screenshot = full; rec.tiles = [];
          const tileCount = Math.min(args.maxTiles, Math.ceil(scan.document.scrollHeight / vp.height));
          if (tileCount > 1) {
            for (let i = 0; i < tileCount; i++) {
              const y = i * vp.height;
              const p = join(OUT, 'screenshots', `${slug}.${vp.name}.tile-${i + 1}.png`);
              await shootViewport(tab, p, y);
              rec.tiles.push({ path: p, pageY: y });
            }
            if (Math.ceil(scan.document.scrollHeight / vp.height) > tileCount) rec.tilesTruncatedAt = tileCount;
            await tab.evaluate('window.scrollTo(0, 0); null');
          }
          scans.push({ route, viewport: vp.name, scan });
          console.log(`  OK ${vp.name} ${route} -> machineText=${scan.summary.machineText} smallTap=${scan.summary.smallTapTargets} headerFlags=${scan.summary.headerFlags} lowContrast=${scan.summary.lowContrast}`);
        } catch (e) {
          rec.error = String(e.message || e);
          manifest.errors.push({ route, viewport: vp.name, error: rec.error });
          console.log(`  FAIL ${vp.name} ${route}: ${rec.error}`);
        }
        manifest.routes.push(rec);
      }
    }

    // Cross-screen census is computed on the mobile pass (the primary target) to avoid double counting.
    const primary = scans.filter((s) => s.viewport === VIEWPORTS[0].name);
    writeFileSync(join(OUT, 'quality', 'census.json'), JSON.stringify(mergeCensus(primary), null, 2));
    manifest.finishedAt = new Date().toISOString();
    writeFileSync(join(OUT, 'quality', 'manifest.json'), JSON.stringify(manifest, null, 2));
    console.log(`quality-drive: wrote ${scans.length} scan(s) -> ${join(OUT, 'quality')}`);
    if (!scans.length) process.exitCode = 1;
  } finally {
    try { await tab.send('Fetch.disable'); } catch {}
    await tab.close();
  }
}

main().catch((e) => {
  console.error(e.infra || e instanceof InfraError ? `INFRA: ${e.message}` : `quality-drive failed: ${e.stack || e}`);
  process.exit(e.infra ? 3 : 1);
});
