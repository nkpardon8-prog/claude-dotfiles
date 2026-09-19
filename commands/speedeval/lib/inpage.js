// inpage.js - the in-page probe for /speedeval.
//
// Runs in NODE: it exports the SOURCE of a self-contained function that measure.mjs injects with
// Page.addScriptToEvaluateOnNewDocument (so it is live before any app code on every document) and
// also Runtime.evaluate (for the document that is already open). CommonJS on purpose, same reason as
// ui-audit/lib/enumerate.js: there is no package.json here, so `node --check inpage.js` must parse.
//
// Clock: everything is reported in EPOCH ms (performance.timeOrigin + performance.now()), so a value
// survives a hard navigation (new document, new timeOrigin) and lines up with CDP Network wallTime.

'use strict';

function __speedevalInstall() {
  if (window.__se) return;
  try { if (window !== window.top) return; } catch (e) { return; }

  var E = function () { return performance.timeOrigin + performance.now(); };
  var toE = function (t) { return performance.timeOrigin + t; };
  var se = window.__se = {
    fcp: null, lcp: null, lcpEl: null, cls: 0,
    longTasks: [], events: [],
    lastMutAny: null,
    armed: false, t0: null,
    mut: { count: 0, first: null, last: null },
    feedbackKind: null, urlChangeAt: null, href0: null,
  };

  var observe = function (type, cb, extra) {
    try {
      var o = new PerformanceObserver(function (l) { l.getEntries().forEach(cb); });
      var opts = { type: type, buffered: true };
      if (extra) for (var k in extra) opts[k] = extra[k];
      o.observe(opts);
    } catch (e) {}
  };
  observe('paint', function (e) { if (e.name === 'first-contentful-paint') se.fcp = e.startTime; });
  observe('largest-contentful-paint', function (e) {
    se.lcp = e.renderTime || e.loadTime || e.startTime;
    var el = e.element;
    se.lcpEl = (el ? el.tagName.toLowerCase() : '?') + ' size=' + Math.round(e.size) + (e.url ? ' url=' + String(e.url).slice(0, 120) : '');
  });
  observe('layout-shift', function (e) { if (!e.hadRecentInput) se.cls += e.value; });
  observe('longtask', function (e) {
    if (se.longTasks.length < 500) se.longTasks.push({ start: toE(e.startTime), dur: e.duration });
  });
  observe('event', function (e) {
    if (!/^(pointerdown|pointerup|mousedown|mouseup|click)$/.test(e.name)) return;
    if (se.events.length < 200) {
      se.events.push({ name: e.name, start: toE(e.startTime), dur: e.duration, procStart: toE(e.processingStart), procEnd: toE(e.processingEnd) });
    }
  }, { durationThreshold: 16 });

  var BUSY = '[aria-busy="true"],[role="progressbar"],[class*="skeleton" i],[class*="spinner" i],[class*="shimmer" i],[class*="animate-pulse"],[class*="animate-spin"],[data-loading="true"],[data-pending="true"]';
  var busyNow = function () { try { return !!document.querySelector(BUSY); } catch (e) { return false; } };
  se.busyNow = busyNow;

  try {
    new MutationObserver(function (records) {
      var now = E();
      se.lastMutAny = now;
      if (se.armed && se.t0 !== null) {
        se.mut.count += records.length;
        if (se.mut.first === null) {
          se.mut.first = now;
          se.feedbackKind = busyNow() ? 'busy-indicator' : 'dom-mutation';
        }
        se.mut.last = now;
      }
    }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  } catch (e) {}

  // t0 = the pointerdown that OUR dispatch produces, stamped in the page clock, first in capture order.
  window.addEventListener('pointerdown', function () {
    if (!se.armed || se.t0 !== null) return;
    se.t0 = E();
    try { window.__seT0(String(se.t0)); } catch (e) {}
  }, true);

  var noteUrl = function () {
    if (se.armed && se.t0 !== null && se.urlChangeAt === null && location.href !== se.href0) se.urlChangeAt = E();
  };
  ['pushState', 'replaceState'].forEach(function (fn) {
    var orig = history[fn];
    history[fn] = function () { var r = orig.apply(this, arguments); try { noteUrl(); } catch (e) {} return r; };
  });
  window.addEventListener('popstate', noteUrl, true);
  window.addEventListener('hashchange', noteUrl, true);

  se.arm = function () {
    se.armed = true; se.t0 = null;
    se.mut = { count: 0, first: null, last: null };
    se.feedbackKind = null; se.urlChangeAt = null; se.href0 = location.href;
    se.longTasks = []; se.events = [];
    return true;
  };

  se.state = function () {
    var n = performance.getEntriesByType('navigation')[0];
    return {
      now: E(), href: location.href, timeOrigin: performance.timeOrigin, readyState: document.readyState,
      visibility: document.visibilityState,
      armed: se.armed, t0: se.t0, mut: se.mut, feedbackKind: se.feedbackKind, urlChangeAt: se.urlChangeAt,
      lastMutAny: se.lastMutAny, busy: busyNow(),
      fcp: se.fcp, lcp: se.lcp, loadEnd: n ? n.loadEventEnd : 0,
      longTasks: se.longTasks, events: se.events,
    };
  };

  se.navState = function () {
    var n = performance.getEntriesByType('navigation')[0];
    var nav = null;
    if (n) {
      nav = {
        type: n.type, redirectCount: n.redirectCount, redirectMs: n.redirectEnd - n.redirectStart,
        fetchStart: n.fetchStart, dnsMs: n.domainLookupEnd - n.domainLookupStart, connectMs: n.connectEnd - n.connectStart,
        requestStart: n.requestStart, ttfb: n.responseStart, responseEnd: n.responseEnd,
        domInteractive: n.domInteractive, dcl: n.domContentLoadedEventEnd, load: n.loadEventEnd,
        transferSize: n.transferSize, encodedBodySize: n.encodedBodySize, decodedBodySize: n.decodedBodySize,
        protocol: n.nextHopProtocol,
        serverTiming: (n.serverTiming || []).map(function (s) { return { name: s.name, dur: s.duration, desc: s.description }; }),
      };
    }
    return {
      href: location.href, title: document.title, visibility: document.visibilityState,
      timeOrigin: performance.timeOrigin, now: E(), nav: nav,
      fcp: se.fcp, lcp: se.lcp, lcpEl: se.lcpEl, cls: se.cls,
      longTasks: se.longTasks.map(function (t) { return { start: t.start - performance.timeOrigin, dur: t.dur }; }),
      resources: performance.getEntriesByType('resource').length,
      domNodes: document.getElementsByTagName('*').length,
      viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
    };
  };

  var labelOf = function (el) {
    var t = el.getAttribute('aria-label') || el.innerText || el.getAttribute('title') || el.value || '';
    if (!t) { var img = el.querySelector && el.querySelector('img[alt]'); if (img) t = img.getAttribute('alt') || ''; }
    return String(t).replace(/\s+/g, ' ').trim().slice(0, 80);
  };
  var visible = function (el) {
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.05 && cs.pointerEvents !== 'none';
  };
  var cssPath = function (el) {
    var parts = [], n = el;
    while (n && n.nodeType === 1 && n !== document.body && n !== document.documentElement) {
      if (n.id && /^[A-Za-z][\w-]*$/.test(n.id) && !/\d{4,}/.test(n.id) && document.querySelectorAll('#' + n.id).length === 1) {
        parts.unshift('#' + n.id); return parts.join(' > ');
      }
      var i = 1, s = n;
      while ((s = s.previousElementSibling)) if (s.tagName === n.tagName) i++;
      parts.unshift(n.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
      n = n.parentElement;
    }
    parts.unshift('body');
    return parts.join(' > ');
  };

  var STD = 'a[href],button,[role="button"],[role="tab"],[role="link"],[role="menuitem"],summary,[role="switch"],[role="checkbox"],[role="radio"],input[type="checkbox"],input[type="radio"],input[type="submit"],input[type="button"]';

  // Bounded enumeration of clickable things: standard interactive elements in document order, then
  // "rows" = pointer-cursor elements that neither are nor contain a standard interactive element.
  se.enumerate = function (cap) {
    var out = [], seen = new Set();
    var push = function (el, hint) {
      if (seen.has(el) || out.length >= cap) return;
      seen.add(el);
      if (!visible(el)) return;
      var tag = el.tagName.toLowerCase(), role = (el.getAttribute('role') || '').toLowerCase();
      var type = (el.getAttribute('type') || '').toLowerCase();
      var form = el.closest('form');
      var r = el.getBoundingClientRect();
      out.push({
        selector: cssPath(el), tag: tag, role: role, type: type, label: labelOf(el), hint: hint,
        href: tag === 'a' ? el.href : (el.getAttribute('data-href') || ''),
        target: el.getAttribute('target') || '', download: el.hasAttribute('download'),
        inForm: !!form, isSubmit: !!form && (type === 'submit' || (tag === 'button' && type !== 'button' && type !== 'reset')),
        disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
        selected: el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-current') === 'page',
        inNav: !!el.closest('nav,aside,header,[role="navigation"],[role="tablist"]'),
        rect: { x: Math.round(r.left), y: Math.round(r.top + scrollY), w: Math.round(r.width), h: Math.round(r.height) },
      });
    };
    document.querySelectorAll(STD).forEach(function (el) { push(el, 'std'); });
    var all = document.body ? document.body.getElementsByTagName('*') : [];
    var limit = Math.min(all.length, 6000);
    for (var i = 0; i < limit && out.length < cap; i++) {
      var el = all[i];
      if (el.matches(STD) || el.closest(STD) || el.querySelector(STD)) continue;
      if (getComputedStyle(el).cursor !== 'pointer') continue;
      if (el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer') continue;
      push(el, 'row');
    }
    return out;
  };

  se.links = function () {
    var out = [];
    document.querySelectorAll('a[href]').forEach(function (a) {
      if (out.length < 400) out.push({ href: a.href, label: labelOf(a), target: a.getAttribute('target') || '', download: a.hasAttribute('download') });
    });
    return out;
  };

  // Re-find an enumerated element after a fresh navigation, scroll it to center, report a click point.
  se.resolve = function (d) {
    var el = null, via = 'selector';
    try { el = document.querySelector(d.selector); } catch (e) {}
    if (el && d.label && labelOf(el) !== d.label) el = null;
    if (!el && d.label) {
      via = 'label';
      var q = d.tag + (d.role ? ',[role="' + d.role + '"]' : '');
      var c = document.querySelectorAll(q);
      for (var i = 0; i < c.length; i++) if (labelOf(c[i]) === d.label && visible(c[i])) { el = c[i]; break; }
    }
    if (!el) return { found: false };
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    var r = el.getBoundingClientRect();
    var x = r.left + r.width / 2, y = r.top + r.height / 2;
    var top = document.elementFromPoint(x, y);
    var ok = !!top && (top === el || el.contains(top) || top.contains(el));
    return { found: true, via: via, x: x, y: y, w: r.width, h: r.height, obscured: !ok, topTag: top ? top.tagName.toLowerCase() : null };
  };
}

module.exports = { source: '(' + __speedevalInstall.toString() + ')()' };
