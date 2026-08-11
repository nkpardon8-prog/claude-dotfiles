// Overlap guard: never draft the same person twice, never re-draft a hard stop.
// usage: node overlap.mjs '<json candidate ids>' [ledgerDir]
// Prints the ids that are SAFE to draft, and what was filtered and why.
//
// Ledger lives at <ledgerDir>/outreach-ledger.json (default ~/.claude/outreach-ledger.json):
//   { "drafted": {id: "YYYY-MM-DD batch"}, "never": {id: "reason"} }
// Update it after every batch with `node overlap.mjs --record ...` (see bottom).
import fs from 'fs';
import os from 'os';
import path from 'path';

const dir = process.argv[3] || path.join(os.homedir(), '.claude');
const LEDGER = path.join(dir, 'outreach-ledger.json');
const load = () => { try { return JSON.parse(fs.readFileSync(LEDGER, 'utf8')); } catch { return { drafted: {}, never: {} }; } };

if (process.argv[2] === '--record') {
  // node overlap.mjs --record '<json ids>' <label> [--never "reason"]
  const led = load();
  const ids = JSON.parse(process.argv[3] || '[]');
  const label = process.argv[4] || new Date().toISOString().slice(0, 10);
  const neverIdx = process.argv.indexOf('--never');
  const target = neverIdx > -1 ? 'never' : 'drafted';
  const val = neverIdx > -1 ? process.argv[neverIdx + 1] : label;
  ids.forEach(id => { led[target][String(id)] = val; });
  fs.mkdirSync(path.dirname(LEDGER), { recursive: true });
  fs.writeFileSync(LEDGER, JSON.stringify(led, null, 1));
  console.log(`recorded ${ids.length} into ${target}; ledger now drafted:${Object.keys(led.drafted).length} never:${Object.keys(led.never).length}`);
  process.exit(0);
}

const led = load();
const cand = JSON.parse(process.argv[2] || '[]').map(String);
const dupes = cand.filter(id => led.drafted[id]);
const stops = cand.filter(id => led.never[id]);
const safe = cand.filter(id => !led.drafted[id] && !led.never[id]);
console.log(JSON.stringify({
  candidates: cand.length, safe: safe.length,
  alreadyDrafted: dupes.map(id => id + ':' + led.drafted[id]),
  neverContact: stops.map(id => id + ':' + led.never[id]),
  safeIds: safe
}, null, 1));
