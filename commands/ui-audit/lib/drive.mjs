#!/usr/bin/env node
// drive.mjs — the /ui-audit Phase-1/2 browser driver, over RAW CDP (zero deps).
//
// Run:  node drive.mjs --url <URL> --out <DIR> [--read-only] [--max-enum-passes N] [--port N]
//
// What it does:
//   1. Connects to the :9222 debug Chrome via cdp.mjs and opens a fresh tab (inherits the session).
//   2. Navigates to --url; if redirected to /login it exits 3 (INFRASTRUCTURE — sign in first).
//   3. STATEFUL worklist traversal to exhaustion:
//        - records the ordered selector-chain (descriptors) to reach each discovered state;
//        - cycle-guards on a STRUCTURAL statePath (route + selector/type/path signature, TEXT
//          EXCLUDED) so re-entering a live-data modal is idempotent;
//        - goToState = FULL nav reset + descriptor replay (esc-and-back is unreliable);
//        - "new state" = body-subtree insertion OR route change OR element-count delta;
//        - --max-enum-passes is a SAFETY cap → still-unexplored states are recorded as UNVERIFIED
//          ledger rows (bounded incompleteness surfaces as findings, never silence).
//   4. Per state: paged-enumerates the whole surface → ledger.json (unique keys, verdict:null) with
//      an INDEPENDENT per-state visible-node count for the fail-closed cross-check; captures
//      network-on-mount + response bodies → evidence/<id>.json for each data element (empty
//      network-on-mount ⇒ hardcoded signal); Page.captureScreenshot → screenshots/<state>.png.
//   5. In --read-only, installs the WIRE-level Fetch abort BEFORE any interaction and logs every
//      blocked non-GET to traversal-actions.log. In full mode, logs every non-GET that FIRES.
//
// All outputs land under --out (which must be inside the repo so Codex's `-s read-only --cd` sandbox
// can read the evidence bundles). Emits crisp JSON + a one-line summary. Exit: 0 ok · 3 infra.

import { mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import {
  openTab, InfraError, normalizeValue,
  installNetworkCapture, installReadOnlyGuard, installMutationLogger, screenshot,
} from './cdp.mjs';
import enumerate from './enumerate.js';

// ------------------------------- arg parsing -------------------------------
function parseArgs(argv) {
  const a = { url: '', out: '', readOnly: false, maxEnumPasses: 6, port: undefined, probeCap: 30 };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    const next = () => argv[++i];
    if (t === '--url') a.url = next();
    else if (t.startsWith('--url=')) a.url = t.slice(6);
    else if (t === '--out') a.out = next();
    else if (t.startsWith('--out=')) a.out = t.slice(6);
    else if (t === '--read-only') a.readOnly = true;
    else if (t === '--max-enum-passes') a.maxEnumPasses = Number(next());
    else if (t.startsWith('--max-enum-passes=')) a.maxEnumPasses = Number(t.split('=')[1]);
    else if (t === '--port') a.port = Number(next());
    else if (t.startsWith('--port=')) a.port = Number(t.split('=')[1]);
    else if (t === '--probe-cap') a.probeCap = Number(next());
    else if (t.startsWith('--probe-cap=')) a.probeCap = Number(t.split('=')[1]);
  }
  return a;
}

const args = parseArgs(process.argv.slice(2));
if (!args.url || !args.out) {
  console.error('usage: node drive.mjs --url <URL> --out <DIR> [--read-only] [--max-enum-passes N] [--port N]');
  process.exit(2);
}

const OUT = args.out;
const NS = '__uiAudit';
const DENY = /^(Delete|Remove|Cancel|Break|Submit|Approve|Reject|Send|Finalize|Destroy)\b/i;
const sh = (s) => createHash('sha256').update(String(s)).digest('hex').slice(0, 16);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Extract candidate value TOKENS from a response body for EXACT provenance matching (not substring).
// Substring matching false-positives constantly: displayed "$85" → normalized "85" is a substring of
// id:2850, 1985, epoch timestamps, etc. We instead pull JSON string values + numeric literals, normalize
// each, and mark provenance 'api' ONLY on exact Set membership. Returns a Set of normalized tokens.
function valueTokens(body) {
  const set = new Set();
  if (!body || typeof body !== 'string') return set;
  // JSON string literals ("...") OR numeric literals (handles $, %, commas via normalizeValue after).
  const re = /"(?:[^"\\]|\\.)*"|-?\d[\d.,]*/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    let raw = m[0];
    if (raw.charCodeAt(0) === 34 /* " */) raw = raw.slice(1, -1); // strip surrounding quotes
    const t = normalizeValue(raw);
    if (t) set.add(t);
  }
  return set;
}

mkdirSync(OUT, { recursive: true });
mkdirSync(join(OUT, 'evidence'), { recursive: true });
mkdirSync(join(OUT, 'screenshots'), { recursive: true });
const ACTIONS_LOG = join(OUT, 'traversal-actions.log');
writeFileSync(ACTIONS_LOG, `# traversal-actions.log — non-GET requests observed (${args.readOnly ? 'read-only: BLOCKED at wire' : 'full: FIRED'})\n`);
const logAction = (kind, rec) => appendFileSync(ACTIONS_LOG, `${new Date().toISOString()} ${kind} ${rec.method} ${rec.url}\n`);

// ------------------------------- in-page helpers (serialized + injected) -------------------------------
// Structural signature (TEXT EXCLUDED) — the cycle-guard key + new-state detector.
function __structuralSig() {
  function domPath(el) {
    const p = []; let n = el;
    while (n && n.nodeType === 1 && n !== document.body) {
      let i = 1, s = n; while (s.previousElementSibling) { s = s.previousElementSibling; i++; }
      p.unshift(n.tagName.toLowerCase() + ':' + i); n = n.parentElement;
    }
    return p.join('>');
  }
  const parts = []; let count = 0;
  for (const el of document.querySelectorAll('*')) {
    const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
    if (!(r.width > 0 && r.height > 0) || cs.visibility === 'hidden' || cs.display === 'none') continue;
    count++;
    if (el.matches && el.matches('main,section,nav,header,footer,aside,form,table,ul,ol,[role=dialog],[role=grid],[role=tabpanel],[aria-modal=true]')) {
      parts.push(el.tagName.toLowerCase() + ':' + (el.getAttribute('role') || '') + ':' + domPath(el));
    }
  }
  return { signature: parts.join('|'), count, route: location.pathname + location.hash };
}

// Interactive candidate descriptors (for building replay chains).
function __collectDescriptors() {
  function domPath(el) {
    const p = []; let n = el;
    while (n && n.nodeType === 1 && n !== document.body) {
      let i = 1, s = n; while (s.previousElementSibling) { s = s.previousElementSibling; i++; }
      p.unshift(n.tagName.toLowerCase() + ':' + i); n = n.parentElement;
    }
    return p.join('>');
  }
  const DENY = /^(Delete|Remove|Cancel|Break|Submit|Approve|Reject|Send|Finalize|Destroy)\b/i;
  const out = [];
  for (const el of document.querySelectorAll('button,[role=button],a[href],[onclick],[tabindex]')) {
    const r = el.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) continue;
    const text = (el.innerText || '').trim().slice(0, 80);
    const aria = el.getAttribute('aria-label') || '';
    out.push({
      text, aria,
      testId: el.getAttribute('data-testid') || el.getAttribute('data-test') || '',
      tag: el.tagName.toLowerCase(),
      domPath: domPath(el),
      destructive: DENY.test(text) || DENY.test(aria),
    });
  }
  return out;
}

// Resolve a recorded descriptor after a full nav reset and click it (in-page).
function __clickDescriptor(d) {
  const norm = (s) => (s || '').trim();
  const cands = [...document.querySelectorAll('button,[role=button],a[href],[onclick],[tabindex]')];
  const el = cands.find((b) =>
    (d.testId && (b.getAttribute('data-testid') === d.testId || b.getAttribute('data-test') === d.testId)) ||
    (d.aria && b.getAttribute('aria-label') === d.aria) ||
    (d.text && norm(b.innerText) === d.text));
  if (!el) return { found: false };
  try { el.scrollIntoView({ block: 'center' }); } catch {}
  el.click();
  return { found: true };
}

const sigExpr = `(${__structuralSig.toString()})()`;
const descriptorsExpr = `(${__collectDescriptors.toString()})()`;
const clickExpr = (d) => `(${__clickDescriptor.toString()})(${JSON.stringify(d)})`;

// ------------------------------- main -------------------------------
let tab;
const started = Date.now();
try {
  tab = await openTab(args.url, { port: args.port });

  // Read-only guard MUST be installed BEFORE any navigation/interaction (fail-closed at the wire).
  let guard = null, mutationLog = null;
  if (args.readOnly) {
    guard = await installReadOnlyGuard(tab, (rec) => logAction('BLOCKED', rec));
  } else {
    mutationLog = await installMutationLogger(tab, (rec) => logAction('FIRED', rec));
  }
  // Capture XHR/Fetch (+ json) responses regardless of URL — stack-agnostic (no dentall host/path regex).
  const capture = await installNetworkCapture(tab);

  const goToState = async (chain) => {
    capture.reset();
    await tab.navigate(args.url);
    for (const d of chain) {
      await tab.evaluate(clickExpr(d), 15000).catch(() => ({}));
      await sleep(900);
    }
  };
  const atLogin = async () => /\/login(\b|\/|$)/.test(await tab.evaluate('location.pathname'));

  // Prime: land on the URL once and bail early if the session isn't signed in.
  await tab.navigate(args.url);
  if (await atLogin()) {
    console.error(`INFRASTRUCTURE FAIL: ${args.url} redirected to /login — sign into the :9222 debug profile, then re-run`);
    process.exit(3);
  }

  const visited = new Set();
  const queue = [{ chain: [], id: 's0', parentId: null }];
  const states = [];
  const elements = [];
  let passes = 0;
  let dataElements = 0;

  while (queue.length) {
    const st = queue.shift();

    // Safety cap tripped: record every still-queued state as an UNVERIFIED ledger row (surfaced, not silent).
    if (passes >= args.maxEnumPasses) {
      const sid = 'unexplored-' + sh(st.chain.map((c) => c.testId || c.aria || c.text).join('>'));
      elements.push({
        key: sh(sid), stateId: sid, statePath: sid, domPath: '(unexplored)', tag: '', type: 'region',
        text: `UNVERIFIED — state left unexplored when --max-enum-passes=${args.maxEnumPasses} tripped`,
        interactive: false, box: null, attrs: {}, dataLocator: '',
        chain: st.chain.map((c) => c.testId || c.aria || c.text),
        verdict: 'UNVERIFIED',
      });
      states.push({ id: sid, statePath: sid, route: '(unexplored)', ledgerCount: 1, independentVisibleCount: 1, screenshot: null, status: 'UNVERIFIED' });
      continue;
    }

    await goToState(st.chain);
    if (await atLogin()) {
      console.error('INFRASTRUCTURE FAIL: session dropped to /login mid-traversal — re-auth the :9222 profile');
      process.exit(3);
    }

    const sig = await tab.evaluate(sigExpr, 20000);
    const statePath = sh(sig.route + '::' + sig.signature);
    if (visited.has(statePath)) continue;
    visited.add(statePath);
    passes++;
    const stateId = st.id === 's0' ? 's0' : 'st-' + statePath;

    // Enumerate the whole surface → paged records.
    const reported = await tab.evaluate(enumerate.setupExpr(NS), 25000);
    const records = [];
    for (let off = 0; off < reported; off += enumerate.PAGE_SIZE) {
      const chunk = await tab.evaluate(enumerate.pageExpr(NS, off, enumerate.PAGE_SIZE), 15000);
      for (const r of JSON.parse(chunk)) records.push(r);
    }
    // INDEPENDENT visible-node count (separate pass) for the fail-closed cross-check.
    const independentVisibleCount = await tab.evaluate(enumerate.visibleCountExpr(), 20000);

    // network-on-mount bodies for this state (provenance source).
    await sleep(600);
    const bodies = await capture.bodies(60);

    // screenshot
    const shotPath = join(OUT, 'screenshots', `${stateId}.png`);
    try { await screenshot(tab, shotPath); } catch (e) { /* screenshot best-effort */ }

    // rekey + attach state; write evidence for data elements (provenance oracle).
    for (const rec of records) {
      rec.statePath = statePath;
      rec.stateId = stateId;
      rec.key = sh(statePath + '|' + rec.domPath);
      elements.push(rec);

      if (['stat', 'chart', 'table', 'badge'].includes(rec.type) && rec.text) {
        dataElements++;
        const nv = normalizeValue(rec.text);
        let provenance = 'empty';
        let matchedUrl = null;
        let matchMode = 'no-value';
        if (nv) {
          if (nv.length < 2) {
            // Trivially-short values (single digit/char) collide with far too much to be evidence of
            // either verdict — they drive NEITHER 'api' nor 'no-network-origin'.
            provenance = 'ambiguous';
            matchMode = 'ambiguous-short';
          } else {
            // EXACT token-set membership (not substring): normalize each JSON string/number token in
            // the body and require nv to be a member. Cache the token Set per body.
            matchMode = 'token-exact';
            const hit = bodies.find((b) =>
              b.body && (b.__tokens || (b.__tokens = valueTokens(b.body))).has(nv));
            provenance = hit ? 'api' : 'no-network-origin';
            matchedUrl = hit ? hit.url : null;
          }
        }
        // empty network-on-mount for a data element ⇒ hardcoded signal (the canonical hardcoded-$85 catch).
        // 'ambiguous' never drives the hardcoded signal.
        const hardcodedSignal = provenance !== 'ambiguous' && (bodies.length === 0 || provenance === 'no-network-origin');
        const id = sh(rec.key);
        writeFileSync(join(OUT, 'evidence', `${id}.json`), JSON.stringify({
          id, key: rec.key, stateId, statePath, type: rec.type, text: rec.text,
          dataLocator: rec.dataLocator, box: rec.box,
          provenance, matchedUrl, matchMode, hardcodedSignal,
          networkOnMount: bodies.map((b) => ({ url: b.url, status: b.status })),
          screenshot: `screenshots/${stateId}.png`,
        }, null, 2));
      }
    }

    states.push({
      id: stateId, statePath, route: sig.route,
      chain: st.chain.map((c) => c.testId || c.aria || c.text),
      ledgerCount: records.length,
      independentVisibleCount,
      screenshot: `screenshots/${stateId}.png`,
      status: 'ENUMERATED',
    });

    // Discover child states: probe each interactive candidate from a fresh replay of THIS chain.
    const candidates = await tab.evaluate(descriptorsExpr, 20000);
    let probed = 0;
    for (const cand of candidates) {
      if (probed >= args.probeCap) break;
      if (args.readOnly && cand.destructive) continue; // never click destructive matches in read-only
      probed++;
      await goToState(st.chain);
      const before = await tab.evaluate(sigExpr, 15000);
      await tab.evaluate(clickExpr(cand), 12000).catch(() => ({}));
      await sleep(900);
      const after = await tab.evaluate(sigExpr, 15000);
      const isNew = after.route !== before.route
        || after.signature !== before.signature
        || Math.abs((after.count || 0) - (before.count || 0)) > 3;
      if (isNew) {
        const childPath = sh(after.route + '::' + after.signature);
        if (!visited.has(childPath)) {
          queue.push({ chain: [...st.chain, cand], id: 'st-' + childPath, parentId: stateId });
        }
      }
    }
  }

  const summary = {
    url: args.url,
    out: OUT,
    readOnly: args.readOnly,
    generatedAt: new Date().toISOString(),
    durationMs: Date.now() - started,
    stateCount: states.length,
    elementCount: elements.length,
    dataElementCount: dataElements,
    enumeratedPasses: passes,
    maxEnumPasses: args.maxEnumPasses,
    nonGetBlocked: guard ? guard.blockedNonGet : 0,
    nonGetFired: mutationLog ? mutationLog.fired.length : 0,
  };

  writeFileSync(join(OUT, 'ledger.json'), JSON.stringify({ ...summary, states, elements }, null, 2));
  writeFileSync(join(OUT, 'drive-summary.json'), JSON.stringify(summary, null, 2));

  console.log(JSON.stringify(summary));
  console.log(`SUMMARY: ${states.length} states · ${elements.length} elements (${dataElements} data) · ` +
    `${args.readOnly ? guard.blockedNonGet + ' non-GET blocked' : (mutationLog.fired.length + ' non-GET fired')} · ` +
    `${passes}/${args.maxEnumPasses} passes → ${OUT}/ledger.json`);
} catch (e) {
  if (e instanceof InfraError) { console.error('INFRASTRUCTURE FAIL:', e.message); process.exit(3); }
  throw e;
} finally {
  if (tab) { try { await tab.send('Fetch.disable'); } catch {} await tab.close(); }
}
