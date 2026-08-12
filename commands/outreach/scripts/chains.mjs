// Read each contact's recent SMS/call/note history so drafts can be tailored.
// usage: node chains.mjs '<json array of contact ids>' [outFile]
// READ-ONLY. Prints a REPLIED / NO REPLY digest and writes the raw chains to JSON.
//
// Inbound vs outbound: HubSpot stores the SMS body prefixed with "<b>INBOUND</b>" or
// "<b>OUTBOUND</b>". That prefix is the ONLY reliable direction signal.
import { j, cdp, ev, hubTab } from './lib-cdp.mjs';

const ids = JSON.parse(process.argv[2] || '[]');
const out = process.argv[3] || 'chains.json';
if (!ids.length) { console.error('need contact ids'); process.exit(1); }

const hub = await hubTab();
const res = await ev(hub, `(async()=>{
 const csrf=(document.cookie.match(/hubspotapi-csrf=([^;]+)/)||[])[1];
 if(!csrf) return {err:'no csrf cookie'};
 const H={'X-HubSpot-CSRF-hubspotapi':csrf};
 const strip=s=>String(s||'').replace(/<[^>]+>/g,' ').replace(/\\s+/g,' ').trim();
 const clean=b=>strip(b).replace(/^(INBOUND|OUTBOUND)\\s*/,'').split(/---- Sent (from|to):/)[0].trim();
 const res={}; const q=[...${JSON.stringify(ids)}];
 const one=async id=>{
  try{
   const r=await fetch('https://app.hubspot.com/api/engagements/v1/engagements/associated/contact/'+id+'/paged?limit=60&portalId=44031266',{credentials:'include',headers:H});
   if(!r.ok){res[id]={err:r.status};return}
   const items=(await r.json()).results||[];
   const sms=items.filter(e=>/SMS/i.test(e.engagement.type)).map(e=>({
     ts:e.engagement.timestamp,
     dir:/INBOUND/i.test(String(e.metadata?.body||''))?'IN':'OUT',
     txt:clean(e.metadata?.body).slice(0,200)
   })).sort((a,b)=>b.ts-a.ts);
   const calls=items.filter(e=>/CALL/i.test(e.engagement.type)).map(e=>({ts:e.engagement.timestamp,txt:strip(e.metadata?.body).slice(0,240)})).sort((a,b)=>b.ts-a.ts);
   const notes=items.filter(e=>/NOTE/i.test(e.engagement.type)).map(e=>({ts:e.engagement.timestamp,txt:strip(e.metadata?.body).slice(0,200)})).sort((a,b)=>b.ts-a.ts);
   res[id]={everIn:sms.some(s=>s.dir==='IN'), smsCount:sms.length, last3:sms.slice(0,3),
            lastIn:sms.filter(s=>s.dir==='IN')[0]||null, call:calls[0]?calls[0].txt:'', note:notes[0]?notes[0].txt:''};
  }catch(e){res[id]={err:String(e.message).slice(0,40)}}
 };
 await Promise.all(Array.from({length:5},async()=>{while(q.length)await one(q.shift())}));
 return res;})()`);
hub.close();
if (res.err) { console.error(res.err); process.exit(1); }

const fs = await import('fs');
fs.writeFileSync(out, JSON.stringify(res, null, 1));

// Flag likely hard stops so they are never drafted. Review by eye; this is a hint, not a gate.
const STOP = /\b(not interested|no thanks|wrong number|stop|unsubscribe|can'?t afford|cannot afford|too expensive|already bought|not looking|fuck off|f\*ck off|asshole|idiot|never (reached out|contacted|texted) (you|me)|don'?t (ever )?(text|contact|call|message) (this number|me) again|leave me alone|piss off)\b/i;
const rep = [], quiet = [], stops = [];
for (const id of ids) {
  const v = res[id] || {};
  if (v.err) { quiet.push(`${id} ERR${v.err}`); continue; }
  if (v.everIn) {
    const t = v.lastIn?.txt || '';
    (STOP.test(t) ? stops : rep).push({ id, in: t.slice(0, 160), note: (v.note || '').slice(0, 90), call: (v.call || '').slice(0, 110) });
  } else quiet.push(`${id} (sms:${v.smsCount}${v.note ? ' NOTE:' + v.note.slice(0, 60) : ''})`);
}
console.log(`=== LIKELY HARD STOPS (${stops.length}) — do NOT draft without a human look ===`);
stops.forEach(r => console.log(` ${r.id}\n   IN: ${r.in}`));
console.log(`\n=== REPLIED, tailorable (${rep.length}) ===`);
rep.forEach(r => console.log(` ${r.id}\n   IN: ${r.in}${r.note ? '\n   NOTE: ' + r.note : ''}${r.call ? '\n   CALL: ' + r.call : ''}`));
console.log(`\n=== NEVER REPLIED, use template (${quiet.length}) ===`);
quiet.forEach(q => console.log(' ' + q));
