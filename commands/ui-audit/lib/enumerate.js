// enumerate.js — in-page whole-surface enumeration, lifted + generalized from dentall's
// scripts/ui-audit-assumptions/02-cdp-paged-eval.mjs.
//
// This module runs in NODE (it builds the JS source strings that get injected into the page via
// CDP Runtime.evaluate). It is authored as CommonJS on purpose: there is no package.json in the
// skill dir, so `node --check enumerate.js` must parse it as CommonJS. drive.mjs imports it with a
// default import (`import enumerate from './enumerate.js'`).
//
// The in-page collector enumerates EVERY visible element AND paint-only regions/background, gives
// each a unique document-order `domPath` key (so distinct siblings/rows never silently merge),
// classifies it into the taxonomy, and returns records with `verdict: null` for later authoring.
// It writes the array onto `window[ns]` so the driver can PAGE it (<=200/record) back over CDP
// without a multi-MB single return truncating/hanging the transport.

'use strict';

// ---------------------------------------------------------------------------------------------
// The in-page collector. Defined as a real function so `node --check` validates its body; it is
// serialized with .toString() and injected. It must be fully self-contained (no closure refs).
// ---------------------------------------------------------------------------------------------
function __collectSurface() {
  function domPath(el) {
    const p = [];
    let n = el;
    while (n && n.nodeType === 1 && n !== document.body) {
      let i = 1, s = n;
      while (s.previousElementSibling) { s = s.previousElementSibling; i++; }
      p.unshift(n.tagName.toLowerCase() + ':' + i);
      n = n.parentElement;
    }
    return p.join('>');
  }

  // Taxonomy: text/stat/chart/table/button/link/input/badge/image/icon/progress/region.
  function classify(el, cs, rect, text) {
    const tag = el.tagName.toLowerCase();
    const role = (el.getAttribute('role') || '').toLowerCase();
    const cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();

    // chart: recharts container / surface / <canvas>. IMPORTANT: a bare small <svg> is a lucide-react
    // icon, NOT a chart — only treat <svg> as chart when it lives inside a recharts wrapper.
    if (tag === 'canvas') return 'chart';
    if (el.closest && el.closest('.recharts-wrapper,.recharts-surface,.recharts-responsive-container')) return 'chart';

    if (tag === 'svg') {
      const big = rect.width >= 120 && rect.height >= 120;
      return big && el.closest && el.closest('.recharts-wrapper,.recharts-surface') ? 'chart' : 'icon';
    }
    if (tag === 'i' && /(^|\s)(icon|fa-|lucide|material-icons)/.test(cls)) return 'icon';

    // table
    if (['table', 'thead', 'tbody', 'tr', 'td', 'th'].includes(tag)) return 'table';
    if (['table', 'row', 'cell', 'grid', 'gridcell', 'columnheader', 'rowheader'].includes(role)) return 'table';

    // interactive
    if (tag === 'button' || role === 'button' || (tag === 'input' && /^(button|submit|reset)$/i.test(el.getAttribute('type') || ''))) return 'button';
    if (tag === 'a' && el.getAttribute('href')) return 'link';
    if (role === 'link') return 'link';
    if (tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable) return 'input';

    // progress
    if (tag === 'progress' || role === 'progressbar' || /(^|\s)(progress|meter)/.test(cls)) return 'progress';

    // image
    if (tag === 'img') return 'image';
    if (/url\(/.test(cs.backgroundImage || '') && (rect.width >= 24 && rect.height >= 24)) return 'image';

    // badge / pill / chip / status
    if (role === 'status' || /(^|\s|-)(badge|pill|chip|tag)(\s|$|-)/.test(cls)) return 'badge';

    // stat: a data value — text is primarily a number / currency / percent, and the element is a
    // near-leaf (its own text isn't just an aggregation of many children).
    const leafish = el.childElementCount <= 1;
    if (leafish && text && /^[\$€£]?\s*[\d][\d,]*(\.\d+)?\s*[%kKmMbB]?$/.test(text)) return 'stat';

    // text: has its own visible text content
    if (text) return 'text';

    // region: visible box, no direct text, not otherwise classified — paint-only region/background.
    return 'region';
  }

  const out = [];
  for (const el of document.querySelectorAll('*')) {
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const visible = rect.width > 0 && rect.height > 0
      && cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) !== 0;
    if (!visible) continue;

    const text = (el.innerText || '').trim();
    const dp = domPath(el);
    const dataTestId = el.getAttribute('data-testid') || el.getAttribute('data-test') || '';
    const record = {
      domPath: dp,
      key: dp, // driver re-keys to hash(statePath + '|' + domPath)
      tag: el.tagName.toLowerCase(),
      type: classify(el, cs, rect, text),
      text: text.slice(0, 120),
      interactive: !!(el.matches && el.matches('button,a[href],input,select,textarea,[role=button],[onclick],[tabindex]')),
      box: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
      attrs: {
        id: el.id || '',
        role: el.getAttribute('role') || '',
        ariaLabel: el.getAttribute('aria-label') || '',
        testId: dataTestId,
        href: el.getAttribute('href') || '',
      },
      // machine-resolvable locator for the /implement handoff: data-* when present, else the domPath.
      dataLocator: dataTestId ? `[data-testid="${dataTestId}"]` : (el.id ? `#${el.id}` : dp),
      verdict: null,
    };
    out.push(record);
  }
  return out;
}

// Independent visible-node count — a SEPARATE pass over the DOM (not derived from the ledger array)
// so ledger-assert can cross-check for enumeration loss/truncation, not just missing verdicts.
function __countVisible() {
  let n = 0;
  for (const el of document.querySelectorAll('*')) {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    if (r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) !== 0) n++;
  }
  return n;
}

// ---------------------------------------------------------------------------------------------
// Expression builders (what the driver actually injects via Runtime.evaluate).
// ---------------------------------------------------------------------------------------------

// Build the whole surface onto window[ns] and RETURN, from the SAME settled-DOM evaluation, both the
// enumerated length AND an independent visible-node count. Computing both in one synchronous evaluate
// (no CDP round-trip, no settle delay between them) means the two counts reflect the IDENTICAL DOM
// moment — so the Phase-4 cross-check catches genuine enumeration-logic loss (dedup collisions,
// paging drops) rather than async DOM growth between two separately-timed passes. Returns a JSON
// string `{ reported, independentVisibleCount }`.
function setupExpr(ns = '__uiAudit') {
  return `(function(){
    var arr = (${__collectSurface.toString()})();
    window[${JSON.stringify(ns)}] = arr;
    var vis = (${__countVisible.toString()})();
    return JSON.stringify({ reported: arr.length, independentVisibleCount: vis });
  })()`;
}

// Page the pre-built surface in <=size chunks as a JSON string (avoids multi-MB single returns).
function pageExpr(ns = '__uiAudit', offset = 0, size = 200) {
  return `JSON.stringify((window[${JSON.stringify(ns)}]||[]).slice(${Number(offset)}, ${Number(offset) + Number(size)}))`;
}

// Reported ledger count for the current state.
function countExpr(ns = '__uiAudit') {
  return `(window[${JSON.stringify(ns)}]||[]).length`;
}

// Independent visible-node count (fresh pass) for the fail-closed cross-check.
function visibleCountExpr() {
  return `(${__countVisible.toString()})()`;
}

module.exports = { setupExpr, pageExpr, countExpr, visibleCountExpr, PAGE_SIZE: 200 };
