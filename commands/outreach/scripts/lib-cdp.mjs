// Shared raw-CDP helpers. Node 24+ (built-in WebSocket). No deps.
// Every other script in this folder imports from here.
export const BASE = 'http://127.0.0.1:9222';
export const j = async p => (await fetch(BASE + p)).json();
export const sleep = ms => new Promise(r => setTimeout(r, ms));

export function cdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let i = 0; const pend = new Map();
    ws.onopen = () => resolve({
      call: (m, p = {}) => new Promise((res, rej) => {
        const id = ++i; pend.set(id, { res, rej });
        ws.send(JSON.stringify({ id, method: m, params: p }));
        setTimeout(() => { if (pend.has(id)) { pend.delete(id); rej(new Error('timeout ' + m)); } }, 240000);
      }),
      close: () => { try { ws.close(); } catch {} }
    });
    ws.onmessage = e => {
      const m = JSON.parse(e.data);
      if (m.id && pend.has(m.id)) { const { res, rej } = pend.get(m.id); pend.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
    };
    ws.onerror = () => reject(new Error('ws error'));
  });
}

export const ev = async (c, expression) => {
  const r = await c.call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error('eval: ' + (r.exceptionDetails.exception?.description || '').slice(0, 160));
  return r.result.value;
};

// Grab any logged-in HubSpot page target to run authenticated fetches from.
export const hubTab = async () => {
  const tabs = (await j('/json/list')).filter(t => t.type === 'page' && (t.url || '').includes('app.hubspot.com'));
  if (!tabs.length) throw new Error('no logged-in HubSpot tab open');
  return cdp(tabs[0].webSocketDebuggerUrl);
};
