// cdp.mjs — reusable, zero-dependency Chrome DevTools Protocol client for /ui-audit.
//
// Transport = Node's global WebSocket (Node >=22). NO Playwright, NO MCP, NO npm deps.
// Generalized from dentall's proven raw-CDP harness (scripts/ui-audit-assumptions/_cdp.mjs):
// port is parametrized (UI_AUDIT_CDP_PORT or openTab arg), and there are no app-specific URL
// defaults — every caller passes the URL it wants.
//
// Exports:
//   openTab(url, { port })            → a tab handle { targetId, send, on, navigate, evaluate, close }
//   InfraError                        → thrown when the :9222 debug endpoint is unreachable (→ exit 3)
//   normalizeValue(s)                 → value normalization for provenance/cross-source compares
//   installNetworkCapture(tab, opts)  → capture responses on mount + retrieve bodies (getResponseBody)
//   installReadOnlyGuard(tab, onBlock)→ WIRE-level read-only: Fetch.enable + abort every non-GET
//   installMutationLogger(tab, onFire)→ full-traversal audit: log every non-GET request that FIRES
//   screenshot(tab, path)             → Page.captureScreenshot → base64 → PNG file
//   hostOf(url)                       → hostname or ''

import { writeFileSync } from 'node:fs';

const DEFAULT_PORT = () => Number(process.env.UI_AUDIT_CDP_PORT || 9222);

export class InfraError extends Error {
  constructor(m) { super(m); this.infra = true; this.name = 'InfraError'; }
}

async function http(port, path, method = 'GET') {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, { method })
    .catch(() => { throw new InfraError(`debug Chrome not reachable on :${port} — launch it via /devtools`); });
  if (!res.ok) throw new InfraError(`CDP HTTP ${method} ${path} → ${res.status}`);
  return res.json().catch(() => ({}));
}

export async function assertEndpoint(port = DEFAULT_PORT()) {
  const v = await http(port, '/json/version');
  if (!v.webSocketDebuggerUrl) throw new InfraError('CDP /json/version has no webSocketDebuggerUrl');
  return v;
}

// Open a FRESH page target (shares the profile's cookies → inherits the logged-in session).
export async function openTab(url, { port = DEFAULT_PORT() } = {}) {
  await assertEndpoint(port);
  const t = await http(port, `/json/new?${encodeURIComponent(url)}`, 'PUT');
  if (!t.webSocketDebuggerUrl) throw new InfraError('could not open a new CDP tab (Chrome 136+ may block on the default profile — use the :9222 debug profile)');
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  const pending = new Map();
  const listeners = new Map();
  let nextId = 1;
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new InfraError('CDP WebSocket failed to open')); });
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
    } else if (msg.method) {
      for (const cb of (listeners.get(msg.method) || [])) { try { cb(msg.params); } catch {} }
    }
  };
  const send = (method, params = {}, timeoutMs = 15000) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`CDP ${method} timed out after ${timeoutMs}ms`)); } }, timeoutMs);
  });
  const on = (method, cb) => { if (!listeners.has(method)) listeners.set(method, []); listeners.get(method).push(cb); };
  return {
    targetId: t.id,
    send,
    on,
    async navigate(u) {
      await send('Page.enable');
      await send('Runtime.enable');
      const loaded = new Promise((r) => on('Page.loadEventFired', r));
      await send('Page.navigate', { url: u });
      await Promise.race([loaded, new Promise((r) => setTimeout(r, 12000))]);
      await new Promise((r) => setTimeout(r, 1200)); // settle (matches harness POST_NAVIGATE_SETTLE)
    },
    async evaluate(expression, timeoutMs = 15000) {
      const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, timeoutMs);
      if (r.exceptionDetails) throw new Error('eval exception: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
      return r.result?.value;
    },
    async close() { try { ws.close(); } catch {} try { await http(port, `/json/close/${t.id}`); } catch {} },
  };
}

// --- Network capture: enable BEFORE navigate so mount requests are seen; bodies via getResponseBody.
export async function installNetworkCapture(tab, { urlFilter } = {}) {
  await tab.send('Network.enable');
  let responses = [];
  tab.on('Network.responseReceived', (p) => {
    const url = p.response?.url || '';
    if (!urlFilter || urlFilter.test(url)) {
      responses.push({ requestId: p.requestId, url, status: p.response?.status, mimeType: p.response?.mimeType });
    }
  });
  return {
    get responses() { return responses; },
    reset() { responses = []; },
    async bodies(limit = 60) {
      const out = [];
      for (const r of responses.slice(0, limit)) {
        try {
          const b = await tab.send('Network.getResponseBody', { requestId: r.requestId }, 8000);
          if (b?.body) out.push({ url: r.url, status: r.status, body: b.base64Encoded ? '' : b.body });
        } catch {}
      }
      return out;
    },
  };
}

// --- Read-only guard (WIRE-level, fail-closed): CDP Fetch.enable aborts EVERY non-GET before it
// executes. This is the guarantee `--read-only` relies on — the start-anchored destructive denylist
// is only a secondary hint (it leaks "Save preferences"/"Confirm and Submit"). Returns live counters.
export async function installReadOnlyGuard(tab, onBlock) {
  await tab.send('Network.enable');
  await tab.send('Fetch.enable', { patterns: [{ requestStage: 'Request' }] });
  const state = { executedNonGet: 0, blockedNonGet: 0, blocked: [] };
  tab.on('Fetch.requestPaused', async (p) => {
    const method = (p.request?.method || 'GET').toUpperCase();
    try {
      if (method !== 'GET') {
        state.blockedNonGet++;
        const rec = { method, url: p.request?.url || '' };
        state.blocked.push(rec);
        if (typeof onBlock === 'function') onBlock(rec);
        await tab.send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'Aborted' });
      } else {
        await tab.send('Fetch.continueRequest', { requestId: p.requestId });
      }
    } catch {}
  });
  return state;
}

// --- Mutation logger (full traversal, non-read-only): record every non-GET that ACTUALLY fires so
// side effects are auditable after the fact. Does NOT block anything.
export async function installMutationLogger(tab, onFire) {
  await tab.send('Network.enable');
  const fired = [];
  tab.on('Network.requestWillBeSent', (p) => {
    const method = (p.request?.method || 'GET').toUpperCase();
    if (method !== 'GET') {
      const rec = { method, url: p.request?.url || '' };
      fired.push(rec);
      if (typeof onFire === 'function') onFire(rec);
    }
  });
  return { get fired() { return fired; } };
}

// --- Screenshot via Page.captureScreenshot → base64 → file (Claude then Reads the PNG for vision).
export async function screenshot(tab, path) {
  await tab.send('Page.enable');
  const r = await tab.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }, 30000);
  if (!r?.data) throw new Error('Page.captureScreenshot returned no data');
  writeFileSync(path, Buffer.from(r.data, 'base64'));
  return path;
}

export function hostOf(url) { try { return new URL(url).hostname; } catch { return ''; } }

// Normalize before compare ("$85" vs 85.0) to avoid false FAKE.
export const normalizeValue = (s) => String(s ?? '').replace(/[\s,$%]/g, '').replace(/\.0+$/, '').toLowerCase();
