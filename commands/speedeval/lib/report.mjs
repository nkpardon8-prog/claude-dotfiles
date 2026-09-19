#!/usr/bin/env node
// report.mjs - render REPORT.md from a /speedeval report.json.
//
// Imported by measure.mjs; also runnable on its own to re-render an existing run:
//   node report.mjs <path/to/report.json>      (writes REPORT.md next to it)
//
// Plain ASCII only. The markdown is for humans; report.json is the contract for agents.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ms = (v) => (typeof v === 'number' && Number.isFinite(v) ? `${Math.round(v)}` : '-');
const kb = (v) => (typeof v === 'number' && Number.isFinite(v) ? `${(v / 1024).toFixed(1)}` : '-');
const cell = (s) => String(s ?? '-').replace(/\|/g, '/').replace(/\s+/g, ' ').trim();
const path = (u, max = 70) => { try { const x = new URL(u); const s = (x.pathname + x.search); return s.length > max ? s.slice(0, max) + '...' : s; } catch { return String(u ?? '').slice(0, max); } };
const table = (head, rows) => (rows.length ? [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...rows.map((r) => `| ${r.map(cell).join(' | ')} |`)].join('\n') : '_none_');

function phaseStr(p) {
  if (!p) return 'cached / no timing';
  return `stalled ${ms(p.stalled)} dns ${ms(p.dns)} connect ${ms(p.connect)} ssl ${ms(p.ssl)} send ${ms(p.send)} WAIT ${ms(p.wait)} receive ${ms(p.receive)}${p.reusedConnection ? ' (reused conn)' : ''}`;
}

export function renderMarkdown(rep) {
  const L = [];
  const m = rep.meta, s = rep.summary;
  L.push(`# Speed evaluation: ${m.target.origin}`, '');
  L.push(`- Run: ${m.startedAt} (${Math.round(m.durationMs / 1000)}s), ${m.chrome.browser} on :${m.chrome.port}`);
  L.push(`- Mode: ${m.options.readOnly ? 'READ-ONLY (every non-GET aborted at the wire)' : 'default (destructive denylist, non-GET logged)'}; runs per route: ${m.options.runs}; browser cache: ${m.options.cold ? 'DISABLED (--cold)' : 'on'}`);
  L.push(`- Routes: ${s.routes} (${s.slowRoutes} slow). Actions: ${s.actions} (${Object.entries(s.actionStatus).map(([k, v]) => `${k} ${v}`).join(', ') || 'none'}); ${s.slowActions} slow, ${s.feelsDead} feel dead (no feedback within ${m.thresholds.feedbackMs}ms).`);
  L.push(`- Slow means: route LCP/load > ${m.thresholds.routeSlowMs}ms or document wait > ${m.thresholds.docWaitSlowMs}ms; click -> settle > ${m.thresholds.actionSlowMs}ms.`);
  L.push(`- Schema: report.json v${rep.schemaVersion} (same directory) is the machine-readable source for everything below.`, '');

  if (m.caveats?.length) { L.push('## Read this first (caveats)', '', ...m.caveats.map((c) => `- ${c}`), ''); }

  L.push('## Top root-cause hypotheses', '');
  if (!rep.hypotheses.length) L.push('_Nothing crossed the slow / feels-dead thresholds._', '');
  rep.hypotheses.forEach((h, i) => {
    L.push(`### ${i + 1}. ${h.title}`, '', `- id: \`${h.id}\`, layer: \`${h.layer}\`, confidence: ${h.confidence}, worst: ${ms(h.worstMs)}ms, affected: ${h.affected.join(', ')}`);
    L.push('- Evidence:', ...h.evidence.map((e) => `  - ${e}`));
    L.push(`- Fix classes: ${h.fixClasses.join('; ')}`, '');
  });

  L.push('## Slowest routes and actions (ranked)', '');
  L.push(table(['#', 'id', 'what', 'total ms', 'dominant layer', 'flags'], rep.ranking.slowest.map((it, i) => [i + 1, it.id, it.label, ms(it.totalMs), it.dominantLayer, (it.flags || []).join(', ')])), '');

  L.push('## Attribution by layer', '');
  L.push(table(['layer', 'items', 'summed ms', 'ids'], Object.entries(rep.ranking.byLayer).sort((a, b) => b[1].totalMs - a[1].totalMs).map(([k, v]) => [k, v.count, ms(v.totalMs), v.ids.join(', ')])), '');

  L.push('## Routes: cold (first hit) vs warm (median of later hits)', '');
  L.push(table(['id', 'route', 'doc WAIT first', 'doc WAIT warm', 'TTFB first', 'TTFB warm', 'FCP first', 'FCP warm', 'LCP first', 'LCP warm', 'load first', 'load warm', 'reqs', 'KB', 'layer'],
    rep.routes.map((r) => { const f = r.first || {}, w = r.warmMedian || {}; return [r.id, r.path + (r.redirected ? ` -> ${path(r.finalUrl, 40)}` : ''), ms(f.docWait), ms(w.docWait), ms(f.ttfb), ms(w.ttfb), ms(f.fcp), ms(w.fcp), ms(f.lcp), ms(w.lcp), ms(f.load), ms(w.load), f.requests ?? '-', kb(f.bytes), r.dominantLayer]; })), '');
  L.push('`doc WAIT` = request sent -> first byte of the document = server + database time. It is independent of the browser cache.', '');

  L.push('## Route details', '');
  for (const r of rep.routes) {
    L.push(`### ${r.id} ${r.path}`, '', `- URL: ${r.url}${r.redirected ? ` (landed on ${r.finalUrl}${r.redirectedToLogin ? ', a SIGN-IN page' : ''})` : ''}`);
    L.push(`- Verdict: ${r.slow ? 'SLOW' : 'ok'}, dominant layer \`${r.dominantLayer}\`${r.flags?.length ? `, flags: ${r.flags.join(', ')}` : ''}`);
    if (r.layers) L.push(`- Steady-state layers (ms): server-wait ${r.layers.serverWaitMs}, network ${r.layers.networkMs}, client-render ${r.layers.clientRenderMs}, waterfall ${r.layers.waterfallMs} (budget ${r.layers.budgetMs})`);
    if (r.evidence?.length) L.push('- Evidence:', ...r.evidence.map((e) => `  - ${e}`));
    L.push('', table(['run', 'TTFB', 'doc WAIT', 'respEnd', 'DCL', 'load', 'FCP', 'LCP', 'reqs', 'cached', 'KB', 'TBT', 'error'], r.runs.map((x) => [x.run, ms(x.ttfb), ms(x.document?.phases?.wait), ms(x.responseEnd), ms(x.dcl), ms(x.load), ms(x.fcp), ms(x.lcp), x.requests ?? '-', x.cachedRequests ?? '-', kb(x.bytes), ms(x.tbt), x.error || ''])), '');
    const rep1 = r.runs.find((x) => x.document) || r.runs[0];
    if (rep1?.document) L.push(`Document request (run ${rep1.run}): ${rep1.document.status} ${rep1.document.protocol} - ${phaseStr(rep1.document.phases)}`, '');
    if (rep1?.slowestRequests?.length) L.push(`Slowest 5 requests (run ${rep1.run}):`, '', table(['ms', 'kind', 'status', 'KB', 'url', 'phases (ms)'], rep1.slowestRequests.map((q) => [ms(q.durationMs), q.kind, q.status, kb(q.bytes), path(q.url), phaseStr(q.phases)])), '');
    if (rep1?.serverRequests?.length) L.push('Data requests by server wait:', '', table(['WAIT ms', 'kind', 'method', 'status', 'url'], rep1.serverRequests.map((q) => [ms(q.phases?.wait), q.kind, q.method, q.status, path(q.url)])), '');
  }

  const done = rep.actions.filter((a) => a.status !== 'SKIPPED');
  L.push('## Actions (clicks)', '');
  L.push(table(['id', 'route', 'kind', 'label', 'status', 'feedback ms', 'first req ms', 'main WAIT', 'main dl', 'settle ms', 'INP', 'nav', 'layer'],
    done.map((a) => { const t = a.timing || {}; const mr = t.mainResponse || {}; return [a.id, a.routePath, a.kind, a.label, a.status, ms(t.feedbackMs), ms(t.timeToFirstRequestMs), ms(mr.waitMs), ms(mr.receiveMs), ms(t.settleMs) + (t.settled === false ? ' (never settled)' : ''), ms(t.inpMs), a.nav?.type ?? '-', a.dominantLayer]; })), '');

  const dead = done.filter((a) => a.flags?.includes('no-feedback'));
  L.push(`## Feels dead (no visible feedback within ${m.thresholds.feedbackMs}ms)`, '');
  L.push(table(['id', 'label', 'route', 'feedback ms', 'settle ms', 'what arrived first'], dead.map((a) => [a.id, a.label, a.routePath, ms(a.timing?.feedbackMs), ms(a.timing?.settleMs), a.timing?.feedbackKind || 'nothing'])), '');

  const broken = done.filter((a) => ['DEAD', 'ERROR', 'UNREACHABLE'].includes(a.status));
  L.push('## Functional problems', '');
  L.push(table(['id', 'label', 'route', 'status', 'detail'], broken.map((a) => [a.id, a.label, a.routePath, a.status, a.note || [...(a.httpErrors || []).map((e) => `HTTP ${e.status} ${path(e.url, 50)}`), ...(a.consoleErrors || []).map((e) => e.text.slice(0, 100))].join('; ')])), '');

  const skipped = rep.actions.filter((a) => a.status === 'SKIPPED');
  L.push('## Skipped (never clicked)', '');
  L.push(table(['id', 'route', 'kind', 'label', 'reason'], skipped.map((a) => [a.id, a.routePath, a.kind, a.label, a.skipReason])), '');

  if (m.firedNonGet?.length) L.push('## Non-GET requests that fired (side-effect audit)', '', ...m.firedNonGet.map((x) => `- ${x.method} ${x.url}`), '');
  if (m.blockedNonGet?.length) L.push('## Non-GET requests blocked by read-only', '', ...m.blockedNonGet.map((x) => `- ${x.method} ${x.url}`), '');

  L.push('## Handoff', '', 'Give a fixing agent `report.json`. Start at `hypotheses[]` (each has `affected` ids), then open those ids in `routes[]` / `actions[]` for `layers`, `evidence`, request phases and response headers.', '');
  return L.join('\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const p = process.argv[2];
  if (!p) { console.error('usage: node report.mjs <report.json>'); process.exit(2); }
  const out = join(dirname(p), 'REPORT.md');
  writeFileSync(out, renderMarkdown(JSON.parse(readFileSync(p, 'utf8'))));
  console.log(out);
}
