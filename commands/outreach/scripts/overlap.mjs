// Overlap guard: never draft the same person twice, never re-draft a hard stop.
//
//   node overlap.mjs '<json ids>'                          -> filter, print safe ids
//   node overlap.mjs --record '<json ids>' "<label>"        -> mark as drafted
//   node overlap.mjs --record '<json ids>' --never "<why>"  -> mark as never-contact
//   (add --dir <path> to any of the above to point at a different ledger)
//
// Ledger: <dir>/outreach-ledger.json  {drafted:{id:label}, never:{id:reason}}
// Writes are merge-only: it loads, adds, and writes back. It never drops existing keys.
import fs from 'fs';
import os from 'os';
import path from 'path';

const argv = process.argv.slice(2);
const flag = name => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : null; };
const has = name => argv.includes(name);

const dir = flag('--dir') || path.join(os.homedir(), '.claude');
const LEDGER = path.join(dir, 'outreach-ledger.json');

const load = () => {
  try {
    const d = JSON.parse(fs.readFileSync(LEDGER, 'utf8'));
    return { drafted: d.drafted || {}, never: d.never || {} };
  } catch { return { drafted: {}, never: {} }; }
};
const save = led => {
  fs.mkdirSync(path.dirname(LEDGER), { recursive: true });
  fs.writeFileSync(LEDGER, JSON.stringify(led, null, 1));
};

// positional ids = first arg that parses as a JSON array
const idsArg = argv.find(a => { try { return Array.isArray(JSON.parse(a)); } catch { return false; } });
const ids = idsArg ? JSON.parse(idsArg).map(String) : [];

if (has('--record')) {
  if (!ids.length) { console.error('--record needs a JSON array of ids'); process.exit(1); }
  const led = load();
  const before = { d: Object.keys(led.drafted).length, n: Object.keys(led.never).length };
  const asNever = has('--never');
  const value = asNever ? (flag('--never') || 'no reason given')
                        : (argv.filter(a => a !== '--record' && a !== idsArg && a !== '--dir' && a !== dir)[0]
                           || new Date().toISOString().slice(0, 10));
  ids.forEach(id => { led[asNever ? 'never' : 'drafted'][id] = value; });
  save(led);
  const after = load();
  console.log(`recorded ${ids.length} as ${asNever ? 'NEVER' : 'drafted'} ("${value}") -> ${LEDGER}`);
  console.log(`  drafted ${before.d} -> ${Object.keys(after.drafted).length} | never ${before.n} -> ${Object.keys(after.never).length}`);
  process.exit(0);
}

if (!ids.length) { console.error("usage: overlap.mjs '<json ids>' [--record ...]"); process.exit(1); }
const led = load();
const dupes = ids.filter(id => led.drafted[id]);
const stops = ids.filter(id => led.never[id]);
const safe = ids.filter(id => !led.drafted[id] && !led.never[id]);
console.log(JSON.stringify({
  ledger: LEDGER,
  candidates: ids.length, safe: safe.length,
  alreadyDrafted: dupes.map(id => id + ':' + led.drafted[id]),
  neverContact: stops.map(id => id + ':' + led.never[id]),
  safeIds: safe
}, null, 1));
