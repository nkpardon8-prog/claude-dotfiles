// Re-vet batch-2 picks right before drafting: deals still 0, opt_in ok, no SMS today, phone present.
const BASE = 'http://127.0.0.1:9222';
const ids = JSON.parse(process.argv[2] || '[]');
const j = async p => (await fetch(BASE + p)).json();
function cdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0; const pending = new Map();
    ws.onopen = () => resolve({
      call: (m, p = {}) => new Promise((res, rej) => { const mid = ++id; pending.set(mid, { res, rej }); ws.send(JSON.stringify({ id: mid, method: m, params: p })); setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); rej(new Error('timeout')); } }, 60000); }),
      close: () => { try { ws.close(); } catch {} }
    });
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } };
    ws.onerror = () => reject(new Error('ws error'));
  });
}
const tabs = (await j('/json/list')).filter(t => t.type === 'page' && (t.url || '').includes('app.hubspot.com'));
const hub = await cdp(tabs[0].webSocketDebuggerUrl);
const r = await hub.call('Runtime.evaluate', { expression: `(async () => {
  const csrf = (document.cookie.match(/hubspotapi-csrf=([^;]+)/)||[])[1];
  const H = { 'X-HubSpot-CSRF-hubspotapi': csrf };
  const today = new Date().toISOString().slice(0,10);
  const strip = s => String(s||'').replace(/<[^>]+>/g,' ').replace(/\\s+/g,' ').trim();
  const bad = []; const ok = []; const notes = {};
  for (const id of ${JSON.stringify(ids)}) {
    const [pr, dr, er] = await Promise.all([
      fetch('https://app.hubspot.com/api/contacts/v1/contact/vid/' + id + '/profile?portalId=44031266', { credentials:'include', headers:H }),
      fetch('https://app.hubspot.com/api/crm-associations/v1/associations/' + id + '/HUBSPOT_DEFINED/4?portalId=44031266&limit=3', { credentials:'include', headers:H }),
      fetch('https://app.hubspot.com/api/engagements/v1/engagements/associated/contact/' + id + '/paged?limit=40&portalId=44031266', { credentials:'include', headers:H })
    ]);
    const p = (await pr.json()).properties || {};
    const deals = (await dr.json()).results.length;
    const eng = er.ok ? ((await er.json()).results || []) : [];
    const g = k => p[k] ? String(p[k].value) : '';
    const smsDay = +g('last_sms_sent_date') ? new Date(+g('last_sms_sent_date')).toISOString().slice(0,10) : '';
    const meetings = eng.filter(e => /MEETING/i.test(e.engagement.type));
    const futureMeeting = meetings.find(m => (m.metadata?.startTime || 0) > Date.now());
    const noteList = eng.filter(e => /NOTE/i.test(e.engagement.type)).sort((a,b)=>b.engagement.timestamp-a.engagement.timestamp);
    if (noteList[0]) notes[id] = strip(noteList[0].metadata?.body).slice(0,200);
    const problems = [];
    if (deals > 0) problems.push('DEAL');
    if (!(g('hs_calculated_phone_number') || g('phone') || g('mobilephone'))) problems.push('NOPHONE');
    if (/out|unsub/i.test(g('opt_in_status'))) problems.push('OPT:' + g('opt_in_status'));
    if (/dnc|unqual/i.test(g('hs_lead_status'))) problems.push('LS:' + g('hs_lead_status'));
    if (smsDay === today) problems.push('SMS_TODAY');
    if (/fail|undeliver/i.test(g('last_sms_sent_status'))) problems.push('DEADNUMBER:' + g('last_sms_sent_status'));
    const lc2 = +g('last_contacted_date') || 0;
    if (lc2 && (Date.now() - lc2) < 30*86400000) problems.push('CONTACTED_' + Math.round((Date.now()-lc2)/86400000) + 'd');
    if (g('hs_v2_date_entered_customer')) problems.push('CUSTOMER');
    if (futureMeeting) problems.push('FUTURE_DEMO:' + new Date(futureMeeting.metadata.startTime).toISOString().slice(0,10));
    problems.length ? bad.push(id + ':' + g('firstname') + ':' + problems.join('+')) : ok.push(id);
  }
  return { okCount: ok.length, bad, notes };
})()`, returnByValue: true, awaitPromise: true });
hub.close();
console.log(JSON.stringify(r.result.value));
