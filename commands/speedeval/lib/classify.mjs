// classify.mjs - turn raw /speedeval measurements into root-cause attribution.
//
// Pure functions, no I/O. Every classification carries the numbers it was derived from (`layers`,
// `evidence`) so a downstream fixing agent can check the reasoning instead of trusting the label.
//
// Layers (the `dominantLayer` vocabulary, stable):
//   server-wait    time between request sent and first response byte (server + DB)
//   network        dns / connect / tls / download / subresource transfer
//   client-render  main-thread work: long tasks, scripting before the request or after the response
//   waterfall      several requests that run one after another instead of in parallel
//   cold-start     first hit much slower than warm hits, warm hits are fine
//   no-feedback    the work is fast enough, but nothing visible happened within 100 ms of the click
//   unattributed   time passed with no server wait, no transfer and no long task to blame it on
//                  (typically continuing DOM mutation: an animation, a carousel, a video player,
//                  a polling widget). Reported honestly instead of being dumped on client-render.
//   none           not slow

export const THRESHOLDS = {
  routeSlowMs: 1500,      // LCP (or load when no LCP) above this => route is slow
  docWaitSlowMs: 600,     // document server wait above this => route is slow even if LCP is fine
  actionSlowMs: 500,      // click -> DOM settle above this => action is slow
  feedbackMs: 100,        // first visible feedback later than this => "feels dead"
  coldRatio: 2,           // first-hit wait >= ratio * warm median ...
  coldDeltaMs: 300,       // ... and at least this much slower => cold-start
  waterfallDepth: 3,      // >= this many strictly sequential requests => waterfall candidate
};

export const FIX_CLASSES = {
  'server-wait': ['query batching / N+1 removal', 'DB index or slimmer query', 'server-side data cache (ISR, unstable_cache, KV)', 'stream with Suspense so the shell paints before the data', 'co-locate compute and database region'],
  'network': ['compression + long-lived cache-control on static assets', 'CDN / edge caching', 'smaller payloads (image sizing, pagination, field selection)', 'preconnect / connection reuse'],
  'client-render': ['code-split and lazy-load heavy components', 'memoize or virtualize large lists', 'cut hydration cost (server components, less client JS)', 'move heavy work off the click handler (useTransition, web worker)'],
  'waterfall': ['parallelize independent fetches (Promise.all)', 'one combined endpoint instead of chained calls', 'prefetch on hover / viewport', 'hoist data fetching to the route level'],
  'cold-start': ['always-on compute / minimum instances', 'keep-warm ping', 'smaller server bundle for faster boot', 'edge runtime for latency-critical routes', 'pooled DB connections (avoid connect-on-boot)'],
  'no-feedback': ['loading skeleton (loading.tsx / Suspense fallback)', 'optimistic UI', 'pending state on the control (useTransition, aria-busy, spinner)', 'prefetch so the next view is instant'],
};

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const r0 = (v) => (num(v) === null ? null : Math.round(v));
export const median = (arr) => {
  const a = arr.filter((v) => num(v) !== null).sort((x, y) => x - y);
  if (!a.length) return null;
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
};

// Max number of pairwise non-overlapping requests (classic interval scheduling). It is a HINT for
// sequential chains, not proof of dependency: two requests that do not overlap may be unrelated.
export function sequentialDepth(reqs, { minMs = 30, types = null } = {}) {
  const iv = reqs
    .filter((q) => num(q.startEpoch) !== null && num(q.endEpoch) !== null && q.durationMs >= minMs && (!types || types.includes(q.type)))
    .sort((a, b) => a.endEpoch - b.endEpoch);
  let depth = 0, lastEnd = -Infinity;
  const chain = [];
  for (const q of iv) if (q.startEpoch >= lastEnd - 2) { depth++; lastEnd = q.endEpoch; chain.push(q); }
  return { depth, chainMs: chain.reduce((s, q) => s + q.durationMs, 0), chain: chain.map((q) => `${q.method} ${shortUrl(q.url)} ${r0(q.durationMs)}ms`) };
}

export function shortUrl(u, max = 90) {
  try { const x = new URL(u); const s = x.pathname + (x.search ? x.search : ''); return s.length > max ? s.slice(0, max) + '...' : s; } catch { return String(u).slice(0, max); }
}

const phaseNet = (p) => (p ? (p.stalled || 0) + (p.dns || 0) + (p.connect || 0) + (p.ssl || 0) + (p.send || 0) + (p.receive || 0) : 0);

function headerEvidence(h) {
  if (!h) return [];
  const out = [];
  for (const k of ['server-timing', 'x-nextjs-cache', 'x-nextjs-prerender', 'cache-control', 'age', 'cache-status', 'cf-cache-status', 'x-vercel-cache', 'x-cache', 'x-nf-request-id']) {
    if (h[k]) out.push(`${k}: ${String(h[k]).slice(0, 160)}`);
  }
  return out;
}

function dominantOf(layers) {
  const pairs = [['server-wait', layers.serverWaitMs], ['network', layers.networkMs], ['client-render', layers.clientRenderMs], ['waterfall', layers.waterfallMs]];
  pairs.sort((a, b) => (b[1] || 0) - (a[1] || 0));
  return pairs[0][1] > 0 ? pairs[0][0] : 'none';
}

// ---- one navigation run -> layers -------------------------------------------------------------
export function layersForRun(run) {
  if (!run || run.error || !run.document) return null;
  const budget = num(run.lcp) ?? num(run.load) ?? num(run.dcl);
  const p = run.document.phases;
  const serverWaitMs = p ? p.wait : Math.max(0, (run.ttfb || 0));
  const docNet = p ? phaseNet(p) : 0;
  const redirectMs = run.redirectMs || 0;
  const post = Math.max(0, (budget || 0) - (run.responseEnd || 0));
  const lt = (run.longTasks || []).filter((t) => t.start < (budget || Infinity)).reduce((s, t) => s + t.dur, 0);
  const clientRenderMs = Math.min(post, lt);
  const sub = Math.max(0, post - clientRenderMs);
  const isWaterfall = (run.sequential?.depth || 0) >= THRESHOLDS.waterfallDepth;
  return {
    budgetMs: r0(budget),
    serverWaitMs: r0(serverWaitMs),
    networkMs: r0(docNet + redirectMs + (isWaterfall ? 0 : sub)),
    clientRenderMs: r0(clientRenderMs),
    waterfallMs: r0(isWaterfall ? sub : 0),
  };
}

export function classifyRoute(route) {
  const ok = route.runs.filter((x) => !x.error || x.document);
  if (!ok.length) return { slow: false, dominantLayer: 'none', layers: null, flags: ['all-runs-failed'], evidence: route.runs.map((x) => x.error).filter(Boolean) };
  const first = ok[0];
  const warm = ok.slice(1);
  // representative steady-state run = the warm run closest to the warm median budget (or the only run)
  let rep = first;
  if (warm.length) {
    const b = (x) => num(x.lcp) ?? num(x.load) ?? 0;
    const m = median(warm.map(b));
    rep = warm.slice().sort((x, y) => Math.abs(b(x) - m) - Math.abs(b(y) - m))[0];
  }
  const layers = layersForRun(rep);
  const flags = [], evidence = [];
  const budget = layers?.budgetMs ?? 0;
  const warmWait = layers?.serverWaitMs ?? 0;
  const slowWarm = budget > THRESHOLDS.routeSlowMs || warmWait > THRESHOLDS.docWaitSlowMs;

  let cold = false;
  const fw = first.document?.phases?.wait, ww = median(warm.map((x) => x.document?.phases?.wait));
  if (warm.length && num(fw) !== null && num(ww) !== null && fw >= THRESHOLDS.coldRatio * ww && fw - ww >= THRESHOLDS.coldDeltaMs) {
    cold = true; flags.push('cold-start');
    evidence.push(`first-hit document wait ${r0(fw)}ms vs warm median ${r0(ww)}ms (+${r0(fw - ww)}ms, ${(fw / Math.max(ww, 1)).toFixed(1)}x)`);
  }
  const firstBudget = num(first.lcp) ?? num(first.load) ?? 0;
  const slowFirst = firstBudget > THRESHOLDS.routeSlowMs || (num(fw) ?? 0) > THRESHOLDS.docWaitSlowMs;

  let dominantLayer = 'none';
  if (slowWarm && layers) dominantLayer = dominantOf(layers);
  else if (cold && slowFirst) dominantLayer = 'cold-start';
  else if (!warm.length && slowFirst && layers) dominantLayer = dominantOf(layers);

  if (layers) {
    evidence.push(`steady-state budget ${budget}ms (${num(rep.lcp) !== null ? 'LCP' : 'load'}): server-wait ${layers.serverWaitMs}ms, network ${layers.networkMs}ms, client-render ${layers.clientRenderMs}ms, waterfall ${layers.waterfallMs}ms`);
    if (rep.sequential?.depth >= THRESHOLDS.waterfallDepth) { flags.push('sequential-requests'); evidence.push(`sequential chain depth ${rep.sequential.depth}: ${rep.sequential.chain.slice(0, 4).join(' -> ')}`); }
    if (rep.tbt > 200) { flags.push('long-tasks'); evidence.push(`blocking time from long tasks ${r0(rep.tbt)}ms (max task ${r0(rep.longTaskMax)}ms)`); }
  }
  const cc = String(rep.document?.headers?.['cache-control'] || '');
  if (/no-store|no-cache|private/.test(cc)) flags.push('document-uncacheable');
  evidence.push(...headerEvidence(rep.document?.headers));
  if (rep.httpErrors?.length) { flags.push('http-errors'); evidence.push(`${rep.httpErrors.length} request(s) with HTTP >= 400, e.g. ${rep.httpErrors[0].status} ${shortUrl(rep.httpErrors[0].url)}`); }
  if (rep.consoleErrors?.length) flags.push('console-errors');
  if (rep.visibility && rep.visibility !== 'visible') flags.push('tab-hidden-paint-metrics-unreliable');
  return { slow: slowWarm || (cold && slowFirst) || (!warm.length && slowFirst), dominantLayer, layers, flags, evidence, totalMs: Math.max(budget, cold ? firstBudget : 0) };
}

// ---- one click -> layers ------------------------------------------------------------------------
export function classifyAction(a) {
  const flags = [], evidence = [];
  if (a.status === 'SKIPPED' || a.status === 'UNREACHABLE') return { slow: false, dominantLayer: 'none', layers: null, flags, evidence, totalMs: null };
  const t = a.timing || {};
  const main = t.mainResponse;
  const settle = num(t.settleMs);
  const total = Math.max(settle ?? 0, num(main?.responseEndMs) ?? 0);
  const somethingHappened = a.status !== 'DEAD';
  const feelsDead = somethingHappened && (num(t.feedbackMs) === null || t.feedbackMs > THRESHOLDS.feedbackMs);
  if (feelsDead) {
    flags.push('no-feedback');
    evidence.push(num(t.feedbackMs) === null ? 'no DOM mutation, busy indicator or URL change was observed after the click' : `first visible feedback at ${r0(t.feedbackMs)}ms (> ${THRESHOLDS.feedbackMs}ms), kind=${t.feedbackKind}`);
  }
  let layers = null;
  if (total > 0) {
    const pre = Math.max(0, num(t.timeToFirstRequestMs) ?? 0);
    const serverWaitMs = main?.phases?.wait ?? main?.waitMs ?? 0;
    const networkMs = main ? phaseNet(main.phases) : 0;
    const after = main && num(main.responseEndMs) !== null ? Math.max(0, total - main.responseEndMs) : (main ? 0 : total);
    const isWaterfall = (a.requests?.sequential?.depth || 0) >= THRESHOLDS.waterfallDepth;
    const lt = num(t.longTaskTotalMs) ?? 0;
    const waterfallMs = isWaterfall ? Math.max(0, after - lt) : 0;
    layers = { totalMs: r0(total), serverWaitMs: r0(serverWaitMs), networkMs: r0(networkMs), clientRenderMs: r0((main ? pre : 0) + (isWaterfall ? Math.min(after, lt) : after)), waterfallMs: r0(waterfallMs) };
  }
  const slow = total > THRESHOLDS.actionSlowMs;
  let dominantLayer = 'none';
  if (a.status === 'BLOCKED') { flags.push('blocked-by-read-only'); evidence.push('a non-GET request was aborted by the read-only wire guard, so server time for this action is NOT measured'); }
  if (slow && layers) dominantLayer = dominantOf(layers);
  else if (feelsDead) dominantLayer = 'no-feedback';
  if (layers) evidence.push(`click -> settle ${layers.totalMs}ms: server-wait ${layers.serverWaitMs}ms, network ${layers.networkMs}ms, client-render ${layers.clientRenderMs}ms, waterfall ${layers.waterfallMs}ms`);
  if (main) {
    evidence.push(`main response: ${main.kind} ${main.method} ${shortUrl(main.url)} -> ${main.status}, request fired at +${r0(main.startMs)}ms, wait ${r0(main.waitMs)}ms, download ${r0(main.receiveMs)}ms${main.fromCache ? ' (browser cache)' : ''}`);
    evidence.push(...headerEvidence(main.headers));
  }
  if (a.nav?.type === 'soft' && main && main.startMs > 0 && !main.fromCache) { flags.push('not-prefetched'); }
  if (a.requests?.sequential?.depth >= THRESHOLDS.waterfallDepth) { flags.push('sequential-requests'); evidence.push(`sequential chain depth ${a.requests.sequential.depth}: ${a.requests.sequential.chain.slice(0, 4).join(' -> ')}`); }
  if ((num(t.longTaskTotalMs) ?? 0) > 100) { flags.push('long-tasks'); evidence.push(`long tasks after click ${r0(t.longTaskTotalMs)}ms (max ${r0(t.longTaskMaxMs)}ms)`); }
  if (num(t.inpMs) !== null && t.inpMs > 200) { flags.push('slow-interaction-to-paint'); evidence.push(`event-timing duration (input -> next paint) ${r0(t.inpMs)}ms`); }
  if (a.noisyDom) flags.push('noisy-dom-feedback-unreliable');
  if (a.timing && a.timing.settled === false) flags.push('never-settled');
  return { slow, dominantLayer, layers, flags, evidence, totalMs: total || null };
}

// ---- cross-cutting: ranking + hypotheses ------------------------------------------------------
export function buildRanking(routes, actions) {
  const items = [
    ...routes.map((r) => ({ id: r.id, type: 'route', label: r.path, totalMs: r.totalMs, dominantLayer: r.dominantLayer, slow: r.slow, flags: r.flags })),
    ...actions.filter((a) => a.totalMs !== null && a.totalMs !== undefined).map((a) => ({ id: a.id, type: 'action', label: `${a.kind} "${a.label}" on ${a.routePath}`, totalMs: a.totalMs, dominantLayer: a.dominantLayer, slow: a.slow, flags: a.flags })),
  ].sort((x, y) => (y.totalMs || 0) - (x.totalMs || 0));
  const byLayer = {};
  for (const it of items) {
    if (it.dominantLayer === 'none') continue;
    const b = (byLayer[it.dominantLayer] ||= { count: 0, totalMs: 0, ids: [] });
    b.count++; b.totalMs += it.totalMs || 0; b.ids.push(it.id);
  }
  return { slowest: items.slice(0, 25), byLayer };
}

export function buildHypotheses(routes, actions) {
  const all = [...routes.map((r) => ({ ...r, _t: 'route', _label: r.path })), ...actions.map((a) => ({ ...a, _t: 'action', _label: `${a.kind} "${a.label}" on ${a.routePath}` }))];
  const titles = {
    'server-wait': 'Server / database time dominates: the browser is waiting on the first byte',
    'network': 'Transfer dominates: connection setup, payload size or subresource downloads',
    'client-render': 'Main-thread work dominates: scripting / rendering after the data has arrived',
    'waterfall': 'Requests run one after another instead of in parallel',
    'cold-start': 'Cold start: the first hit pays a boot penalty that warm hits do not',
    'no-feedback': 'Feels dead: the click works, but nothing visible happens within 100 ms',
  };
  const out = [];
  for (const layer of Object.keys(titles)) {
    const hit = all.filter((x) => x.dominantLayer === layer || (layer === 'cold-start' && x.flags?.includes('cold-start')) || (layer === 'no-feedback' && x.flags?.includes('no-feedback')));
    if (!hit.length) continue;
    hit.sort((x, y) => (y.totalMs || 0) - (x.totalMs || 0));
    const evidence = [];
    for (const h of hit.slice(0, 5)) {
      const e = (h.evidence || []).filter((s) => layer !== 'cold-start' || /first-hit|server-timing|x-nf/.test(s)).slice(0, 3);
      evidence.push(`[${h.id}] ${h._label}: ${e.join(' | ')}`);
    }
    const share = hit.filter((h) => h.dominantLayer === layer).length;
    out.push({
      id: `H-${layer}`, layer, title: titles[layer],
      confidence: hit.length >= 3 && share >= 2 ? 'high' : hit.length >= 2 ? 'medium' : 'low',
      affected: hit.map((h) => h.id), worstMs: hit[0].totalMs ?? null,
      evidence, fixClasses: FIX_CLASSES[layer],
    });
  }
  const notPrefetched = actions.filter((a) => a.flags?.includes('not-prefetched') && a.slow);
  if (notPrefetched.length) {
    out.push({
      id: 'H-no-prefetch', layer: 'server-wait', title: 'Soft navigations fetch their data only AFTER the click (nothing was prefetched or cached client-side)',
      confidence: notPrefetched.length >= 2 ? 'medium' : 'low', affected: notPrefetched.map((a) => a.id), worstMs: Math.max(...notPrefetched.map((a) => a.totalMs || 0)),
      evidence: notPrefetched.slice(0, 5).map((a) => `[${a.id}] ${a.label}: request fired +${r0(a.timing.mainResponse.startMs)}ms after click, wait ${r0(a.timing.mainResponse.waitMs)}ms`),
      fixClasses: ['prefetch on hover / viewport (Link prefetch)', 'client cache (router staleTimes, TanStack Query staleTime)', 'keep previous data visible while the next view loads'],
    });
  }
  const order = { high: 0, medium: 1, low: 2 };
  return out.sort((a, b) => order[a.confidence] - order[b.confidence] || (b.worstMs || 0) - (a.worstMs || 0));
}
