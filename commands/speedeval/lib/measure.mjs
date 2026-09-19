#!/usr/bin/env node
// measure.mjs - the /speedeval driver: click everything, time everything, attribute the time.
//
// Run:  node measure.mjs --url <URL> [--base <B> --routes /a,/b] --out <DIR>
//         [--read-only] [--include-destructive] [--runs N] [--cold] [--no-clicks]
//         [--max-routes N] [--max-actions N] [--deny <regex>] [--port N]
//
// Transport: RAW CDP through ui-audit's zero-dependency client (../../ui-audit/lib/cdp.mjs). This
// file adds NO second CDP client - it only layers measurement on openTab()'s send/on.
//
// What it does:
//   1. Opens ONE fresh tab on the :9222 debug Chrome (inherits the logged-in session) and closes
//      it (plus any popup that tab spawned) on exit. It never attaches to a pre-existing tab.
//   2. Per ROUTE, N navigations (default 3): TTFB, responseEnd, DCL, load, FCP, LCP, requests,
//      bytes, slowest 5 requests with dns/connect/ssl/send/wait/receive, and the document
//      request's `wait` (= server + DB time). First hit vs median of later hits => cold vs warm.
//   3. Per CLICK (fresh navigation before each one, so every click starts from the same state):
//      t0 at pointerdown (page clock), time to first request, main response (server wait vs
//      download), DOM settle (mutations quiet 300ms + no inflight), first visible feedback
//      (the "feels dead" metric, 100ms bar), soft/hard nav detection, functional verdict.
//   4. Classifies every route + action into a DOMINANT LAYER (classify.mjs) and writes
//      report.json + REPORT.md (report.mjs) under --out.
//
// Safety: --read-only installs ui-audit's WIRE-level guard (Fetch domain aborts every non-GET).
// Without it, elements whose label/href match the destructive denylist, form submits, state
// toggles and unlabeled icon buttons are SKIPPED (logged, never clicked), and every non-GET that
// does fire is recorded. Sign-in / sign-out / account controls are never clicked in any mode.
//
// Exit: 0 ok - 2 usage - 3 infrastructure (debug Chrome unreachable).

import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { openTab, assertEndpoint, InfraError, installReadOnlyGuard, installMutationLogger } from '../../ui-audit/lib/cdp.mjs';
import { classifyRoute, classifyAction, buildRanking, buildHypotheses, sequentialDepth, median, THRESHOLDS } from './classify.mjs';
import { renderMarkdown } from './report.mjs';

const require = createRequire(import.meta.url);
const INPAGE = require('./inpage.js').source;

export const SCHEMA_VERSION = '1.0';

// ------------------------------- args -------------------------------
function parseArgs(argv) {
  const a = { url: '', base: '', routes: [], out: '', readOnly: false, includeDestructive: false, runs: 3, cold: false, clicks: true, maxRoutes: 10, maxActions: 15, deny: '', port: 9222, settleTimeoutMs: 10000 };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    const [k, inline] = t.startsWith('--') && t.includes('=') ? [t.slice(0, t.indexOf('=')), t.slice(t.indexOf('=') + 1)] : [t, undefined];
    const val = () => (inline !== undefined ? inline : argv[++i]);
    if (k === '--url') a.url = val();
    else if (k === '--base') a.base = val();
    else if (k === '--routes') a.routes = String(val()).split(',').map((s) => s.trim()).filter(Boolean);
    else if (k === '--out') a.out = val();
    else if (k === '--read-only') a.readOnly = true;
    else if (k === '--include-destructive') a.includeDestructive = true;
    else if (k === '--runs') a.runs = Number(val());
    else if (k === '--cold') a.cold = true;
    else if (k === '--no-clicks') a.clicks = false;
    else if (k === '--max-routes') a.maxRoutes = Number(val());
    else if (k === '--max-actions') a.maxActions = Number(val());
    else if (k === '--deny') a.deny = val();
    else if (k === '--port') a.port = Number(val());
    else if (k === '--settle-timeout') a.settleTimeoutMs = Number(val());
    else if (!k.startsWith('--') && !a.url) a.url = k;
    else { console.error(`unknown argument: ${t}`); process.exit(2); }
  }
  return a;
}

const args = parseArgs(process.argv.slice(2));
if (!args.url && args.base) args.url = args.base;
if (!args.url || !args.out || !(args.runs >= 1)) {
  console.error('usage: node measure.mjs --url <URL> --out <DIR> [--base <B>] [--routes /a,/b] [--read-only] [--include-destructive] [--runs N] [--cold] [--no-clicks] [--max-routes N] [--max-actions N] [--deny <regex>] [--port N]');
  process.exit(2);
}
if (args.includeDestructive && !args.readOnly) { console.error('--include-destructive is only allowed together with --read-only'); process.exit(2); }
if (!/^https?:\/\//.test(args.url)) args.url = 'http://' + args.url;
const ORIGIN = new URL(args.base || args.url).origin;
const OUT = resolve(args.out);
mkdirSync(OUT, { recursive: true });

// Never clicked / never crawled, in ANY mode: session + account + auth-flow controls.
const ALWAYS_SKIP = /\b(log[ -]?out|sign[ -]?out|log[ -]?in|sign[ -]?in|sign[ -]?up|register|continue with|delete (my )?account|close account|deactivate|revoke|disconnect|unlink)\b/i;
// Skipped unless --read-only --include-destructive. Word-boundary, anywhere in the label.
const DENY = new RegExp(args.deny || String.raw`\b(delete|remove|destroy|erase|discard|clear all|send|resend|cancel|confirm|pay|purchase|buy|checkout|charge|refund|submit|approve|reject|decline|accept|archive|publish|unpublish|block|ban|reset|book|reschedule|void|unsubscribe|invite|save|apply|merge|transfer)\b`, 'i');
const DENY_HREF = /\/(log-?out|sign-?out|signout|logout|delete|remove|destroy|unsubscribe|revoke|api)(\/|$|\?)/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...m) => console.error('[speedeval]', ...m);
const r1 = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10) / 10 : null);

// Strip secrets from URLs before they reach a report another agent will read.
function redact(u) {
  try {
    const x = new URL(u);
    for (const k of [...x.searchParams.keys()]) if (/token|key|secret|code|pass|sess|sig|auth|jwt/i.test(k)) x.searchParams.set(k, 'REDACTED');
    const s = x.toString();
    return s.length > 300 ? s.slice(0, 300) + '...' : s;
  } catch { return String(u).slice(0, 300); }
}

// Response headers that help attribute time. Deliberately NOT set-cookie / authorization.
const KEEP_HEADERS = ['server-timing', 'cache-control', 'age', 'x-nextjs-cache', 'x-nextjs-prerender', 'x-nextjs-stale-time', 'x-nf-request-id', 'cache-status', 'netlify-cdn-cache-control', 'cdn-cache-control', 'cf-cache-status', 'cf-ray', 'x-vercel-cache', 'x-vercel-id', 'x-cache', 'x-served-by', 'via', 'server', 'x-powered-by', 'content-encoding', 'content-length', 'content-type', 'etag', 'vary'];
function pickHeaders(h) {
  const low = {}; for (const [k, v] of Object.entries(h || {})) low[k.toLowerCase()] = String(v);
  const out = {}; for (const k of KEEP_HEADERS) if (low[k] !== undefined) out[k] = low[k].slice(0, 400);
  return out;
}

// ------------------------------- network log -------------------------------
function createNetLog(tab) {
  const byId = new Map();
  const list = [];
  tab.on('Network.requestWillBeSent', (p) => {
    const url = p.request?.url || '';
    if (/^(data|blob|chrome-extension|chrome|about):/.test(url)) return;
    const prev = byId.get(p.requestId);
    if (prev && p.redirectResponse) {
      prev.status = p.redirectResponse.status; prev.timing = p.redirectResponse.timing || null;
      prev.headers = pickHeaders(p.redirectResponse.headers); prev.endTs = p.timestamp; prev.done = true; prev.redirectedTo = url;
    }
    const rh = {}; for (const [k, v] of Object.entries(p.request?.headers || {})) rh[k.toLowerCase()] = String(v);
    const r = {
      id: p.requestId, url, method: (p.request?.method || 'GET').toUpperCase(), type: p.type || 'Other',
      frameId: p.frameId, initiator: p.initiator?.type || '', startTs: p.timestamp, wallMs: p.wallTime * 1000,
      isServerAction: !!rh['next-action'], isRsc: rh['rsc'] === '1' || /[?&]_rsc=/.test(url),
      isPrefetch: !!rh['next-router-prefetch'] || /prefetch/i.test(rh['purpose'] || '') || /prefetch/i.test(rh['sec-purpose'] || ''),
      status: null, timing: null, headers: {}, protocol: '', fromCache: false, fromSW: false, bytes: 0, endTs: null, failed: null, done: false,
    };
    byId.set(p.requestId, r); list.push(r);
  });
  tab.on('Network.requestServedFromCache', (p) => { const r = byId.get(p.requestId); if (r) r.fromCache = true; });
  tab.on('Network.responseReceived', (p) => {
    const r = byId.get(p.requestId); if (!r) return;
    const s = p.response || {};
    r.status = s.status; r.timing = s.timing || null; r.headers = pickHeaders(s.headers); r.protocol = s.protocol || '';
    r.fromCache = r.fromCache || !!s.fromDiskCache || !!s.fromPrefetchCache; r.fromSW = !!s.fromServiceWorker;
    r.mime = s.mimeType || ''; if (p.type) r.type = p.type;
  });
  tab.on('Network.loadingFinished', (p) => { const r = byId.get(p.requestId); if (r) { r.endTs = p.timestamp; r.bytes = p.encodedDataLength || 0; r.done = true; } });
  tab.on('Network.loadingFailed', (p) => { const r = byId.get(p.requestId); if (r) { r.endTs = p.timestamp; r.failed = p.errorText || 'failed'; r.canceled = !!p.canceled; r.blockedReason = p.blockedReason || ''; r.done = true; } });
  return { mark: () => list.length, since: (i) => list.slice(i) };
}

const epochOf = (r, ts) => r.wallMs + (ts - r.startTs) * 1000;

// CDP ResourceTiming -> exclusive phases in ms. `wait` = request sent -> first response byte.
function phasesOf(r) {
  const t = r.timing;
  if (!t || r.fromCache) return null;
  const span = (a, b) => (a >= 0 && b >= 0 ? Math.max(0, b - a) : 0);
  const ssl = span(t.sslStart, t.sslEnd);
  const firstPhase = [t.dnsStart, t.connectStart, t.sendStart].filter((v) => v >= 0).sort((x, y) => x - y)[0] ?? 0;
  const headersAt = t.receiveHeadersStart > 0 ? t.receiveHeadersStart : t.receiveHeadersEnd;
  const receive = r.endTs !== null ? Math.max(0, (r.endTs - t.requestTime) * 1000 - t.receiveHeadersEnd) : 0;
  return {
    stalled: r1(Math.max(0, (t.requestTime - r.startTs) * 1000) + firstPhase),
    dns: r1(span(t.dnsStart, t.dnsEnd)), connect: r1(Math.max(0, span(t.connectStart, t.connectEnd) - ssl)), ssl: r1(ssl),
    send: r1(span(t.sendStart, t.sendEnd)), wait: r1(Math.max(0, headersAt - t.sendEnd)), receive: r1(receive),
    reusedConnection: t.connectStart < 0,
  };
}

function kindOf(r) {
  if (r.type === 'Document') return 'document';
  if (r.isServerAction) return 'server-action';
  if (r.isPrefetch) return 'prefetch';
  if (r.isRsc) return 'rsc';
  if (r.type === 'XHR' || r.type === 'Fetch') return 'api';
  return String(r.type || 'other').toLowerCase();
}

function summarize(r) {
  const endEpoch = r.endTs !== null ? epochOf(r, r.endTs) : null;
  return {
    url: redact(r.url), method: r.method, type: r.type, kind: kindOf(r), status: r.status, protocol: r.protocol,
    fromCache: r.fromCache, fromServiceWorker: r.fromSW, bytes: r.bytes, failed: r.failed,
    startEpoch: r1(r.wallMs), endEpoch: r1(endEpoch), durationMs: endEpoch !== null ? r1(endEpoch - r.wallMs) : null,
    phases: phasesOf(r), headers: r.headers,
  };
}

const LONG_LIVED = new Set(['EventSource', 'WebSocket']);
const inflight = (reqs) => reqs.filter((r) => !r.done && !LONG_LIVED.has(r.type) && Date.now() - r.wallMs < 5000);

// ------------------------------- session -------------------------------
const ctx = { loadFired: false, mainFrameNav: 0, t0: null, consoleErrors: [], dialogs: [] };
let tab, net, guard = null, mutations = null;

async function setup() {
  const version = await assertEndpoint(args.port);
  tab = await openTab('about:blank', { port: args.port });
  await tab.send('Page.enable'); await tab.send('Runtime.enable'); await tab.send('Network.enable');
  try { await tab.send('Log.enable'); } catch {}
  // Keep the tab rendering (paint metrics, un-throttled timers) WITHOUT stealing the user's screen.
  try { await tab.send('Emulation.setFocusEmulationEnabled', { enabled: true }); } catch {}
  net = createNetLog(tab);
  if (args.readOnly) guard = await installReadOnlyGuard(tab, (rec) => log(`read-only: blocked ${rec.method} ${redact(rec.url)}`));
  else mutations = await installMutationLogger(tab, (rec) => log(`non-GET fired: ${rec.method} ${redact(rec.url)}`));
  if (args.cold) await tab.send('Network.setCacheDisabled', { cacheDisabled: true });

  tab.on('Page.loadEventFired', () => { ctx.loadFired = true; });
  tab.on('Page.frameNavigated', (p) => { if (!p.frame?.parentId) ctx.mainFrameNav++; });
  tab.on('Page.javascriptDialogOpening', (p) => {
    ctx.dialogs.push({ type: p.type, message: String(p.message || '').slice(0, 200) });
    tab.send('Page.handleJavaScriptDialog', { accept: p.type === 'beforeunload' }).catch(() => {});
  });
  tab.on('Runtime.bindingCalled', (p) => { if (p.name === '__seT0' && ctx.t0 === null) ctx.t0 = Number(p.payload); });
  tab.on('Runtime.exceptionThrown', (p) => ctx.consoleErrors.push({ kind: 'exception', text: String(p.exceptionDetails?.exception?.description || p.exceptionDetails?.text || '').slice(0, 300) }));
  tab.on('Runtime.consoleAPICalled', (p) => { if (p.type === 'error') ctx.consoleErrors.push({ kind: 'console.error', text: (p.args || []).map((x) => x.value ?? x.description ?? '').join(' ').slice(0, 300) }); });
  tab.on('Log.entryAdded', (p) => { if (p.entry?.level === 'error') ctx.consoleErrors.push({ kind: 'log', text: String(p.entry.text || '').slice(0, 300), url: redact(p.entry.url || '') }); });

  await tab.send('Runtime.addBinding', { name: '__seT0' });
  await tab.send('Page.addScriptToEvaluateOnNewDocument', { source: INPAGE });
  return version;
}

async function teardown() {
  if (!tab) return;
  try { // close popups spawned by OUR tab only - never anything the user opened
    const t = await tab.send('Target.getTargets', {}, 3000);
    for (const x of t.targetInfos || []) if (x.openerId === tab.targetId) await fetch(`http://127.0.0.1:${args.port}/json/close/${x.targetId}`).catch(() => {});
  } catch {}
  await tab.close();
  tab = null;
}

async function waitFor(pred, timeoutMs, stepMs = 25) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) { if (await pred()) return true; await sleep(stepMs); }
  return false;
}

async function waitNetworkQuiet(mark, quietMs, maxMs) {
  let quietSince = null;
  return waitFor(() => {
    if (inflight(net.since(mark)).length) { quietSince = null; return false; }
    quietSince ??= Date.now();
    return Date.now() - quietSince >= quietMs;
  }, maxMs);
}

const pageEval = (expr, timeoutMs = 5000) => tab.evaluate(`(() => { ${INPAGE}; return ${expr}; })()`, timeoutMs);

async function gotoBlank() {
  ctx.loadFired = false;
  await tab.send('Page.navigate', { url: 'about:blank' });
  await waitFor(() => ctx.loadFired, 3000);
  await sleep(50);
}

// Navigate and wait for load + network quiet. Returns { mark, error }.
async function navigate(url, { quietMs = 500, maxQuietMs = 8000, loadTimeoutMs = 30000 } = {}) {
  await gotoBlank();
  const mark = net.mark();
  ctx.loadFired = false; ctx.consoleErrors = [];
  let error = null;
  try {
    const res = await tab.send('Page.navigate', { url }, loadTimeoutMs);
    if (res.errorText) error = res.errorText;
  } catch (e) { error = e.message; }
  if (!error) {
    if (!(await waitFor(() => ctx.loadFired, loadTimeoutMs))) error = `load event did not fire within ${loadTimeoutMs}ms`;
    await waitNetworkQuiet(mark, quietMs, maxQuietMs);
    await sleep(250); // let loadEventEnd + the final LCP candidate land
  }
  return { mark, error };
}

// ------------------------------- route measurement -------------------------------
async function measureNavigation(url, runIndex) {
  const { mark, error } = await navigate(url);
  const reqsRaw = net.since(mark);
  if (error && !reqsRaw.length) return { run: runIndex + 1, error };
  let st = null;
  try { st = await pageEval('window.__se.navState()'); } catch (e) { return { run: runIndex + 1, error: error || `page state unreadable: ${e.message}` }; }
  const reqs = reqsRaw.map(summarize);
  const docRaw = reqsRaw.filter((r) => r.type === 'Document' && !r.redirectedTo && r.frameId === reqsRaw[0]?.frameId).pop() || reqsRaw.find((r) => r.type === 'Document');
  const doc = docRaw ? summarize(docRaw) : null;
  const nav = st.nav || {};
  const lt = st.longTasks || [];
  const byType = {};
  for (const q of reqs) { const b = (byType[q.type] ||= { count: 0, bytes: 0 }); b.count++; b.bytes += q.bytes || 0; }
  const budget = st.lcp ?? nav.load ?? null;
  const originMs = st.timeOrigin;
  const critical = reqs.filter((q) => budget === null || (q.startEpoch - originMs) < budget);
  return {
    run: runIndex + 1, error: error || null,
    requestedUrl: url, finalUrl: redact(st.href), title: String(st.title || '').slice(0, 120), visibility: st.visibility,
    ttfb: r1(nav.ttfb), responseEnd: r1(nav.responseEnd), domInteractive: r1(nav.domInteractive), dcl: r1(nav.dcl), load: r1(nav.load),
    fcp: r1(st.fcp), lcp: r1(st.lcp), lcpElement: st.lcpEl, cls: r1(st.cls * 1000) / 1000,
    redirectCount: nav.redirectCount ?? 0, redirectMs: r1(nav.redirectMs ?? 0), navigationType: nav.type, protocol: nav.protocol,
    serverTiming: nav.serverTiming || [],
    requests: reqs.length, bytes: reqs.reduce((s, q) => s + (q.bytes || 0), 0), cachedRequests: reqs.filter((q) => q.fromCache).length, byType,
    document: doc,
    serverRequests: reqs.filter((q) => ['rsc', 'server-action', 'api'].includes(q.kind)).sort((a, b) => (b.phases?.wait || 0) - (a.phases?.wait || 0)).slice(0, 5),
    slowestRequests: reqs.filter((q) => q.durationMs !== null).sort((a, b) => b.durationMs - a.durationMs).slice(0, 5),
    sequential: sequentialDepth(critical, { types: ['Document', 'Fetch', 'XHR', 'Script'] }),
    longTasks: lt.map((t) => ({ start: r1(t.start), dur: r1(t.dur) })), longTaskMax: r1(Math.max(0, ...lt.map((t) => t.dur))), tbt: r1(lt.reduce((s, t) => s + Math.max(0, t.dur - 50), 0)),
    domNodes: st.domNodes, viewport: st.viewport,
    httpErrors: reqs.filter((q) => q.status >= 400).map((q) => ({ status: q.status, url: q.url })).slice(0, 10),
    failedRequests: reqs.filter((q) => q.failed).map((q) => ({ error: q.failed, url: q.url })).slice(0, 10),
    consoleErrors: ctx.consoleErrors.slice(0, 10),
  };
}

const METRICS = ['ttfb', 'docWait', 'responseEnd', 'fcp', 'lcp', 'dcl', 'load', 'requests', 'bytes'];
const metricsOf = (run) => ({ ttfb: run.ttfb, docWait: run.document?.phases?.wait ?? null, responseEnd: run.responseEnd, fcp: run.fcp, lcp: run.lcp, dcl: run.dcl, load: run.load, requests: run.requests, bytes: run.bytes });

function aggregateRoute(route) {
  const ok = route.runs.filter((x) => !x.error || x.document);
  route.first = ok[0] ? metricsOf(ok[0]) : null;
  const warm = ok.slice(1).map(metricsOf);
  route.warmMedian = warm.length ? Object.fromEntries(METRICS.map((m) => [m, r1(median(warm.map((w) => w[m])))])) : null;
  route.coldPenaltyMs = route.first && route.warmMedian ? Object.fromEntries(['ttfb', 'docWait', 'fcp', 'lcp', 'load'].map((m) => [m, route.first[m] !== null && route.warmMedian[m] !== null ? r1(route.first[m] - route.warmMedian[m]) : null])) : null;
  route.finalUrl = ok[0]?.finalUrl || null;
  try {
    const f = new URL(route.finalUrl), q = new URL(route.url);
    route.redirected = f.pathname !== q.pathname || f.origin !== q.origin;
    route.redirectedToLogin = route.redirected && /(log-?in|sign-?in|auth|sso)/i.test(f.pathname + f.hostname);
  } catch { route.redirected = false; route.redirectedToLogin = false; }
  Object.assign(route, classifyRoute(route));
}

// ------------------------------- route discovery -------------------------------
const idLike = (seg) => /^\d+$/.test(seg) || /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(seg) || (/^[A-Za-z0-9_-]{16,}$/.test(seg) && /\d/.test(seg));
async function discoverRoutes(startUrl, known) {
  let links = [];
  try { links = await pageEval('window.__se.links()'); } catch { return []; }
  const seen = new Set(known.map((u) => patternOf(u)));
  const out = [];
  for (const l of links) {
    let u; try { u = new URL(l.href); } catch { continue; }
    if (u.origin !== ORIGIN || !/^https?:$/.test(u.protocol) || l.download || l.target === '_blank') continue;
    if (DENY_HREF.test(u.pathname) || ALWAYS_SKIP.test(l.label) || ALWAYS_SKIP.test(u.pathname.replace(/[/_-]/g, ' '))) continue;
    if (/\.(pdf|png|jpe?g|gif|svg|webp|zip|xml|json|txt|ics|csv|mp4|webm)$/i.test(u.pathname)) continue;
    u.hash = ''; u.search = '';
    const pat = patternOf(u.toString());
    if (seen.has(pat)) continue;
    seen.add(pat); out.push(u.toString());
    if (out.length + known.length >= args.maxRoutes) break;
  }
  return out;
}
function patternOf(u) { try { return new URL(u).pathname.split('/').map((s) => (idLike(s) ? ':id' : s)).join('/').replace(/\/$/, '') || '/'; } catch { return u; } }

// ------------------------------- click candidates -------------------------------
function triage(c, routeUrl) {
  let kind = 'button';
  const toggle = ['switch', 'checkbox', 'radio'].includes(c.role) || ['checkbox', 'radio'].includes(c.type);
  if (c.tag === 'a' || c.role === 'link') kind = 'nav-link';
  else if (c.role === 'tab') kind = 'tab';
  else if (toggle) kind = 'toggle';
  else if (c.hint === 'row') kind = 'row';
  else if (c.role === 'menuitem') kind = 'menuitem';
  let skip = null, hrefPath = '';
  if (c.href) {
    try {
      const u = new URL(c.href, routeUrl), cur = new URL(routeUrl);
      hrefPath = u.pathname + u.search;
      if (!/^https?:$/.test(u.protocol)) skip = 'non-http-link';
      else if (u.origin !== cur.origin) skip = 'external-link';
      else if (DENY_HREF.test(u.pathname)) skip = 'destructive-href';
      else if (u.pathname === cur.pathname && u.search === cur.search) { if (u.hash) kind = 'hash-link'; else skip = 'self-link'; }
    } catch { skip = 'bad-href'; }
  }
  if (!skip && c.target === '_blank') skip = 'opens-new-tab';
  if (!skip && c.download) skip = 'download';
  if (!skip && c.disabled) skip = 'disabled';
  if (!skip && (ALWAYS_SKIP.test(c.label) || ALWAYS_SKIP.test(hrefPath.replace(/[/_-]/g, ' ')))) skip = 'session-or-account-control';
  if (!skip && DENY.test(c.label) && !(args.readOnly && args.includeDestructive)) skip = 'destructive-text';
  if (!skip && !args.readOnly) {
    if (c.isSubmit) skip = 'form-submit';
    else if (toggle) skip = 'state-toggle';
    else if (!c.label && kind !== 'row') skip = 'unlabeled-control';
  }
  return { kind, skip, hrefPath };
}

async function enumerateActions(route, globalSeen) {
  const { error } = await navigate(route.url, { maxQuietMs: 5000 });
  if (error) return { actions: [], skipped: [], error };
  let cands = [];
  try { cands = await pageEval('window.__se.enumerate(400)', 15000); } catch (e) { return { actions: [], skipped: [], error: e.message }; }
  const actions = [], skipped = [];
  let rows = 0;
  for (const c of cands) {
    const { kind, skip, hrefPath } = triage(c, route.url);
    const key = kind === 'nav-link' ? `nav|${hrefPath}` : `${route.path}|${kind}|${c.label}|${kind === 'row' ? '' : c.selector}`;
    let reason = skip;
    if (!reason && globalSeen.has(key)) reason = 'duplicate';
    if (!reason && kind === 'row' && ++rows > 2) reason = 'row-sample-cap';
    if (!reason && actions.length >= args.maxActions) reason = 'over-max-actions';
    const base = { kind, label: c.label || `(unlabeled ${c.tag})`, selector: c.selector, tag: c.tag, role: c.role, href: c.href ? redact(c.href) : '', inNav: c.inNav };
    if (reason) { if (reason !== 'duplicate') skipped.push({ ...base, skipReason: reason }); continue; }
    globalSeen.add(key);
    actions.push({ ...base, _desc: { selector: c.selector, tag: c.tag, role: c.role, label: c.label } });
  }
  return { actions, skipped, total: cands.length };
}

// ------------------------------- click measurement -------------------------------
async function measureClick(route, cand) {
  const result = { status: 'PASS', timing: null, nav: null, requests: null, consoleErrors: [], httpErrors: [], blockedNonGet: [], dialogs: [], mutations: 0, noisyDom: false, note: null };
  const { error } = await navigate(route.url, { maxQuietMs: 5000 });
  if (error) return { ...result, status: 'UNREACHABLE', note: `route did not load: ${error}` };

  let loc;
  try { loc = await pageEval(`window.__se.resolve(${JSON.stringify(cand._desc)})`); } catch (e) { loc = { found: false, err: e.message }; }
  if (!loc.found) return { ...result, status: 'UNREACHABLE', note: 'element not found after a fresh navigation (dynamic list or state-dependent control)' };
  if (loc.obscured) return { ...result, status: 'UNREACHABLE', note: `click point is covered by <${loc.topTag}> (overlay, sticky bar or pointer-events)` };

  // Pre-click DOM quiet: if the page mutates on its own (carousel, ticker) the feedback metric is noise.
  const quiet = await waitFor(async () => { try { const s = await pageEval('window.__se.state()'); return s.lastMutAny === null || s.now - s.lastMutAny >= 300; } catch { return false; } }, 3000, 60);
  result.noisyDom = !quiet;

  const urlBefore = await pageEval('location.href');
  await pageEval('window.__se.arm()');
  const mark = net.mark();
  const blockedMark = guard ? guard.blocked.length : 0;
  ctx.t0 = null; ctx.consoleErrors = []; ctx.dialogs = []; ctx.loadFired = false;
  const navCountBefore = ctx.mainFrameNav;

  const pt = { x: loc.x, y: loc.y, button: 'left', clickCount: 1 };
  await tab.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: loc.x, y: loc.y });
  await sleep(100); // a human hovers before pressing; this also lets hover-prefetch fire, as it would for a user
  const nodeT0 = Date.now();
  const down = tab.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...pt });
  const up = tab.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...pt });
  await Promise.allSettled([down, up]);
  await waitFor(() => ctx.t0 !== null, 500, 5);
  const t0 = ctx.t0 ?? nodeT0;
  const t0Source = ctx.t0 !== null ? 'page-pointerdown' : 'node-dispatch';

  // ---- settle loop: no inflight action request AND no DOM mutation for 300ms (AND load, on a hard nav)
  let last = null, settled = false;
  const deadline = Date.now() + args.settleTimeoutMs;
  while (Date.now() < deadline) {
    await sleep(50);
    let s = null;
    try { s = await pageEval('window.__se.state()', 3000); } catch { continue; } // mid-navigation: context is gone, retry
    last = s;
    const hard = ctx.mainFrameNav > navCountBefore;
    const reqs = net.since(mark);
    if (inflight(reqs).length) continue;
    if (hard && (!ctx.loadFired || s.readyState !== 'complete')) continue;
    const lastNet = Math.max(0, ...reqs.filter((r) => r.endTs !== null).map((r) => epochOf(r, r.endTs)));
    const lastMut = hard ? (s.lastMutAny ?? 0) : (s.mut?.last ?? 0);
    const lastActivity = Math.max(t0, lastNet, lastMut, s.urlChangeAt ?? 0);
    if (s.now - lastActivity >= 300) { settled = true; break; }
  }

  const hard = ctx.mainFrameNav > navCountBefore;
  const raw = net.since(mark);
  const reqs = raw.map(summarize);
  const s = last || {};
  const urlAfter = s.href || urlBefore;
  const lastNet = Math.max(0, ...raw.filter((r) => r.endTs !== null && !LONG_LIVED.has(r.type)).map((r) => epochOf(r, r.endTs)));
  const lastMut = hard ? (s.lastMutAny ?? 0) : (s.mut?.last ?? 0);
  const loadEpoch = hard && s.loadEnd ? s.timeOrigin + s.loadEnd : 0;
  const lastActivity = Math.max(lastNet, lastMut, s.urlChangeAt ?? 0, loadEpoch);

  // first visible feedback: DOM mutation / busy indicator / URL change; on a hard nav, the new document's FCP
  const fb = [];
  if (!hard && s.mut?.first) fb.push([s.mut.first - t0, s.feedbackKind || 'dom-mutation']);
  if (!hard && s.urlChangeAt) fb.push([s.urlChangeAt - t0, 'url-change']);
  if (hard && s.fcp !== null && s.fcp !== undefined) fb.push([s.timeOrigin + s.fcp - t0, 'new-document-first-paint']);
  fb.sort((a, b) => a[0] - b[0]);

  // main response: document (hard nav) > server action > RSC > the API call with the longest wait
  const cands = reqs.filter((q) => q.kind !== 'prefetch' && ['document', 'server-action', 'rsc', 'api'].includes(q.kind));
  const pick = cands.find((q) => q.kind === 'document') || cands.find((q) => q.kind === 'server-action') || cands.find((q) => q.kind === 'rsc') || cands.slice().sort((a, b) => (b.phases?.wait || 0) - (a.phases?.wait || 0))[0] || null;
  let main = null;
  if (pick) {
    const p = pick.phases;
    const headersAt = p ? pick.startEpoch + p.stalled + p.dns + p.connect + p.ssl + p.send + p.wait : null;
    main = {
      kind: pick.kind, url: pick.url, method: pick.method, status: pick.status, fromCache: pick.fromCache, bytes: pick.bytes,
      startMs: r1(pick.startEpoch - t0), waitMs: p ? p.wait : null, receiveMs: p ? p.receive : null,
      responseStartMs: headersAt !== null ? r1(headersAt - t0) : null, responseEndMs: pick.endEpoch !== null ? r1(pick.endEpoch - t0) : null,
      phases: p, headers: pick.headers,
    };
  }

  const lts = (s.longTasks || []).filter((t) => t.start + t.dur >= t0);
  const evs = (s.events || []).filter((e) => e.start >= t0 - 50);
  const started = reqs.filter((q) => q.startEpoch >= t0 - 5);
  result.timing = {
    t0Epoch: r1(t0), t0Source,
    timeToFirstRequestMs: started.length ? r1(Math.min(...started.map((q) => q.startEpoch)) - t0) : null,
    feedbackMs: fb.length ? r1(Math.max(0, fb[0][0])) : null, feedbackKind: fb.length ? fb[0][1] : null,
    feedbackWithin100ms: fb.length ? fb[0][0] <= THRESHOLDS.feedbackMs : false,
    busyIndicatorSeen: s.feedbackKind === 'busy-indicator',
    mainResponse: main,
    settleMs: lastActivity > 0 ? r1(Math.max(0, lastActivity - t0)) : null, settled,
    inpMs: evs.length ? r1(Math.max(...evs.map((e) => e.dur))) : null,
    longTaskTotalMs: r1(lts.reduce((a, t) => a + t.dur, 0)), longTaskMaxMs: r1(Math.max(0, ...lts.map((t) => t.dur))),
  };
  const sameDoc = (() => { try { const a = new URL(urlBefore), b = new URL(urlAfter); return a.origin + a.pathname + a.search === b.origin + b.pathname + b.search; } catch { return urlBefore === urlAfter; } })();
  result.nav = { urlBefore: redact(urlBefore), urlAfter: redact(urlAfter), type: hard ? 'hard' : urlAfter === urlBefore ? 'none' : sameDoc ? 'hash' : 'soft' };
  result.requests = {
    count: reqs.length, bytes: reqs.reduce((a, q) => a + (q.bytes || 0), 0),
    slowest: reqs.filter((q) => q.durationMs !== null).sort((a, b) => b.durationMs - a.durationMs).slice(0, 5),
    sequential: sequentialDepth(reqs, { types: ['Document', 'Fetch', 'XHR'] }),
  };
  result.mutations = hard ? null : (s.mut?.count ?? 0);
  result.consoleErrors = ctx.consoleErrors.slice(0, 10);
  result.httpErrors = reqs.filter((q) => q.status >= 400).map((q) => ({ status: q.status, url: q.url })).slice(0, 10);
  result.blockedNonGet = guard ? guard.blocked.slice(blockedMark).map((b) => ({ method: b.method, url: redact(b.url) })) : [];
  result.dialogs = ctx.dialogs.slice();

  const happened = hard || urlAfter !== urlBefore || (s.mut?.count ?? 0) > 0 || reqs.length > 0 || result.dialogs.length > 0;
  if (result.blockedNonGet.length) result.status = 'BLOCKED';
  else if (!happened) { result.status = 'DEAD'; result.note = 'no navigation, no DOM mutation, no network request and no dialog followed the click'; }
  else if (result.httpErrors.length || result.consoleErrors.length) result.status = 'ERROR';
  return result;
}

// ------------------------------- main -------------------------------
async function main() {
  const startedAt = new Date();
  const version = await setup();
  log(`connected to ${version.Browser} on :${args.port}; tab ${tab.targetId}; mode=${args.readOnly ? 'READ-ONLY (non-GET aborted at the wire)' : 'default (destructive denylist + non-GET logging)'}`);

  const toUrl = (p) => new URL(p, (args.base || args.url).replace(/\/?$/, '/')).toString();
  const explicit = args.routes.length > 0;
  const routeUrls = explicit ? args.routes.map((p) => (/^https?:/.test(p) ? p : toUrl(p.replace(/^\//, '')))) : [args.url];
  const routes = [];
  const caveats = [];

  for (let i = 0; i < routeUrls.length; i++) {
    const url = routeUrls[i];
    const route = { id: `R${i + 1}`, url, path: patternOf(url), runs: [] };
    for (let n = 0; n < args.runs; n++) {
      const run = await measureNavigation(url, n);
      route.runs.push(run);
      log(`${route.id} ${route.path} run ${n + 1}/${args.runs}: ${run.error ? 'ERROR ' + run.error : `ttfb=${run.ttfb} docWait=${run.document?.phases?.wait} fcp=${run.fcp} lcp=${run.lcp} load=${run.load} reqs=${run.requests} bytes=${run.bytes}`}`);
      if (i === 0 && n === 0 && !explicit) {
        const found = await discoverRoutes(url, routeUrls);
        routeUrls.push(...found);
        log(`discovered ${found.length} more same-origin route(s): ${found.map(patternOf).join(', ') || '-'}`);
      }
    }
    aggregateRoute(route);
    routes.push(route);
  }

  // ---- clicks
  const actions = [];
  const globalSeen = new Set();
  const donePages = new Map();
  if (args.clicks) {
    for (const route of routes) {
      if (!route.first) continue;
      const pageKey = route.finalUrl || route.url;
      if (donePages.has(pageKey)) { caveats.push(`${route.id} ${route.path} resolves to the same page as ${donePages.get(pageKey)} (${pageKey}); its actions were not re-measured`); continue; }
      donePages.set(pageKey, route.id);
      const en = await enumerateActions(route, globalSeen);
      if (en.error) { caveats.push(`${route.id}: action enumeration failed: ${en.error}`); continue; }
      log(`${route.id} ${route.path}: ${en.total} clickable candidate(s) -> ${en.actions.length} to measure, ${en.skipped.length} skipped`);
      for (const sk of en.skipped) actions.push({ id: `A${actions.length + 1}`, routeId: route.id, routePath: route.path, routeUrl: route.url, ...sk, status: 'SKIPPED' });
      for (const cand of en.actions) {
        const id = `A${actions.length + 1}`;
        let res;
        try { res = await measureClick(route, cand); } catch (e) { res = { status: 'UNREACHABLE', note: `measurement threw: ${e.message}` }; }
        const { _desc, ...pub } = cand;
        actions.push({ id, routeId: route.id, routePath: route.path, routeUrl: route.url, ...pub, skipReason: null, ...res });
        const t = res.timing;
        log(`${id} ${cand.kind} "${cand.label}" -> ${res.status}${t ? ` feedback=${t.feedbackMs}ms settle=${t.settleMs}ms firstReq=${t.timeToFirstRequestMs}ms nav=${res.nav?.type}` : ` (${res.note})`}`);
      }
    }
  }
  for (const a of actions) Object.assign(a, classifyAction(a));

  if (routes.some((r) => r.redirectedToLogin)) caveats.push('at least one route redirected to a sign-in page: the numbers describe the sign-in page, not the app behind it. Sign in to the debug Chrome profile and re-run.');
  if (routes.some((r) => r.runs.some((x) => x.visibility && x.visibility !== 'visible'))) caveats.push('the measurement tab was not visible for some runs: FCP/LCP and feedback timing can be missing or late in a hidden tab.');
  if (args.readOnly) caveats.push('read-only mode: every non-GET was aborted at the wire, so BLOCKED actions have no server timing; request interception also adds roughly 1-3ms per request.');
  if (!args.cold) caveats.push('browser HTTP cache was left ON (realistic repeat-visit numbers). Use --cold to disable it. Document `wait` is server time either way.');
  caveats.push('"first hit" is only a true cold start if the server function was idle before the run; the harness cannot force a server cold start.');
  caveats.push('each click follows a fresh navigation of its route plus a 100ms hover, so hover/viewport prefetch has already happened, as it would for a real user who just landed.');

  const counts = (key) => actions.reduce((m, a) => ((m[a[key]] = (m[a[key]] || 0) + 1), m), {});
  const report = {
    schemaVersion: SCHEMA_VERSION, tool: 'speedeval',
    meta: {
      startedAt: startedAt.toISOString(), finishedAt: new Date().toISOString(), durationMs: Date.now() - startedAt.getTime(),
      target: { startUrl: args.url, origin: ORIGIN, routesExplicit: explicit },
      options: { readOnly: args.readOnly, includeDestructive: args.includeDestructive, runs: args.runs, cold: args.cold, clicks: args.clicks, maxRoutes: args.maxRoutes, maxActions: args.maxActions },
      chrome: { browser: version.Browser, port: args.port }, thresholds: THRESHOLDS,
      firedNonGet: mutations ? mutations.fired.map((m) => ({ method: m.method, url: redact(m.url) })) : [],
      blockedNonGet: guard ? guard.blocked.map((m) => ({ method: m.method, url: redact(m.url) })) : [],
      caveats,
    },
    summary: { routes: routes.length, slowRoutes: routes.filter((r) => r.slow).length, actions: actions.length, actionStatus: counts('status'), slowActions: actions.filter((a) => a.slow).length, feelsDead: actions.filter((a) => a.flags?.includes('no-feedback')).length },
    routes, actions,
    ranking: buildRanking(routes, actions),
    hypotheses: buildHypotheses(routes, actions),
  };
  writeFileSync(join(OUT, 'report.json'), JSON.stringify(report, null, 2));
  writeFileSync(join(OUT, 'REPORT.md'), renderMarkdown(report));
  console.log(JSON.stringify({ ok: true, out: OUT, reportJson: join(OUT, 'report.json'), reportMd: join(OUT, 'REPORT.md'), ...report.summary, hypotheses: report.hypotheses.map((h) => h.id) }));
}

let exiting = false;
async function bail(code) { if (exiting) return; exiting = true; await teardown().catch(() => {}); process.exit(code); }
process.on('SIGINT', () => bail(130));
process.on('SIGTERM', () => bail(143));

main().then(() => bail(0)).catch(async (e) => {
  console.error(`[speedeval] ${e.infra ? 'INFRASTRUCTURE' : 'FATAL'}: ${e.stack || e.message}`);
  await bail(e instanceof InfraError || e.infra ? 3 : 1);
});
