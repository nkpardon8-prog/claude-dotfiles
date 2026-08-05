// Draft Arc re-engagement texts into Salesmsg widget via raw CDP. NEVER sends:
// only JS clicks on "Launch Salesmsg Widget" + Input.insertText. No Enter, no send button.
const PORT = 9222;
const BASE = `http://127.0.0.1:${PORT}`;

const contacts = JSON.parse(process.argv[2] || '[]'); // [{id, first, msg}]

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function j(path) {
  const r = await fetch(BASE + path, { method: path.startsWith('/json/new') ? 'PUT' : 'GET' });
  return r.json();
}

function cdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0;
    const pending = new Map();
    ws.onopen = () => resolve({
      call: (method, params = {}) => new Promise((res, rej) => {
        const mid = ++id;
        pending.set(mid, { res, rej });
        ws.send(JSON.stringify({ id: mid, method, params }));
        setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); rej(new Error('timeout ' + method)); } }, 20000);
      }),
      close: () => { try { ws.close(); } catch {} }
    });
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && pending.has(m.id)) {
        const { res, rej } = pending.get(m.id);
        pending.delete(m.id);
        m.error ? rej(new Error(m.error.message)) : res(m.result);
      }
    };
    ws.onerror = e => reject(new Error('ws error'));
  });
}

async function evalIn(c, expr) {
  const r = await c.call('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error('eval: ' + (r.exceptionDetails.exception?.description || 'err').slice(0, 200));
  return r.result.value;
}

async function processContact({ id, first, msg }) {
  const out = { id, first };
  try {
    // 1. find or create tab
    let tabs = (await j('/json/list')).filter(t => t.type === 'page');
    let tab = tabs.find(t => (t.url || '').includes(`/${id}/`));
    if (!tab) {
      tab = await j(`/json/new?${encodeURIComponent('https://app.hubspot.com/contacts/44031266/contact/' + id + '/')}`);
      await sleep(9000);
    }
    out.tab = tab.id;
    const page = await cdp(tab.webSocketDebuggerUrl);

    // 2. wait for record page + click Launch Salesmsg Widget (skip if widget iframe already there)
    let launched = false;
    for (let i = 0; i < 25; i++) {
      const state = await evalIn(page, `(() => {
        const f = [...document.querySelectorAll('iframe')].find(f => /salesmessage.*widget-light/i.test(f.src||''));
        if (f) return 'widget';
        const b = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Launch Salesmsg Widget' && b.offsetParent !== null);
        if (b) { b.click(); return 'clicked'; }
        return 'waiting';
      })()`);
      if (state === 'widget') { launched = true; break; }
      if (state === 'clicked') { launched = true; await sleep(6000); break; }
      await sleep(1500);
    }
    if (!launched) { out.err = 'launch button never appeared'; page.close(); return out; }

    // 3. confirm widget bound to this contact
    for (let i = 0; i < 20; i++) {
      const bound = await evalIn(page, `(() => {
        const f = [...document.querySelectorAll('iframe')].find(f => /salesmessage.*widget-light/i.test(f.src||''));
        return f ? (f.src.match(/contact_integration_id=(\\d+)/)||[])[1] : null;
      })()`);
      if (bound === String(id)) { out.bound = true; break; }
      await sleep(1500);
    }
    if (!out.bound) { out.err = 'widget not bound to contact'; page.close(); return out; }
    await sleep(4000); // let conversation + composer render

    // 4a. get this contact's Salesmsg conversation id from the CRM card link (may not exist for never-texted contacts)
    let convId = null;
    for (let i = 0; i < 8; i++) {
      convId = await evalIn(page, `(() => {
        const a = [...document.querySelectorAll('a[href*="salesmessage.com/conversations/"]')].pop();
        return a ? (a.href.match(/conversations\\/(\\d+)/)||[])[1] : null;
      })()`);
      if (convId) break;
      await sleep(1500);
    }
    out.convId = convId;

    // 4b. attach to the widget iframe target: by conversation id, or by contact id for fresh conversations
    let ifr = null;
    for (let i = 0; i < 15; i++) {
      const all = await j('/json/list');
      if (convId) ifr = all.find(t => t.type === 'iframe' && (t.url || '').includes('widget-light/conversations/' + convId));
      if (!ifr) ifr = all.find(t => t.type === 'iframe' && /widget-light/.test(t.url || '') && (t.url || '').includes('contact_integration_id=' + id));
      if (ifr) break;
      await sleep(1500);
    }
    if (!ifr) { out.err = 'widget iframe target not found (conv ' + convId + ')'; page.close(); return out; }
    const frame = await cdp(ifr.webSocketDebuggerUrl);

    // 4c. belt and braces: widget header must show this contact's first name
    // case-insensitive: the copy may normalize the stored name (e.g. HubSpot "Rj" -> "RJ")
    const hasName = await evalIn(frame, `document.body.innerText.toLowerCase().includes(${JSON.stringify(String(first).toLowerCase())})`);
    if (!hasName) { out.err = 'widget body does not show contact first name'; frame.close(); page.close(); return out; }

    // 5. focus the message field inside the widget
    const focusRes = await evalIn(frame, `(() => {
      const el = document.querySelector('[data-test="TextInput_MessageField"], [data-testid="TextInput_MessageField"]')
        || [...document.querySelectorAll('[contenteditable="true"]')].pop()
        || [...document.querySelectorAll('textarea')].pop();
      if (!el) return 'nofield';
      el.focus();
      return { tag: el.tagName, ce: el.getAttribute('contenteditable'), existing: (el.value || el.textContent || '').slice(0, 60) };
    })()`);
    if (focusRes === 'nofield') { out.err = 'message field not found in widget'; frame.close(); page.close(); return out; }
    out.field = focusRes;
    const existing = (focusRes.existing || '').trim();
    if (existing && !existing.startsWith('Hey ')) { out.err = 'field has unexpected text, skipping: ' + existing; frame.close(); page.close(); return out; }
    if (existing) {
      // replace our own prior draft: select all inside the focused composer, insertText overwrites
      await evalIn(frame, `(() => { const el = document.activeElement; el.focus(); document.execCommand('selectAll'); return true; })()`);
      out.replaced = true;
    }

    // 6. type the draft via trusted insertText (no key events, no Enter)
    await frame.call('Input.insertText', { text: msg });
    await sleep(1200);

    // 7. verify
    const after = await evalIn(frame, `(() => {
      const el = document.activeElement;
      return (el && (el.value || el.textContent) || '').trim();
    })()`);
    out.verified = after === msg;
    out.after = after.slice(0, 80);
    frame.close();
    page.close();
    return out;
  } catch (e) {
    out.err = String(e.message || e).slice(0, 160);
    return out;
  }
}

const results = [];
for (const c of contacts) {
  const r = await processContact(c);
  results.push(r);
  console.log(JSON.stringify(r));
  await sleep(1500);
}
console.log('SUMMARY ' + JSON.stringify({ ok: results.filter(r => r.verified).length, fail: results.filter(r => !r.verified).map(r => r.id + ':' + (r.err || 'unverified')) }));
