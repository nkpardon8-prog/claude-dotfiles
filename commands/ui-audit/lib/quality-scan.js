// quality-scan.js - in-page DOM scan for `/ui-audit --quality` (UI quality + consistency mode).
//
// This file is ONE expression (an IIFE). It is read as text and injected via CDP
// `Runtime.evaluate` with `returnByValue: true`; the value it returns is a plain JSON-serializable
// object. It is READ-ONLY: it never clicks, never mutates the DOM, never fires a request.
//
// Optional tuning: set `window.__uiAuditQualityOpts = { cap: 60, minTap: 44 }` before evaluating.
//
// All boxes are PAGE coordinates in CSS px ({x,y,w,h} with scroll offsets added), so they line up
// with the full-page screenshot taken at the same viewport (multiply by deviceScaleFactor for PNG px).
//
// Output shape is documented in passes/quality.md ("Scan output").
(() => {
  const OPTS = Object.assign({ cap: 60, minTap: 44 }, (typeof window !== 'undefined' && window.__uiAuditQualityOpts) || {});
  const CAP = OPTS.cap;
  const VW = window.innerWidth;
  const VH = window.innerHeight;
  const SX = window.scrollX;
  const SY = window.scrollY;
  const truncated = {};

  // ------------------------------------------------------------------ helpers
  const round = (n) => Math.round(n * 10) / 10;
  const pageBox = (r) => ({ x: round(r.left + SX), y: round(r.top + SY), w: round(r.width), h: round(r.height) });
  const clip = (s, n) => { s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 3) + '...' : s; };
  const push = (list, name, item) => { if (list.length < CAP) list.push(item); else truncated[name] = (truncated[name] || list.length) + 1; };

  const styleCache = new WeakMap();
  const cs = (el) => { let s = styleCache.get(el); if (!s) { s = getComputedStyle(el); styleCache.set(el, s); } return s; };

  const visibleCache = new WeakMap();
  function isVisible(el) {
    if (!(el instanceof Element)) return false;
    if (visibleCache.has(el)) return visibleCache.get(el);
    let ok = true;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) ok = false;
    for (let n = el; ok && n && n.nodeType === 1; n = n.parentElement) {
      const s = cs(n);
      if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || Number(s.opacity) === 0) ok = false;
      if (n.getAttribute('aria-hidden') === 'true' && n !== el) ok = false;
    }
    visibleCache.set(el, ok);
    return ok;
  }

  const cssEsc = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&'));
  function selectorOf(el) {
    if (!(el instanceof Element)) return '';
    if (el.id && document.querySelectorAll('#' + cssEsc(el.id)).length === 1) return '#' + cssEsc(el.id);
    for (const a of ['data-testid', 'data-test', 'data-qa']) {
      const v = el.getAttribute(a);
      if (v && document.querySelectorAll('[' + a + '="' + v.replace(/"/g, '\\"') + '"]').length === 1) return '[' + a + '="' + v + '"]';
    }
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && n !== document.documentElement && parts.length < 6; n = n.parentElement) {
      if (n.id && document.querySelectorAll('#' + cssEsc(n.id)).length === 1) { parts.unshift('#' + cssEsc(n.id)); break; }
      const tag = n.tagName.toLowerCase();
      const sibs = n.parentElement ? Array.from(n.parentElement.children).filter((c) => c.tagName === n.tagName) : [];
      parts.unshift(sibs.length > 1 ? tag + ':nth-of-type(' + (sibs.indexOf(n) + 1) + ')' : tag);
    }
    return parts.join(' > ');
  }

  const SKIP_TEXT_ANCESTORS = 'script,style,noscript,template,code,pre,kbd,samp,textarea,svg,[contenteditable="true"]';

  // ------------------------------------------------------- collect text nodes
  // Each entry: { text, el } where el is the parent element of a visible, non-empty text node.
  const texts = [];
  {
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const raw = node.nodeValue;
      if (!raw || !raw.trim()) continue;
      const el = node.parentElement;
      if (!el || el.closest(SKIP_TEXT_ANCESTORS) || !isVisible(el)) continue;
      texts.push({ text: raw.replace(/\s+/g, ' ').trim(), el });
    }
    // Attribute-borne UI text that users also read.
    for (const el of document.querySelectorAll('input[placeholder], textarea[placeholder], input[type="button"], input[type="submit"], option')) {
      if (!isVisible(el.tagName === 'OPTION' ? el.parentElement : el)) continue;
      const t = el.tagName === 'OPTION' ? el.textContent : (el.getAttribute('placeholder') || el.value);
      if (t && t.trim()) texts.push({ text: t.replace(/\s+/g, ' ').trim(), el: el.tagName === 'OPTION' ? el.parentElement : el, attr: true });
    }
  }

  // ------------------------------------------------------ 1. machine text
  const KEBAB_STOP = new Set(['a', 'an', 'and', 'as', 'at', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'up', 'one', 'two', 'do', 'it', 'no', 'non', 'step', 'day', 'year', 'old', 'time', 'date', 'face', 'back', 'well', 'self', 'all', 'ins', 'outs']);
  const CAMEL_OK = /^(i(Phone|Pad|Pod|Message|Cloud|OS|Mac|Tunes)|e(Bay|Book|Commerce|Mail|Sign)|mac(OS|Book)|watchOS|tvOS|iPadOS|visionOS|gRPC|jQuery|npm[A-Z]|mRNA|pH|kWh|mAh)/;
  const MACHINE = [
    { kind: 'uuid', severity: 'high', re: /\b[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/gi },
    { kind: 'iso-timestamp', severity: 'high', re: /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/g },
    { kind: 'iso-date', severity: 'medium', re: /\b(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b(?![T ]\d{2}:)/g },
    { kind: 'epoch-ms', severity: 'high', re: /\b1[5-9]\d{11}\b/g },
    { kind: 'e164-phone', severity: 'high', re: /(?<![\d+])\+\d{11,15}(?!\d)/g },
    { kind: 'js-nullish', severity: 'high', re: /\b(?:undefined|NaN)\b|\[object [A-Z][A-Za-z]*\]|\bInvalid Date\b|(?:^|[\s:(,])null(?=$|[\s,.)])/g },
    { kind: 'template-leak', severity: 'high', re: /\{\{[^{}]{0,80}\}\}|\$\{[^{}]{0,80}\}|<%[^%]{0,80}%>/g },
    { kind: 'error-internals', severity: 'high', re: /\b(?:TypeError|ReferenceError|SyntaxError|RangeError|NetworkError|AxiosError|ZodError|PrismaClient\w*Error)\b|\bat \S+ \(\S+:\d+:\d+\)|\bE[A-Z]{4,}(?:REFUSED|RESET|TIMEDOUT|NOTFOUND)\b|\bstatus code \d{3}\b|\bUnexpected token\b/g },
    { kind: 'kv-leak', severity: 'high', re: /\b[a-z][a-z0-9_-]*;[a-z0-9_-]+(?:[=:;][^\s]*)?/gi },
    { kind: 'screaming-snake', severity: 'high', re: /\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/g },
    { kind: 'snake-case', severity: 'high', re: /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/g },
    { kind: 'kebab-enum', severity: 'medium', re: /\b[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}\b/g,
      keep: (m) => !m.split('-').some((p) => KEBAB_STOP.has(p)) && !/^\d/.test(m) },
    { kind: 'camel-case', severity: 'low', re: /\b[a-z]{2,}(?:[A-Z][a-z0-9]+)+\b/g, keep: (m) => !CAMEL_OK.test(m) },
    { kind: 'file-path-or-url-internal', severity: 'medium', re: /\b(?:localhost|127\.0\.0\.1)(?::\d+)?\b|(?:^|\s)\/(?:api|v\d)\/[\w/.-]+/g },
  ];
  const machineText = [];
  {
    const seen = new Set();
    for (const { text, el, attr } of texts) {
      if (el.closest('a[href^="mailto:"]')) continue; // an email address is not a machine leak
      const masked = text.replace(/\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/g, ' ').replace(/\bhttps?:\/\/\S+/g, ' ');
      const taken = [];
      for (const rule of MACHINE) {
        rule.re.lastIndex = 0;
        let m;
        while ((m = rule.re.exec(masked))) {
          const match = m[0].trim();
          if (!match) { rule.re.lastIndex++; continue; }
          if (rule.keep && !rule.keep(match)) continue;
          const start = m.index; const end = m.index + m[0].length;
          if (taken.some(([a, b]) => start < b && end > a)) continue; // earlier (more specific) rule owns this span
          taken.push([start, end]);
          const sel = selectorOf(el);
          const k = rule.kind + '|' + match + '|' + sel;
          if (seen.has(k)) continue;
          seen.add(k);
          push(machineText, 'machineText', {
            kind: rule.kind, severity: rule.severity, match, text: clip(text, 140),
            selector: sel, box: pageBox(el.getBoundingClientRect()), inAttribute: !!attr,
          });
        }
      }
    }
  }

  // ------------------------------------------------- 2. format census (per datum)
  function census(rules, sourceTexts) {
    const out = {};
    for (const { text, el } of sourceTexts) {
      const taken = [];
      for (const [style, re] of rules) {
        re.lastIndex = 0;
        let m;
        while ((m = re.exec(text))) {
          const start = m.index; const end = start + m[0].length;
          if (!m[0]) { re.lastIndex++; continue; }
          if (taken.some(([a, b]) => start < b && end > a)) continue;
          taken.push([start, end]);
          const slot = out[style] || (out[style] = { count: 0, samples: [] });
          slot.count++;
          if (slot.samples.length < 4) slot.samples.push({ match: m[0].trim(), selector: selectorOf(el), box: pageBox(el.getBoundingClientRect()) });
        }
      }
    }
    return out;
  }
  const MONTH = '(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)';
  const formatCensus = {
    phones: census([
      ['e164', /(?<![\d+])\+\d{11,15}(?!\d)/g],
      ['plus1-formatted', /\+1[\s.-]?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b/g],
      ['paren', /\(\d{3}\)\s?\d{3}[-.\s]\d{4}\b/g],
      ['dashed', /(?<![\d-])\d{3}-\d{3}-\d{4}(?![\d-])/g],
      ['dotted', /(?<![\d.])\d{3}\.\d{3}\.\d{4}(?![\d.])/g],
      ['spaced', /(?<!\d)\d{3} \d{3} \d{4}(?!\d)/g],
      ['plain10', /(?<![\d$.,#-])\d{10}(?![\d.,])/g],
    ], texts),
    dates: census([
      ['iso-timestamp', /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}\S*/g],
      ['iso-date', /\b(?:19|20)\d{2}-\d{2}-\d{2}\b/g],
      ['us-slash', /\b\d{1,2}\/\d{1,2}\/(?:\d{4}|\d{2})\b/g],
      ['slash-no-year', /(?<![\d/])\d{1,2}\/\d{1,2}(?![\d/])/g],
      ['month-long-day-year', new RegExp('\\b(?:January|February|March|April|June|July|August|September|October|November|December)\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}\\b', 'g')],
      ['month-short-day-year', new RegExp('\\b' + MONTH + '\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}\\b', 'g')],
      ['month-day', new RegExp('\\b' + MONTH + '\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?\\b', 'g')],
      ['day-month', new RegExp('\\b\\d{1,2}\\s+' + MONTH + '\\b', 'g')],
      ['relative', /\b(?:\d+\s?(?:s|sec|m|min|h|hr|d|w|mo|y)s?\s+ago|just now|yesterday|today|tomorrow|(?:last|next)\s+(?:week|month|year|(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day))\b/gi],
    ], texts),
    times: census([
      ['12h-with-minutes', /\b(?:1[0-2]|0?[1-9]):[0-5]\d\s?(?:AM|PM|am|pm|a\.m\.|p\.m\.)/g],
      ['12h-bare-hour', /\b(?:1[0-2]|0?[1-9])\s?(?:AM|PM|am|pm)\b/g],
      ['24h', /(?<![\d:])(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?![\d:]|\s?(?:AM|PM|am|pm))/g],
    ], texts),
    money: census([
      ['dollar-cents', /\$\s?\d{1,3}(?:,\d{3})*\.\d{2}\b/g],
      ['dollar-whole', /\$\s?\d{1,3}(?:,\d{3})*(?![\d.,]\d)\b/g],
      ['dollar-no-comma', /\$\s?\d{4,}(?:\.\d{2})?\b/g],
      ['code-suffix', /\b\d[\d,]*(?:\.\d{2})?\s?(?:USD|CAD|EUR|GBP)\b/g],
      ['per-unit', /\$\s?\d[\d,.]*\s?(?:\/|per\s)\s?(?:hr|hour|session|mo|month|lesson)\b/gi],
    ], texts),
  };
  for (const k of Object.keys(formatCensus)) {
    const styles = Object.keys(formatCensus[k]);
    formatCensus[k] = { styles: formatCensus[k], distinctStyles: styles.length, inconsistentOnThisScreen: styles.length > 1 };
  }

  // ------------------------------------------------ 3. interactive elements
  const INTERACTIVE_SEL = 'a[href], button, input:not([type="hidden"]), select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="switch"], [role="checkbox"], [role="radio"], [role="option"], [onclick], [tabindex]:not([tabindex="-1"])';
  const interactive = Array.from(document.querySelectorAll(INTERACTIVE_SEL)).filter(isVisible)
    // drop wrappers whose only job is to contain another interactive element of the same box
    .filter((el, _i, all) => !all.some((o) => o !== el && el.contains(o) && el.tagName !== 'A' && el.tagName !== 'BUTTON' && !el.getAttribute('role')));
  const nameOf = (el) => clip(
    el.getAttribute('aria-label') || (el.getAttribute('aria-labelledby') && (document.getElementById(el.getAttribute('aria-labelledby').split(' ')[0]) || {}).textContent) ||
    el.innerText || el.value || el.getAttribute('title') || el.getAttribute('placeholder') || (el.querySelector('img[alt]') || {}).alt || '', 60);

  const inFirstViewport = (r) => r.top + SY < VH && r.bottom + SY > 0;
  const wordCount = (s) => (s.match(/\S+/g) || []).length;
  let wordsTotal = 0; let wordsFirst = 0;
  for (const t of texts) { if (t.attr) continue; const w = wordCount(t.text); wordsTotal += w; if (inFirstViewport(t.el.getBoundingClientRect())) wordsFirst += w; }
  const fontSizes = {}; const textColors = {}; const fontFamilies = {};
  for (const t of texts) {
    const s = cs(t.el);
    fontSizes[s.fontSize] = (fontSizes[s.fontSize] || 0) + 1;
    textColors[s.color] = (textColors[s.color] || 0) + 1;
    const fam = s.fontFamily.split(',')[0].trim().replace(/["']/g, '');
    fontFamilies[fam] = (fontFamilies[fam] || 0) + 1;
  }
  const isButtonLike = (el) => el.tagName === 'BUTTON' || el.getAttribute('role') === 'button' || (el.tagName === 'INPUT' && /^(button|submit|reset)$/.test(el.type)) ||
    (el.tagName === 'A' && /\b(btn|button|cta)\b/i.test(el.className && el.className.baseVal === undefined ? el.className : ''));
  const buttons = interactive.filter(isButtonLike);
  const pageHeightInViewports = round(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0) / VH);
  const density = {
    interactiveTotal: interactive.length,
    interactiveFirstViewport: interactive.filter((el) => inFirstViewport(el.getBoundingClientRect())).length,
    buttonsTotal: buttons.length,
    buttonsFirstViewport: buttons.filter((el) => inFirstViewport(el.getBoundingClientRect())).length,
    linksTotal: interactive.filter((el) => el.tagName === 'A').length,
    inputsTotal: interactive.filter((el) => /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName)).length,
    textNodesTotal: texts.filter((t) => !t.attr).length,
    textNodesFirstViewport: texts.filter((t) => !t.attr && inFirstViewport(t.el.getBoundingClientRect())).length,
    wordsTotal, wordsFirstViewport: wordsFirst,
    interactivePerViewport: round(interactive.length / Math.max(1, pageHeightInViewports)),
    pageHeightInViewports,
    distinctFontSizes: Object.keys(fontSizes).length, fontSizes,
    distinctTextColors: Object.keys(textColors).length,
    distinctFontFamilies: Object.keys(fontFamilies).length, fontFamilies,
  };

  // ------------------------------------------------------ 4. tap targets
  const tapTargets = [];
  for (const el of interactive) {
    let r = el.getBoundingClientRect();
    // A checkbox/radio wrapped in (or pointed at by) a label is as big as the label.
    if (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type)) {
      const lab = el.closest('label') || (el.id && document.querySelector('label[for="' + cssEsc(el.id) + '"]'));
      if (lab && isVisible(lab)) { const lr = lab.getBoundingClientRect(); if (lr.width * lr.height > r.width * r.height) r = lr; }
    }
    if (r.width >= OPTS.minTap && r.height >= OPTS.minTap) continue;
    const inline = el.tagName === 'A' && cs(el).display.startsWith('inline') && !!el.parentElement &&
      wordCount(el.parentElement.innerText || '') > wordCount(el.innerText || '') + 3; // WCAG 2.5.8 inline exception
    push(tapTargets, 'tapTargets', {
      selector: selectorOf(el), label: nameOf(el), tag: el.tagName.toLowerCase(), box: pageBox(r),
      w: round(r.width), h: round(r.height), inlineTextLink: inline,
      severityHint: inline ? 'low' : (Math.min(r.width, r.height) < 24 ? 'high' : 'medium'),
    });
  }

  // ------------------------------------------- 5. headers / title centering
  const rectGap = (a, b) => { // 0 when overlapping; otherwise the edge-to-edge distance
    const dx = Math.max(0, Math.max(a.left, b.left) - Math.min(a.right, b.right));
    const dy = Math.max(0, Math.max(a.top, b.top) - Math.min(a.bottom, b.bottom));
    return { gap: round(Math.hypot(dx, dy)), dx: round(dx), dy: round(dy) };
  };
  const headers = [];
  {
    const cand = new Set(document.querySelectorAll('h1, h2, h3, [role="heading"], header [class*="title" i], nav [class*="title" i], [class*="navbar" i] [class*="title" i], [class*="header" i] > [class*="title" i]'));
    for (const el of cand) {
      if (!isVisible(el) || !(el.innerText || '').trim()) continue;
      const r = el.getBoundingClientRect();
      // Measure the INK, not the block: a block-level h1 spans its container, so use a Range over its text.
      const range = document.createRange(); range.selectNodeContents(el);
      const ink = range.getBoundingClientRect();
      const inkR = ink.width > 0 ? ink : r;
      let container = el.parentElement;
      while (container && container !== document.body && container.getBoundingClientRect().width < VW * 0.9) container = container.parentElement;
      const c = (container || document.body).getBoundingClientRect();
      const s = cs(el);
      const offset = round((inkR.left + inkR.width / 2) - (c.left + c.width / 2));
      let nearest = null;
      for (const it of interactive) {
        if (it === el || el.contains(it) || it.contains(el)) continue;
        const g = rectGap(inkR, it.getBoundingClientRect());
        if (g.gap <= 48 && (!nearest || g.gap < nearest.gapPx)) nearest = { selector: selectorOf(it), label: nameOf(it), gapPx: g.gap, dxPx: g.dx, dyPx: g.dy, box: pageBox(it.getBoundingClientRect()) };
      }
      const flags = [];
      const centeredIntent = s.textAlign === 'center' || /center/.test(cs(el.parentElement || el).justifyContent) || Math.abs(offset) <= 24;
      if (centeredIntent && Math.abs(offset) > 2 && Math.abs(offset) <= 40) flags.push('off-center');
      if (nearest && nearest.gapPx < 8) flags.push(nearest.gapPx === 0 ? 'overlaps-neighbor' : 'crammed-against-neighbor');
      if (inkR.top < 4 && SY === 0) flags.push('touches-viewport-top');
      if (inkR.left < 8 || VW - inkR.right < 8) flags.push('touches-viewport-edge');
      push(headers, 'headers', {
        selector: selectorOf(el), text: clip(el.innerText, 80), tag: el.tagName.toLowerCase(),
        box: pageBox(r), inkBox: pageBox(inkR), containerBox: pageBox(c),
        centerOffsetPx: offset, leftGapPx: round(inkR.left - c.left), rightGapPx: round(c.right - inkR.right),
        textAlign: s.textAlign, fontSize: s.fontSize, fontWeight: s.fontWeight, nearestInteractive: nearest, flags,
      });
    }
  }

  // ------------------------------------------------------ 6. gutter census
  // Left/right insets of text-bearing blocks. Many distinct values inside one screen = uneven gutters.
  const gutters = { left: {}, right: {} };
  {
    const blocks = new Set();
    for (const t of texts) { if (!t.attr) blocks.add(t.el); }
    for (const el of blocks) {
      const r = el.getBoundingClientRect();
      if (r.width < 40) continue;
      const l = Math.round(r.left); const rt = Math.round(VW - r.right);
      if (l >= 0 && l <= 64) gutters.left[l] = (gutters.left[l] || 0) + 1;
      if (rt >= 0 && rt <= 64 && r.width > VW * 0.5) gutters.right[rt] = (gutters.right[rt] || 0) + 1;
    }
    gutters.distinctLeft = Object.keys(gutters.left).length;
    gutters.distinctRight = Object.keys(gutters.right).length;
  }

  // ------------------------------------------------ 7. overflow / clipping
  const docEl = document.documentElement;
  const overflow = { horizontalScroll: docEl.scrollWidth > VW + 1, documentScrollWidth: docEl.scrollWidth, viewportWidth: VW, offenders: [] };
  const truncation = [];
  {
    const all = document.body ? document.body.querySelectorAll('*') : [];
    for (const el of all) {
      if (el.closest('svg') && el.tagName.toLowerCase() !== 'svg') continue;
      if (!isVisible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.right > VW + 1 || r.left < -1) {
        // ignore content living inside an intentional horizontal scroller (carousel, table wrapper)
        let scroller = false;
        for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) { if (/(auto|scroll)/.test(cs(n).overflowX)) { scroller = true; break; } }
        const fixedOff = cs(el).position === 'fixed' && (r.left >= VW || r.right <= 0); // parked off-canvas drawer
        if (!scroller && !fixedOff && !Array.from(el.children).some((c) => { const cr = c.getBoundingClientRect(); return cr.right > VW + 1 || cr.left < -1; })) {
          push(overflow.offenders, 'overflow.offenders', { selector: selectorOf(el), text: clip(el.innerText || '', 60), box: pageBox(r), overRightPx: round(Math.max(0, r.right - VW)), overLeftPx: round(Math.max(0, -r.left)) });
        }
      }
      const s = cs(el);
      const hasOwnText = Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.nodeValue.trim());
      if (!hasOwnText) continue;
      const clipsX = /(hidden|clip)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 1;
      const clipsY = /(hidden|clip)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 1;
      if (clipsX || clipsY) {
        const clamp = s.webkitLineClamp && s.webkitLineClamp !== 'none';
        push(truncation, 'truncation', {
          selector: selectorOf(el), text: clip(el.textContent, 120), box: pageBox(r),
          axis: clipsX && clipsY ? 'both' : clipsX ? 'x' : 'y',
          ellipsis: s.textOverflow === 'ellipsis' || !!clamp, lineClamp: clamp ? s.webkitLineClamp : null,
          hiddenPx: clipsX ? el.scrollWidth - el.clientWidth : el.scrollHeight - el.clientHeight,
          fullTextReachable: !!(el.getAttribute('title') || el.closest('a[href], button, summary, [aria-expanded]')),
        });
      }
    }
  }

  // ------------------------------------------------------------ 8. contrast
  const parseColor = (str) => {
    const m = String(str).match(/rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,/\s]+([\d.]+%?))?\s*\)/);
    if (!m) return null;
    let a = m[4] === undefined ? 1 : (String(m[4]).endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]));
    if (Number.isNaN(a)) a = 1;
    return { r: +m[1], g: +m[2], b: +m[3], a };
  };
  const over = (fg, bg) => ({ r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a), b: fg.b * fg.a + bg.b * (1 - fg.a), a: 1 });
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b); };
  function effectiveBg(el) {
    const layers = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const s = cs(n);
      if (s.backgroundImage && s.backgroundImage !== 'none') return null; // gradient/image: not measurable, leave to vision
      const c = parseColor(s.backgroundColor);
      if (c && c.a > 0) { layers.push(c); if (c.a >= 1) break; }
    }
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    const rootScheme = cs(document.documentElement).colorScheme || '';
    if (!layers.some((l) => l.a >= 1) && /dark/.test(rootScheme) && !/light/.test(rootScheme)) bg = { r: 18, g: 18, b: 18, a: 1 };
    for (let i = layers.length - 1; i >= 0; i--) bg = over(layers[i], bg);
    return bg;
  }
  const contrast = [];
  {
    const seenEl = new Set(); const pairs = new Map();
    for (const t of texts) {
      if (t.attr || seenEl.has(t.el)) continue;
      seenEl.add(t.el);
      const s = cs(t.el);
      const fg0 = parseColor(s.color); const bg = effectiveBg(t.el);
      if (!fg0 || !bg) continue;
      const fg = over(fg0, bg);
      const l1 = lum(fg); const l2 = lum(bg);
      const ratio = round((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05));
      const px = parseFloat(s.fontSize); const bold = parseInt(s.fontWeight, 10) >= 700;
      const large = px >= 24 || (px >= 18.66 && bold);
      const need = large ? 3 : 4.5;
      if (ratio >= need) continue;
      const key = s.color + '|' + Math.round(bg.r) + ',' + Math.round(bg.g) + ',' + Math.round(bg.b) + '|' + need;
      const hit = pairs.get(key);
      if (hit) { hit.count++; continue; }
      const rec = {
        selector: selectorOf(t.el), text: clip(t.text, 60), box: pageBox(t.el.getBoundingClientRect()),
        color: s.color, background: 'rgb(' + Math.round(bg.r) + ', ' + Math.round(bg.g) + ', ' + Math.round(bg.b) + ')',
        ratio, required: need, fontSize: s.fontSize, fontWeight: s.fontWeight, count: 1,
        disabledLooking: !!t.el.closest('[disabled], [aria-disabled="true"]'),
      };
      pairs.set(key, rec);
      push(contrast, 'contrast', rec);
    }
  }

  // ------------------------------------------- 9. labels, actions, variants
  const VAGUE = /^(edit|change|set|select|choose|option|options|settings?|more|manage|update|configure|view|details?|click here|here|submit|ok|okay|go|open|continue|learn more|read more|see more)$/i;
  const ICONABLE = /^(back|close|dismiss|menu|search|delete|remove|trash|call|phone|text|message|email|mail|next|previous|prev|add|new|edit|share|copy|download|upload|refresh|reload|filter|sort|info|help|expand|collapse|more)$/i;
  const vagueLabels = []; const unlabeledControls = []; const iconCandidates = [];
  const labelCounts = new Map();
  for (const el of interactive) {
    const name = nameOf(el);
    const visibleText = clip(el.innerText || el.value || '', 60);
    const r = el.getBoundingClientRect();
    if (!name) { push(unlabeledControls, 'unlabeledControls', { selector: selectorOf(el), tag: el.tagName.toLowerCase(), box: pageBox(r) }); continue; }
    if (visibleText && VAGUE.test(visibleText)) push(vagueLabels, 'vagueLabels', { selector: selectorOf(el), label: visibleText, box: pageBox(r), showsCurrentValue: false });
    if (visibleText && ICONABLE.test(visibleText) && !el.querySelector('svg, img, i[class*="icon" i]')) push(iconCandidates, 'iconCandidates', { selector: selectorOf(el), label: visibleText, box: pageBox(r) });
    if (visibleText && !el.closest('nav, [role="navigation"], footer')) {
      const k = visibleText.toLowerCase();
      const e = labelCounts.get(k) || { label: visibleText, count: 0, selectors: [] };
      e.count++; if (e.selectors.length < 4) e.selectors.push(selectorOf(el));
      labelCounts.set(k, e);
    }
  }
  const duplicateActions = Array.from(labelCounts.values()).filter((e) => e.count >= 2).sort((a, b) => b.count - a.count).slice(0, CAP);

  // Actions whose label names the screen you are already on (e.g. a "Text" action inside the text thread).
  const selfReferentialActions = [];
  {
    const ctx = new Set();
    const addWords = (s) => String(s || '').toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length >= 3).forEach((w) => ctx.add(w));
    addWords(location.pathname); addWords((document.querySelector('h1') || {}).innerText);
    const SYN = { inbox: ['text', 'message', 'messages', 'sms'], messages: ['text', 'message', 'sms'], thread: ['text', 'message'], calls: ['call', 'phone'], 'call-history': ['call'], calendar: ['calendar', 'schedule'], settings: ['settings'], clients: ['clients'] };
    for (const w of Array.from(ctx)) (SYN[w] || []).forEach((x) => ctx.add(x));
    for (const el of interactive) {
      if (el.closest('nav, [role="navigation"], [role="tablist"], footer')) continue; // the active nav item is legitimately self-named
      const t = (el.innerText || el.getAttribute('aria-label') || '').trim().toLowerCase();
      if (t && t.length <= 24 && ctx.has(t)) push(selfReferentialActions, 'selfReferentialActions', { selector: selectorOf(el), label: clip(t, 40), box: pageBox(el.getBoundingClientRect()), matchedContextWord: t });
    }
  }

  // Button style census: one role should have one look. Vision decides role; this gives the evidence.
  const buttonVariants = [];
  {
    const sigs = new Map();
    for (const el of buttons) {
      const s = cs(el); const r = el.getBoundingClientRect();
      const sig = [s.backgroundColor, s.color, s.borderTopLeftRadius, s.borderTopWidth + ' ' + s.borderTopStyle + ' ' + s.borderTopColor, s.fontSize, s.fontWeight, Math.round(r.height / 4) * 4 + 'px-tall', s.textTransform].join(' | ');
      const e = sigs.get(sig) || { signature: sig, count: 0, samples: [] };
      e.count++; if (e.samples.length < 4) e.samples.push({ label: nameOf(el), selector: selectorOf(el), box: pageBox(r) });
      sigs.set(sig, e);
    }
    Array.from(sigs.values()).sort((a, b) => b.count - a.count).slice(0, CAP).forEach((e) => buttonVariants.push(e));
  }

  // ------------------------------------------------ 10. long cards, text walls
  const longCards = []; const textWalls = [];
  {
    const cardSel = 'article, li, section, details, [class*="card" i], [class*="panel" i], [class*="tile" i], [class*="row" i], [class*="item" i]';
    const found = [];
    for (const el of document.querySelectorAll(cardSel)) {
      if (!isVisible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.height < VH * 0.75 || r.width < VW * 0.5) continue;
      if (r.height > docEl.scrollHeight * 0.8) continue; // that is the page wrapper, not a card
      const s = cs(el);
      const looksLikeCard = el.matches('article, li, details') || s.boxShadow !== 'none' || parseFloat(s.borderTopWidth) > 0 || parseFloat(s.borderTopLeftRadius) > 0;
      if (!looksLikeCard) continue;
      found.push({ el, r });
    }
    for (const { el, r } of found) {
      if (found.some((o) => o.el !== el && el.contains(o.el))) continue; // report the innermost long card
      push(longCards, 'longCards', {
        selector: selectorOf(el), box: pageBox(r), heightInViewports: round(r.height / VH), words: wordCount(el.innerText || ''),
        interactiveInside: interactive.filter((i) => el.contains(i)).length,
        hasDisclosure: !!el.querySelector('details, [aria-expanded]') || el.tagName === 'DETAILS' || el.hasAttribute('aria-expanded'),
      });
    }
    const seenWall = new Set();
    for (const t of texts) {
      if (t.attr || seenWall.has(t.el)) continue;
      seenWall.add(t.el);
      const words = wordCount(t.el.innerText || '');
      if (words < 60) continue;
      if (Array.from(t.el.children).some((c) => wordCount(c.innerText || '') > words * 0.8)) continue;
      const r = t.el.getBoundingClientRect();
      const lh = parseFloat(cs(t.el).lineHeight) || parseFloat(cs(t.el).fontSize) * 1.2;
      push(textWalls, 'textWalls', { selector: selectorOf(t.el), words, approxLines: Math.round(r.height / lh), box: pageBox(r), text: clip(t.el.innerText, 100) });
    }
  }

  // ---------------------------------------------- 11. state markers (empty/loading/error)
  const STATE = [
    ['error-generic', /\b(?:unavailable|something went wrong|an error occurred|error|failed(?: to \w+)?|could ?n[o']t (?:load|fetch|connect)|try again(?: later)?|oops)\b/i],
    ['empty', /\b(?:no (?:results|data|items|messages|calls|clients|bookings|appointments|records|entries)(?: found| yet)?|nothing (?:here|to show|yet)|empty|none yet)\b/i],
    ['loading', /\b(?:loading|please wait|fetching)\b|\.\.\.$/i],
  ];
  const stateText = [];
  for (const t of texts) {
    if (t.attr || t.text.length > 160) continue;
    for (const [kind, re] of STATE) {
      if (!re.test(t.text)) continue;
      const host = t.el.closest('section, article, li, [class*="card" i], [class*="empty" i], [class*="error" i], main') || t.el;
      push(stateText, 'stateText', {
        kind, text: clip(t.text, 120), selector: selectorOf(t.el), box: pageBox(t.el.getBoundingClientRect()),
        // design signals vision should confirm: an illustration/icon, a heading, and a next action near the message
        hasIconOrImage: !!host.querySelector('svg, img'), hasAction: !!host.querySelector('a[href], button'), bareText: host === t.el || host.children.length <= 1,
      });
      break;
    }
  }
  const loadingIndicators = {
    ariaBusy: document.querySelectorAll('[aria-busy="true"]').length,
    skeletons: Array.from(document.querySelectorAll('[class*="skeleton" i], [class*="shimmer" i], [class*="placeholder" i]')).filter(isVisible).length,
    spinners: Array.from(document.querySelectorAll('[class*="spinner" i], [class*="loader" i], [role="progressbar"]')).filter(isVisible).length,
  };
  const disclosures = {
    detailsClosed: document.querySelectorAll('details:not([open])').length,
    ariaCollapsed: Array.from(document.querySelectorAll('[aria-expanded="false"]')).filter(isVisible).length,
  };

  // ------------------------------------------------------------- summary
  const bySeverity = (list) => list.reduce((a, x) => { a[x.severity] = (a[x.severity] || 0) + 1; return a; }, {});
  return {
    schema: 'ui-audit.quality-scan/1',
    url: location.href, path: location.pathname, title: document.title, scannedAt: new Date().toISOString(),
    viewport: { w: VW, h: VH, dpr: window.devicePixelRatio, scrollX: SX, scrollY: SY },
    document: { scrollWidth: docEl.scrollWidth, scrollHeight: docEl.scrollHeight, lang: docEl.lang || null },
    summary: {
      machineText: machineText.length, machineTextBySeverity: bySeverity(machineText),
      phoneStyles: formatCensus.phones.distinctStyles, dateStyles: formatCensus.dates.distinctStyles,
      timeStyles: formatCensus.times.distinctStyles, moneyStyles: formatCensus.money.distinctStyles,
      interactiveFirstViewport: density.interactiveFirstViewport, smallTapTargets: tapTargets.filter((t) => !t.inlineTextLink).length,
      headerFlags: headers.filter((h) => h.flags.length).length, horizontalScroll: overflow.horizontalScroll,
      overflowOffenders: overflow.offenders.length, truncated: truncation.length, lowContrast: contrast.length,
      vagueLabels: vagueLabels.length, unlabeledControls: unlabeledControls.length, buttonVariants: buttonVariants.length,
      longCards: longCards.length, textWalls: textWalls.length, stateText: stateText.length,
    },
    machineText, formatCensus, density, tapTargets, headers, gutters, overflow, truncation, contrast,
    vagueLabels, unlabeledControls, iconCandidates, duplicateActions, selfReferentialActions, buttonVariants,
    longCards, textWalls, stateText, loadingIndicators, disclosures,
    truncatedLists: truncated,
  };
})()
