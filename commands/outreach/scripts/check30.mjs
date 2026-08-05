const BASE='http://127.0.0.1:9222';
const ids=JSON.parse(process.argv[2]||'[]');
const j=async p=>(await fetch(BASE+p)).json();
function cdp(w){return new Promise((res,rej)=>{const ws=new WebSocket(w);let i=0;const pend=new Map();
ws.onopen=()=>res({call:(m,p={})=>new Promise((r2,j2)=>{const id=++i;pend.set(id,{r2,j2});ws.send(JSON.stringify({id,method:m,params:p}));setTimeout(()=>{if(pend.has(id)){pend.delete(id);j2(new Error('timeout'))}},180000)}),close:()=>{try{ws.close()}catch{}}});
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pend.has(m.id)){const{r2,j2}=pend.get(m.id);pend.delete(m.id);m.error?j2(new Error(m.error.message)):r2(m.result)}};
ws.onerror=()=>rej(new Error('ws'))})}
const tabs=(await j('/json/list')).filter(t=>t.type==='page'&&(t.url||'').includes('app.hubspot.com'));
const hub=await cdp(tabs[0].webSocketDebuggerUrl);
const r=await hub.call('Runtime.evaluate',{expression:`(async()=>{
 const csrf=(document.cookie.match(/hubspotapi-csrf=([^;]+)/)||[])[1];
 const H={'X-HubSpot-CSRF-hubspotapi':csrf};const now=Date.now(),DAY=86400000;
 const rows=[];
 for(const id of ${JSON.stringify(ids)}){
  const r=await fetch('https://app.hubspot.com/api/contacts/v1/contact/vid/'+id+'/profile?portalId=44031266',{credentials:'include',headers:H});
  const p=(await r.json()).properties||{};const g=k=>p[k]?String(p[k].value):'';
  const lc=+g('last_contacted_date')||0, sms=+g('last_sms_sent_date')||0;
  const newest=Math.max(lc,sms);
  rows.push({id,fn:g('firstname'),lcDays:lc?Math.round((now-lc)/DAY):null,smsDays:sms?Math.round((now-sms)/DAY):null,newestDays:newest?Math.round((now-newest)/DAY):null});
 }
 return rows;})()`,returnByValue:true,awaitPromise:true});
hub.close();
const rows=r.result.value;
const viol=rows.filter(x=>x.newestDays!==null&&x.newestDays<30);
console.log('MIN days since any contact:',Math.min(...rows.map(x=>x.newestDays===null?9999:x.newestDays)));
console.log('UNDER-30 VIOLATIONS:',JSON.stringify(viol));
console.log(rows.map(x=>`${x.fn}(${x.id}) lastContact=${x.lcDays}d lastSMS=${x.smsDays}d`).join('\n'));
