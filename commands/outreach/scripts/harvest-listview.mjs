// Harvest every contact from a saved HubSpot list view (virtualized + paginated).
// usage: node harvest-listview.mjs <viewId> [outFile]
// Writes {id: "Full Name"} JSON. Read-only.
import {BASE,j,sleep,cdp,ev} from './lib-cdp.mjs';
const viewId=process.argv[2];
const out=process.argv[3]||'listview.json';
if(!viewId){console.error('need a viewId');process.exit(1)}
const URL=`https://app.hubspot.com/contacts/44031266/objects/0-1/views/${viewId}/list`;
const t=await (await fetch(BASE+'/json/new?'+encodeURIComponent(URL),{method:'PUT'})).json(); // NOTE: /json/new requires PUT
await sleep(14000);
const p=await cdp(t.webSocketDebuggerUrl);
const GRAB=`(()=>{const links=[...document.querySelectorAll('a[href*="/contact/"],a[href*="/record/0-1/"]')];
 const o={};links.forEach(a=>{const m=(a.getAttribute('href')||'').match(/(?:contact|0-1)\\/(\\d+)/);
 if(m){const n=(a.textContent||'').trim();if(n&&n.length<60)o[m[1]]=n}});return o})()`;
const SCROLL=`(()=>{const sc=[...document.querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+200&&e.clientHeight>250);
 const el=sc.sort((a,b)=>b.scrollHeight-a.scrollHeight)[0]||document.scrollingElement;
 el.scrollTop=Math.min(el.scrollTop+900,el.scrollHeight);return 1})()`;
const TOP=`(()=>{const sc=[...document.querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+200&&e.clientHeight>250);
 const el=sc.sort((a,b)=>b.scrollHeight-a.scrollHeight)[0]||document.scrollingElement;el.scrollTop=0;return 1})()`;
const all={};
for(let page=0;page<12;page++){
  let stagnant=0;
  for(let i=0;i<40&&stagnant<4;i++){
    const before=Object.keys(all).length;
    Object.assign(all,await ev(p,GRAB));
    stagnant = Object.keys(all).length===before ? stagnant+1 : 0;
    await ev(p,SCROLL); await sleep(1400);
  }
  const nav=await ev(p,`(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()==='Next');
   if(!b||b.disabled||b.getAttribute('aria-disabled')==='true')return 'end'; b.click(); return 'next'})()`);
  console.log('after page',page+1,'->',Object.keys(all).length);
  if(nav==='end')break;
  await sleep(7000); await ev(p,TOP);
}
const fs=await import('fs');
fs.writeFileSync(out,JSON.stringify(all,null,1));
console.log('TOTAL:',Object.keys(all).length,'->',out);
p.close();
