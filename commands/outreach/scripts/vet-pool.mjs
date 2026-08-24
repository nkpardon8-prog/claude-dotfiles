// Full re-vet of the remaining pool + rank for batch selection.
const BASE = 'http://127.0.0.1:9222';
const ids = JSON.parse(process.argv[2] || '[]');
const j = async p => (await fetch(BASE + p)).json();
function cdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0; const pending = new Map();
    ws.onopen = () => resolve({
      call: (m, p = {}) => new Promise((res, rej) => { const mid = ++id; pending.set(mid, { res, rej }); ws.send(JSON.stringify({ id: mid, method: m, params: p })); setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); rej(new Error('timeout')); } }, 180000); }),
      close: () => { try { ws.close(); } catch {} }
    });
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } };
    ws.onerror = () => reject(new Error('ws error'));
  });
}
const tabs = (await j('/json/list')).filter(t => t.type === 'page' && (t.url || '').includes('app.hubspot.com'));
if (!tabs.length) { console.log(JSON.stringify({ err: 'no hubspot tab open' })); process.exit(1); }
const hub = await cdp(tabs[0].webSocketDebuggerUrl);
const r = await hub.call('Runtime.evaluate', { expression: `(async () => {
  const csrf = (document.cookie.match(/hubspotapi-csrf=([^;]+)/)||[])[1];
  if (!csrf) return { err: 'no csrf cookie' };
  const H = { 'X-HubSpot-CSRF-hubspotapi': csrf };
  const ids = ${JSON.stringify(ids)};
  const now = Date.now(), DAY = 86400000;
  const today = new Date().toISOString().slice(0,10);
  const clean = [], skipped = [];
  const queue = [...ids];
  const strip = s => String(s||'').replace(/<[^>]+>/g,' ').replace(/\\s+/g,' ').trim();
  const one = async (id) => {
    try {
      const [pr, dr, er] = await Promise.all([
        fetch('https://app.hubspot.com/api/contacts/v1/contact/vid/' + id + '/profile?portalId=44031266', { credentials:'include', headers:H }),
        fetch('https://app.hubspot.com/api/crm-associations/v1/associations/' + id + '/HUBSPOT_DEFINED/4?portalId=44031266&limit=3', { credentials:'include', headers:H }),
        fetch('https://app.hubspot.com/api/engagements/v1/engagements/associated/contact/' + id + '/paged?limit=40&portalId=44031266', { credentials:'include', headers:H })
      ]);
      if (!pr.ok) { skipped.push(id + ':HTTP' + pr.status); return; }
      const p = (await pr.json()).properties || {};
      const deals = dr.ok ? (await dr.json()).results.length : -1;
      const eng = er.ok ? ((await er.json()).results || []) : [];
      const g = k => p[k] ? String(p[k].value) : '';
      const lc = +g('last_contacted_date') || 0;
      const smsDay = +g('last_sms_sent_date') ? new Date(+g('last_sms_sent_date')).toISOString().slice(0,10) : '';
      // future demo/meeting already booked -> never re-engage into a duplicate ask
      const meetings = eng.filter(e => /MEETING/i.test(e.engagement.type));
      const futureMeeting = meetings.find(m => (m.metadata?.startTime || 0) > now);
      // most recent note, always surfaced as context per standing instruction
      const notes = eng.filter(e => /NOTE/i.test(e.engagement.type)).sort((a,b)=>b.engagement.timestamp-a.engagement.timestamp);
      const noteTxt = notes[0] ? strip(notes[0].metadata?.body).slice(0,200) : '';
      const probs = [];
      if (deals !== 0) probs.push(deals > 0 ? 'DEAL' : 'DEALCHECK');
      if (!(g('hs_calculated_phone_number') || g('phone') || g('mobilephone'))) probs.push('NOPHONE');
      if (/out|unsub/i.test(g('opt_in_status'))) probs.push('OPTOUT:' + g('opt_in_status'));
      if (/dnc|do.?not.?contact|unqual/i.test(g('hs_lead_status'))) probs.push('LS:' + g('hs_lead_status'));
      if (g('hs_v2_date_entered_customer')) probs.push('CUSTOMER');
      if (smsDay === today) probs.push('SMS_TODAY');
      if (lc && (now - lc) < 30*DAY) probs.push('CONTACTED_' + Math.round((now-lc)/DAY) + 'd');
      if (/fail|undeliver/i.test(g('last_sms_sent_status'))) probs.push('DEADNUMBER:' + g('last_sms_sent_status'));
      if (futureMeeting) probs.push('FUTURE_DEMO:' + new Date(futureMeeting.metadata.startTime).toISOString().slice(0,10));
      const fn = g('firstname').trim();
      if (!fn || fn.length < 2 || /^(.)\\1+$/i.test(fn)) probs.push('JUNKNAME:' + (fn || 'empty'));
      if (probs.length) { skipped.push(id + ':' + (g('firstname')||'?') + ':' + probs.join('+')); return; }
      clean.push({
        id, fn: g('firstname'), ln: g('lastname'), st: g('state'), ct: g('city'),
        lcs: g('lifecyclestage').replace('marketingqualifiedlead','MQL').replace('salesqualifiedlead','SQL'),
        es: g('engagement_status'),
        lcDays: lc ? Math.round((now-lc)/DAY) : 9999,
        conv: g('first_conversion_event_name').slice(0,40),
        note: noteTxt
      });
    } catch (e) { skipped.push(id + ':EX:' + String(e.message).slice(0,40)); }
  };
  const workers = Array.from({length:6}, async () => { while (queue.length) await one(queue.shift()); });
  await Promise.all(workers);
  return { cleanCount: clean.length, skippedCount: skipped.length, skipped, clean };
})()`, returnByValue: true, awaitPromise: true });
hub.close();
const v = r.result.value;
if (v.err) { console.log(JSON.stringify(v)); process.exit(1); }
// rank: engagement Active > Inactive > Unresponsive, SQL > MQL, most recent contact first
const eRank = e => ({ 'Active':0, 'Inactive':1, 'Unresponsive':2 }[e] ?? 3);
v.clean.sort((a,b) => eRank(a.es)-eRank(b.es) || (a.lcs==='SQL'?0:1)-(b.lcs==='SQL'?0:1) || a.lcDays-b.lcDays);
const fs = await import('fs');
const os = await import('os');
const path = await import('path');
const dir = path.join(os.tmpdir(), 'outreach-pool') + path.sep;
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + 'pool-vetted.json', JSON.stringify(v.clean, null, 1));
fs.writeFileSync(dir + 'pool-skipped.txt', v.skipped.join('\n'));
console.log('CLEAN', v.cleanCount, 'SKIPPED', v.skippedCount, '-> written to', dir);
console.log('SKIP REASONS:', JSON.stringify(v.skipped.slice(0, 40)));
console.log('TOP 25:', JSON.stringify(v.clean.slice(0,25).map(c => [c.id,c.fn,c.ln,c.st,c.ct,c.lcs,c.es,c.lcDays+'d',c.note?('NOTE:'+c.note):''].join('|'))));
