// Final verification: (1) no SMS was sent today to any of the 20 (last_sms_sent_date unchanged),
// (2) every draft sits in its composer, (3) dedupe Derek's duplicate tab.
const BASE = 'http://127.0.0.1:9222';
const ids = JSON.parse(process.argv[2] || '[]');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const j = async p => (await fetch(BASE + p)).json();

function cdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0; const pending = new Map();
    ws.onopen = () => resolve({
      call: (method, params = {}) => new Promise((res, rej) => {
        const mid = ++id; pending.set(mid, { res, rej });
        ws.send(JSON.stringify({ id: mid, method, params }));
        setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); rej(new Error('timeout')); } }, 30000);
      }),
      close: () => { try { ws.close(); } catch {} }
    });
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } };
    ws.onerror = () => reject(new Error('ws error'));
  });
}
const evalIn = async (c, expression) => {
  const r = await c.call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error('eval failed');
  return r.result.value;
};

// 1) API check from a HubSpot tab context
const tabs = (await j('/json/list')).filter(t => t.type === 'page' && (t.url || '').includes('app.hubspot.com'));
const hub = await cdp(tabs[0].webSocketDebuggerUrl);
const api = await evalIn(hub, `(async () => {
  const csrf = (document.cookie.match(/hubspotapi-csrf=([^;]+)/)||[])[1];
  const out = {};
  for (const id of ${JSON.stringify(ids)}) {
    const r = await fetch('https://app.hubspot.com/api/contacts/v1/contact/vid/' + id + '/profile?portalId=44031266', { credentials: 'include', headers: { 'X-HubSpot-CSRF-hubspotapi': csrf } });
    const p = (await r.json()).properties || {};
    out[id] = p.last_sms_sent_date ? new Date(+p.last_sms_sent_date.value).toISOString().slice(0,10) : 'never';
  }
  return out;
})()`);
hub.close();
const today = new Date().toISOString().slice(0, 10);
const sentToday = Object.entries(api).filter(([, d]) => d === today);
console.log('SENT_TODAY (must be empty):', JSON.stringify(sentToday));

// 2) every widget composer holds a draft starting with "Hey "
const frames = (await j('/json/list')).filter(t => t.type === 'iframe' && /widget-light\/conversations/.test(t.url || ''));
let withDraft = 0; const empty = [];
for (const f of frames) {
  try {
    const c = await cdp(f.webSocketDebuggerUrl);
    const v = await evalIn(c, `(() => {
      const el = document.querySelector('[contenteditable="true"]');
      const name = (document.body.innerText.split('\\n').find(l => l.trim()) || '').slice(0, 30);
      return { text: el ? (el.textContent || '').trim().slice(0, 70) : 'NOFIELD', name };
    })()`);
    c.close();
    if (v.text.startsWith('Hey ')) withDraft++; else empty.push({ url: f.url.slice(40, 80), v });
  } catch { empty.push({ url: f.url.slice(40, 80), v: 'attach failed' }); }
}
console.log('WIDGETS:', frames.length, 'WITH_DRAFT:', withDraft, 'EMPTY_OR_ODD:', JSON.stringify(empty));

