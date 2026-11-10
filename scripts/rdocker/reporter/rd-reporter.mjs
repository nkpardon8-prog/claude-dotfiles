#!/usr/bin/env node
// rd-reporter: pushes this machine's live stats to the fleet dashboard (Cloudflare Worker +
// Fleet Durable Object) over ONE WebSocket. Node 22+, zero dependencies, no sudo.
//
// Config: ~/.config/rdocker/reporter.json (mode 0600, refused otherwise), or $RD_REPORTER_CONFIG:
//   { "name": "hp", "url": "wss://<worker host>/ingest", "key": "<MACHINE_KEY_HP secret>",
//     "role": "home + worker",            // optional label shown on the dashboard
//     "pingPeers": true,                   // optional: tailscale ping online peers while viewed
//     "speed": 1.0,                        // optional: else fleet.json `speed` for this name, else 1
//     "rrRoot": "~/rr",                    // optional: rrun server root (slots, runs.log)
//     "notify": true }                     // optional: show fleet alerts on this machine (agent Macs)
// Protocol (dashboard/shared/protocol.ts is the typed source of truth):
//   -> {t:'hello', v:1, name, ts, nonce, sig[, notify:true]}  sig = hex HMAC-SHA256(key, "rd-ingest-v1|name|ts|nonce")
//   <- {t:'mode', ms}                           60000 when nobody watches, 5000 while a browser is open
//   -> {t:'f', ...frame}                        on wall-clock-aligned ticks of `ms`
//   <- {t:'alert', events:[{kind, alert}]}      notify:true only; once per fire / resolve (see notify below)
// CPU is sampled every 5 s locally; each frame carries the samples since the previous one (hist).
//
// Linux: /proc, /sys/class/hwmon, statfs; WSL: + Windows host RAM via powershell.exe (optional).
// macOS: vm_stat, sysctl, memory_pressure; temperature needs root there, so it is reported as null.
// rrun: running jobs from <rrRoot>/slots/*.who, finished runs from <rrRoot>/log/runs.log.
// Install: copy this file to ~/.local/share/rdocker/reporter/ and load units/rd-reporter.service
// (systemd --user, Linux) or units/com.rdocker.reporter.plist (launchd, macOS).
// Flags: --once (print one frame as JSON, no network), --config <path>, --version.
import { execFile } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const VERSION = '1.0.0';
const INGEST_V = 1;
const SAMPLE_MS = 5_000;
const SLOW_MS = 60_000;
const TS_EVERY_MS = 30_000;
const PING_EVERY_MS = 60_000;
const SLOW_CACHE_MS = 60_000;

// ---------------------------------------------------------------------------- parsers (pure)

/** /proc/stat -> { all: {idle,total}, cores: [{idle,total}] } */
export function parseProcStat(text) {
  const out = { all: null, cores: [] };
  for (const line of text.split('\n')) {
    const m = /^cpu(\d*)\s+(.*)$/.exec(line);
    if (!m) continue;
    const v = m[2].trim().split(/\s+/).map(Number);
    // user nice system idle iowait irq softirq steal (guest* are already in user/nice)
    const idle = (v[3] ?? 0) + (v[4] ?? 0);
    const total = v.slice(0, 8).reduce((a, b) => a + (Number.isFinite(b) ? b : 0), 0);
    if (m[1] === '') out.all = { idle, total };
    else out.cores[Number(m[1])] = { idle, total };
  }
  return out;
}

/** Busy % between two {idle,total} samples. */
export function busyPct(prev, cur) {
  if (!prev || !cur) return 0;
  const dt = cur.total - prev.total;
  if (dt <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((1000 * (dt - (cur.idle - prev.idle))) / dt) / 10));
}

/** os.cpus() -> per-core {idle,total} (macOS path; Linux uses /proc/stat for iowait/steal). */
export function fromOsCpus(cpus) {
  const cores = cpus.map((c) => {
    const t = c.times;
    return { idle: t.idle, total: t.user + t.nice + t.sys + t.idle + t.irq };
  });
  const all = cores.reduce((a, c) => ({ idle: a.idle + c.idle, total: a.total + c.total }), { idle: 0, total: 0 });
  return { all, cores };
}

/** /proc/meminfo -> bytes */
export function parseMeminfo(text) {
  const kv = {};
  for (const line of text.split('\n')) {
    const m = /^(\w+(?:\(\w+\))?):\s+(\d+)(?:\s+kB)?/.exec(line);
    if (m) kv[m[1]] = Number(m[2]) * 1024;
  }
  const total = kv.MemTotal ?? 0;
  const avail = kv.MemAvailable ?? (kv.MemFree ?? 0) + (kv.Cached ?? 0) + (kv.Buffers ?? 0);
  return {
    mem: { total, used: Math.max(0, total - avail), avail },
    swap: { total: kv.SwapTotal ?? 0, used: Math.max(0, (kv.SwapTotal ?? 0) - (kv.SwapFree ?? 0)) },
  };
}

export function parseLoadavg(text) {
  const p = text.trim().split(/\s+/).map(Number);
  return [p[0] || 0, p[1] || 0, p[2] || 0];
}

/** vm_stat -> { pageSize, pages: {free, active, ...} } (keys lower-cased, spaces -> _) */
export function parseVmStat(text) {
  const ps = /page size of (\d+) bytes/.exec(text);
  const pages = {};
  for (const line of text.split('\n')) {
    const m = /^"?([^":]+)"?:\s+(\d+)\.?$/.exec(line.trim());
    if (m) pages[m[1].toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/_$/, '')] = Number(m[2]);
  }
  return { pageSize: ps ? Number(ps[1]) : 4096, pages };
}

/** macOS "Memory Used" like Activity Monitor: app (anonymous - purgeable) + wired + compressed. */
export function macMem(vm, memTotal) {
  const p = vm.pages;
  const anon = (p.anonymous_pages ?? p.pages_active ?? 0) - (p.pages_purgeable ?? 0);
  const used = Math.min(memTotal, Math.max(0, (anon + (p.pages_wired_down ?? 0) + (p.pages_occupied_by_compressor ?? 0)) * vm.pageSize));
  return { total: memTotal, used, avail: Math.max(0, memTotal - used) };
}

const UNIT = { K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 };
/** sysctl vm.swapusage: "total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)" */
export function parseSwapusage(text) {
  const g = (k) => {
    const m = new RegExp(`${k} = ([\\d.]+)([KMGT])`).exec(text);
    return m ? Math.round(Number(m[1]) * UNIT[m[2]]) : 0;
  };
  return { total: g('total'), used: g('used') };
}

/** memory_pressure -Q -> free % */
export function parsePressure(text) {
  const m = /free percentage:\s*(\d+)%/i.exec(text);
  return m ? Number(m[1]) : null;
}

export function parseCpuinfo(text) {
  const m = /^model name\s*:\s*(.+)$/m.exec(text) ?? /^Hardware\s*:\s*(.+)$/m.exec(text);
  const cores = new Set();
  let phys = 0;
  for (const block of text.split(/\n\s*\n/)) {
    const pid = /^physical id\s*:\s*(\d+)/m.exec(block)?.[1];
    const cid = /^core id\s*:\s*(\d+)/m.exec(block)?.[1];
    if (cid !== undefined) cores.add(`${pid ?? 0}:${cid}`);
    if (/^processor\s*:/m.test(block)) phys++;
  }
  return { model: m ? m[1].trim() : '', cores: cores.size || phys, threads: phys };
}

export function parseOsRelease(text) {
  const m = /^PRETTY_NAME="?([^"\n]+)"?/m.exec(text);
  return m ? m[1] : '';
}

/**
 * hwmon readings [{chip, label, value(°C)}] -> one CPU temperature. Prefers the package /
 * Tctl sensor of a CPU chip; falls back to the hottest CPU-ish reading, then anything.
 */
export function pickTemp(readings) {
  const cpuChips = /^(coretemp|k10temp|zenpower|cpu_thermal|cpu-thermal|soc_thermal|x86_pkg_temp|acpitz|applesmc)$/;
  const valid = readings.filter((r) => Number.isFinite(r.value) && r.value > -40 && r.value < 130);
  const pkg = valid.find((r) => cpuChips.test(r.chip) && /package|tctl|tdie|cpu/i.test(r.label));
  if (pkg) return Math.round(pkg.value * 10) / 10;
  const cpu = valid.filter((r) => cpuChips.test(r.chip));
  const pool = cpu.length ? cpu : valid;
  return pool.length ? Math.round(Math.max(...pool.map((r) => r.value)) * 10) / 10 : null;
}

// ---------------------------------------------------------------------------- leak detection
// Agent hosts (role without "worker") should not run heavy dev work: the routing hook sends it to the
// pool. A "leak" is a dev-tool process burning local CPU anyway. One `ps` per frame; nothing else.
export const LEAK_MIN_CPU_S = 15;
/** ...burned within this window: a slow trickle (an idle server at 1 %) never adds up to a leak. */
export const LEAK_WINDOW_MS = 120_000;
const LEAK_MAX = 10;
const NOT_A_LEAK = /claude|anthropic|codex|runpane|pane\.app|\bmcp\b|-mcp\b|chrome-devtools|google chrome|chromium|safari|firefox|electron|visual studio code|code helper|cursor\.app|tsserver|typingsinstaller|rd-reporter|\brrun\b|rd_run|rd_pool|\bssh\b|rsync|\bgit\b|caffeinate|spotlight|mdworker/i;
// dev servers, app servers and watch modes are allowed to run locally (the user's own tabs need them)
const LOCAL_BY_DESIGN = /(^|\s)(dev|serve|preview|start)(\s|$)|--watch\b|(^|\s)watch(\s|$)|(^|\s)-w(\s|$)|--port\b|--host\b|\b(uvicorn|gunicorn|celery|hypercorn|daphne|runserver|http\.server|serve-static|nodemon|tsx watch)\b|\bflask run\b|\bvite\b(?!.*\b(build|optimize)\b)(?!st)/i;

/** `ps` cumulative CPU time ([DD-][HH:]MM:SS[.ss]) -> seconds. */
export function psTimeS(t) {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(String(t ?? '').trim());
  if (!m) return null;
  return Number(m[1] ?? 0) * 86400 + Number(m[2] ?? 0) * 3600 + Number(m[3]) * 60 + Number(m[4]);
}

/** argv -> leak kind, or null when it is not heavy dev work (or is local by design). */
export function leakKind(args) {
  const a = String(args ?? '');
  if (!a || NOT_A_LEAK.test(a) || LOCAL_BY_DESIGN.test(a)) return null;
  if (/\bvitest\b/.test(a)) return 'vitest';
  if (/\bjest\b/.test(a)) return 'jest';
  if (/(^|[/\s])tsc(\s|$)|typescript\/bin\/tsc|\bvue-tsc\b/.test(a)) return 'tsc';
  if (/\beslint\b|\bbiome\b|\boxlint\b/.test(a)) return 'eslint';
  if (/\bplaywright\b|\bcypress\b/.test(a)) return 'playwright';
  if (/\b(next|vite|webpack|rollup|esbuild|turbo|tsup|rspack|parcel|nx)\b.*\bbuild\b|(^|\s)build(\s|$)/.test(a)) return 'build';
  if (/(^|\/)(cargo|rustc)(\s|$)/.test(a)) return 'cargo';
  if (/(^|\/)go(\s+(build|test|vet|run))/.test(a)) return 'go';
  if (/(^|\/)python[\d.]*(\s|$)|\bpytest\b/.test(a)) return 'python';
  if (/(^|\/)(node|bun|deno)(\s|$)/.test(a)) return 'node';
  if (/(^|\/)(java|gradle|mvn|swift|xcodebuild|ruby)(\s|$)/.test(a)) return 'other';
  return null;
}

/** Secrets out of argv before it leaves the machine. */
export function redactArgs(args) {
  return String(args ?? '')
    .replace(/((?:token|key|secret|password|passwd|auth)\w*)([=: ])\S+/gi, '$1$2***')
    .replace(/[A-Za-z0-9+_-]{32,}={0,2}/g, '***') // tokens; paths keep their '/' so they stay readable
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 160);
}

/**
 * One scan: `ps -eo pid=,time=,args=` text + state -> leaks to report now. Per pid, CPU burned since
 * the last scan accumulates until it reaches LEAK_MIN_CPU_S, then it is reported and reset (works at
 * any frame cadence). The first scan only sets the baseline. A pid seen for the first time after that
 * started since the last scan, so all its CPU counts.
 */
export function scanLeaks(psText, state, nowMs, minCpuS = LEAK_MIN_CPU_S) {
  const seen = new Map();
  const first = !state.prev;
  const out = [];
  for (const line of String(psText ?? '').split('\n')) {
    const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const pid = Number(m[1]);
    const cpu = psTimeS(m[2]);
    if (cpu === null) continue;
    const kind = leakKind(m[3]);
    if (!kind) continue;
    const old = state.prev?.get(pid);
    const delta = first ? 0 : old ? Math.max(0, cpu - old.cpu) : cpu;
    const fresh = !old || nowMs - old.since > LEAK_WINDOW_MS; // window expired below the bar: start over
    const acc = (fresh ? 0 : old.acc) + delta;
    const since = fresh ? nowMs : old.since;
    if (acc >= minCpuS) {
      out.push({ ts: nowMs, pid, kind, cmd: redactArgs(m[3]), cpuS: Math.round(acc * 10) / 10 });
      seen.set(pid, { cpu, acc: 0, since: nowMs });
    } else seen.set(pid, { cpu, acc, since });
  }
  state.prev = seen;
  return out.sort((a, b) => b.cpuS - a.cpuS).slice(0, LEAK_MAX);
}

/** ~/.claude/settings.json text -> is the auto-offload hook wired? */
export const hookState = (settingsText) => (settingsText == null ? 'missing' : /rrun-route/.test(settingsText) ? 'ok' : 'missing');

/** /run/rdocker/power ("<watts> <epoch s>", written by root's rd-power) -> watts, null when missing or stale. */
export function parsePower(text, nowMs, maxAgeS = 30) {
  const m = /^\s*(\d+(?:\.\d+)?)\s+(\d+)\s*$/.exec(text ?? '');
  if (!m) return null;
  const w = Number(m[1]);
  const age = nowMs / 1000 - Number(m[2]);
  return Number.isFinite(w) && w >= 0 && w < 5000 && age >= -60 && age <= maxAgeS ? w : null;
}

/** `tailscale status --json` -> self + peers (relayed = online peer without a direct CurAddr). */
export function parseTailscale(json) {
  const s = typeof json === 'string' ? JSON.parse(json) : json;
  const peers = Object.values(s.Peer ?? {}).map((p) => ({
    host: String(p.HostName ?? ''),
    ip: String((p.TailscaleIPs ?? [])[0] ?? ''),
    os: String(p.OS ?? ''),
    online: p.Online === true,
    relayed: p.Online === true && !p.CurAddr,
    relay: String(p.Relay ?? ''),
    curAddr: String(p.CurAddr ?? ''),
    rttMs: null,
  }));
  return {
    self: { host: String(s.Self?.HostName ?? ''), ips: (s.Self?.TailscaleIPs ?? []).map(String) },
    peers,
  };
}

/** Online peers to ping (phones and tablets included: one 1-packet ping a minute, only while viewed). */
export function pingTargets(peers) {
  return peers.filter((p) => p.online && p.ip).slice(0, 16);
}

/** `tailscale ping -c 1` output -> {rttMs, via} or null */
export function parseTsPing(text) {
  const m = /pong from .* via (.+?) in ([\d.]+)ms/.exec(text);
  return m ? { via: m[1], rttMs: Number(m[2]) } : null;
}

/** "2026-11-09T10:00:00-0800" -> ms epoch */
export function parseLogTime(s) {
  const iso = s.replace(/([+-]\d{2})(\d{2})$/, '$1:$2');
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : 0;
}

/** rr runs.log lines -> runs (format: rr_runner.pl run_log). */
export function parseRunsLog(text) {
  const out = [];
  const re = /^(\S+) repo=(\S+) wt=\S+ sha=\S+ outcome=(.+?) prepare_s=(\S+) cmd_s=(\S+) argv=(.*)$/;
  for (const line of text.split('\n')) {
    const m = re.exec(line);
    if (!m) continue;
    const n = (x) => (x === '-' ? null : Number(x));
    out.push({ ts: parseLogTime(m[1]), repo: m[2], outcome: m[3], prepS: n(m[4]), cmdS: n(m[5]), argv: m[6].slice(0, 160) });
  }
  return out;
}

/** <slot>.who: "<repo_slug> <epoch> <pid> <wt12>" */
export function parseWho(text, slot) {
  const [repo, t, pid] = text.trim().split(/\s+/);
  if (!repo || !t) return null;
  return { slot, repo, since: Number(t) * 1000, pid: Number(pid) || null, cmd: null };
}

/** Redact env-looking argv tokens, like rr_runner.pl redact_argv. */
export function redactArgv(argv) {
  const out = [];
  let val = false;
  for (const a of argv) {
    if (val) {
      out.push('<redacted>');
      val = false;
    } else if (a === '-e' || a === '--env') {
      out.push(a);
      val = true;
    } else if (/^(-*[A-Za-z_][A-Za-z0-9_-]*=)/.test(a)) out.push(a.replace(/^(-*[A-Za-z_][A-Za-z0-9_-]*=).*/s, '$1<redacted>'));
    else out.push(a);
  }
  const s = out.join(' ').replace(/[\x00-\x1f\x7f]/g, ' ');
  return s.length > 120 ? `${s.slice(0, 120)}...` : s;
}

/** Windows host RAM from powershell Win32_OperatingSystem (KB) JSON. */
export function parsePsMem(text) {
  try {
    const o = JSON.parse(text);
    const total = Number(o.TotalVisibleMemorySize) * 1024;
    const free = Number(o.FreePhysicalMemory) * 1024;
    return Number.isFinite(total) && total > 0 ? { total, free } : null;
  } catch {
    return null;
  }
}

/** fleet.json (dotfiles registry) -> this machine's entry, or null. Accepts {machines:[...]} or [...]. */
export function fleetEntry(name, text) {
  if (!text) return null;
  try {
    const j = JSON.parse(text);
    const list = Array.isArray(j) ? j : Array.isArray(j?.machines) ? j.machines : Array.isArray(j?.servers) ? j.servers : [];
    return list.find((m) => m && m.name === name) ?? null;
  } catch {
    return null;
  }
}

export const helloMessage = (name, ts, nonce) => `rd-ingest-v${INGEST_V}|${name}|${ts}|${nonce}`;

export function signHello(name, key, tsS = Math.floor(Date.now() / 1000), nonce = randomBytes(16).toString('hex')) {
  const sig = createHmac('sha256', key).update(helloMessage(name, tsS, nonce)).digest('hex');
  return { t: 'hello', v: INGEST_V, name, ts: tsS, nonce, sig };
}

/** ms until the next wall-clock multiple of `interval` (all reporters tick together). */
export function untilTick(now, interval) {
  const r = interval - (now % interval);
  return r < 50 ? r + interval : r;
}

export function validateConfig(c) {
  const errs = [];
  if (!c || typeof c !== 'object') return ['config is not a JSON object'];
  if (typeof c.name !== 'string' || !/^[a-z0-9][a-z0-9-]{0,31}$/.test(c.name)) errs.push('name: lower-case a-z0-9-, max 32');
  if (typeof c.url !== 'string' || !/^wss?:\/\/[^/]+\/ingest$/.test(c.url)) errs.push('url: wss://<host>/ingest');
  else if (c.url.startsWith('ws://') && !/^ws:\/\/(localhost|127\.0\.0\.1)(:\d+)?\//.test(c.url)) errs.push('url: ws:// only for localhost');
  if (typeof c.key !== 'string' || c.key.length < 32) errs.push('key: at least 32 chars (npm run machine-key)');
  if (c.notify !== undefined && typeof c.notify !== 'boolean') errs.push('notify: true or false');
  return errs;
}

// ---------------------------------------------------------------------------- alerts (notify:true)
// The Fleet DO sends each alert once when it fires and once when it resolves. Locally we still
// cap it: at most one fire notification per alert id per hour (an id is rule:machine[:detail], so a
// flapping machine cannot spam), a resolve only when its fire was shown, and more than
// NOTIFY_SUMMARY_OVER in one message collapse into a single summary notification.
export const NOTIFY_EVERY_MS = 3600_000;
export const NOTIFY_SUMMARY_OVER = 3;

const clock = (ms) => new Date(ms).toTimeString().slice(0, 8);
const minutes = (ms) => `${Math.max(1, Math.round(ms / 60_000))} min`;

/**
 * events + per-id memory -> notifications to show now. `seen` is not mutated: a new Map is returned.
 * seen: Map<id, { fireAt, firedAt, resolveAt }> (fireAt/resolveAt = when we last showed one).
 */
export function planNotifications(events, seen, now) {
  const next = new Map([...seen].filter(([, v]) => now - Math.max(v.fireAt ?? 0, v.resolveAt ?? 0) < 2 * NOTIFY_EVERY_MS));
  const notes = [];
  for (const e of Array.isArray(events) ? events : []) {
    const a = e?.alert;
    if (!a || typeof a.id !== 'string' || typeof a.message !== 'string') continue;
    const rec = next.get(a.id) ?? {};
    if (e.kind === 'fire') {
      if (rec.fireAt !== undefined && now - rec.fireAt < NOTIFY_EVERY_MS) continue;
      next.set(a.id, { ...rec, fireAt: now, firedAt: a.firedAt });
      notes.push({ title: `${a.severity === 'crit' ? 'CRIT' : 'WARN'} ${a.message}`, body: `since ${clock(a.firedAt)} · spine fleet` });
    } else if (e.kind === 'resolve') {
      if (rec.firedAt !== a.firedAt) continue; // we never showed this one firing
      if (rec.resolveAt !== undefined && now - rec.resolveAt < NOTIFY_EVERY_MS) continue;
      next.set(a.id, { ...rec, resolveAt: now });
      notes.push({ title: `OK ${a.message}`, body: `resolved after ${minutes((a.resolvedAt ?? now) - a.firedAt)} · spine fleet` });
    }
  }
  if (notes.length > NOTIFY_SUMMARY_OVER) {
    const body = notes.map((n) => n.title).join('\n');
    return { notes: [{ title: `${notes.length} fleet alerts`, body: body.length > 600 ? `${body.slice(0, 597)}...` : body }], seen: next };
  }
  return { notes, seen: next };
}

/** `runpane` on PATH, else Pane's default shim dir (launchd agents get a minimal PATH). */
export function findRunpane(env = process.env, exists = isExecutable, home = os.homedir()) {
  const dirs = [...String(env.PATH ?? '').split(path.delimiter).filter(Boolean), path.join(home, '.pane', 'bin')];
  for (const d of dirs) {
    const p = path.join(d, 'runpane');
    if (exists(p)) return p;
  }
  return null;
}

function isExecutable(p) {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

/** AppleScript string literal. */
export const appleString = (s) => `"${String(s).replace(/[\\"]/g, (c) => `\\${c}`).replace(/[\r\n]+/g, '; ')}"`;

const runCmd = (cmd, args, timeout = 10_000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 1 << 20 }, (err, stdout) => resolve({ ok: !err, stdout: String(stdout ?? '') }));
  });

/**
 * Show one notification: `runpane notify --ui info` (returns at once; its JSON says `unavailable`
 * when Pane is not running), else osascript on macOS, else the log only. Returns the channel used.
 */
export async function deliverNotification(note, { platform = process.platform, runpane = findRunpane(), run = runCmd, log: say = log } = {}) {
  say(`alert: ${note.title} (${note.body.replace(/\n/g, '; ')})`);
  if (runpane) {
    const r = await run(runpane, ['notify', '--ui', 'info', '--title', note.title.slice(0, 200), '--context', note.body, '--json']);
    let unavailable = !r.ok;
    if (r.ok) {
      try {
        unavailable = 'unavailable' in JSON.parse(r.stdout);
      } catch {
        unavailable = true;
      }
    }
    if (!unavailable) return 'runpane';
  }
  if (platform === 'darwin') {
    const r = await run('osascript', ['-e', `display notification ${appleString(note.body)} with title ${appleString(note.title)}`]);
    if (r.ok) return 'osascript';
  }
  return 'log';
}

/** Per-process notifier: plans with rate limits, delivers one at a time. */
export function createNotifier(deps = {}) {
  let seen = new Map();
  let chain = Promise.resolve();
  return (events, now = Date.now()) => {
    const plan = planNotifications(events, seen, now);
    seen = plan.seen;
    for (const n of plan.notes) chain = chain.then(() => deliverNotification(n, deps)).catch(() => 'log');
    return chain;
  };
}

// ---------------------------------------------------------------------------- collectors

const sh = (cmd, args, timeout = 3000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 4 << 20, env: { ...process.env, LC_ALL: 'C' } }, (err, stdout) => resolve(err ? null : stdout));
  });
const read = (p) => {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return null;
  }
};
const expandHome = (p) => (p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p);

function cached(fn, ttl) {
  let at = 0;
  let val;
  let inflight = null;
  return async (...a) => {
    if (Date.now() - at < ttl) return val;
    inflight ??= Promise.resolve(fn(...a)).then(
      (v) => {
        val = v;
        at = Date.now();
        inflight = null;
        return v;
      },
      () => {
        inflight = null;
        return val;
      },
    );
    return inflight;
  };
}

function diskOf(mount) {
  try {
    const s = fs.statfsSync(mount);
    const total = s.blocks * s.bsize;
    return { mount, total, used: Math.max(0, total - s.bavail * s.bsize) };
  } catch {
    return null;
  }
}

function hwmonReadings(root = '/sys/class/hwmon') {
  const out = [];
  let dirs = [];
  try {
    dirs = fs.readdirSync(root);
  } catch {
    return out;
  }
  for (const d of dirs) {
    const dir = path.join(root, d);
    const chip = (read(path.join(dir, 'name')) ?? '').trim();
    let files = [];
    try {
      files = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const f of files) {
      const m = /^temp(\d+)_input$/.exec(f);
      if (!m) continue;
      const v = Number(read(path.join(dir, f)));
      if (!Number.isFinite(v)) continue;
      out.push({ chip, label: (read(path.join(dir, `temp${m[1]}_label`)) ?? '').trim(), value: v / 1000 });
    }
  }
  return out;
}

function procChildren(pid) {
  const t = read(`/proc/${pid}/task/${pid}/children`);
  return t ? t.trim().split(/\s+/).filter(Boolean).map(Number) : [];
}
const procArgv = (pid) => (read(`/proc/${pid}/cmdline`) ?? '').split('\0').filter(Boolean);
const WRAPPERS = new Set(['perl', 'sh', 'bash', 'dash', 'env', 'setsid', 'timeout', 'nice', 'ionice', 'flock']);

/** Linux: the user command an rr_runner pid is running (first non-wrapper descendant). */
function jobCommand(pid) {
  const queue = [...procChildren(pid)];
  for (let i = 0; i < queue.length && i < 64; i++) {
    const argv = procArgv(queue[i]);
    if (argv.length && !WRAPPERS.has(path.basename(argv[0]))) return redactArgv(argv.map((a, j) => (j === 0 ? path.basename(a) : a)));
    queue.push(...procChildren(queue[i]));
  }
  return null;
}

/** Linux: rr_runner processes that hold no slot = queued; their mean age = wait. */
function runnerQueue(busyPids, uptimeS) {
  let queued = 0;
  let ageSum = 0;
  let dirs = [];
  try {
    dirs = fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d));
  } catch {
    return { queued: 0, waitS: null };
  }
  const hz = 100; // USER_HZ is 100 on every mainstream Linux
  for (const d of dirs) {
    const argv = procArgv(d);
    if (!argv.some((a) => a.endsWith('rr_runner.pl') || a.endsWith('rr_runner'))) continue;
    if (busyPids.has(Number(d))) continue;
    // A runner whose parent is also a runner is a forked helper, not a job.
    const stat = read(`/proc/${d}/stat`) ?? '';
    const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    const ppid = Number(fields[1]);
    if (procArgv(ppid).some((a) => a.endsWith('rr_runner.pl'))) continue;
    queued++;
    ageSum += Math.max(0, uptimeS - Number(fields[19]) / hz);
  }
  return { queued, waitS: queued ? Math.round(ageSum / queued) : null };
}

export class Collector {
  constructor(cfg, platform = process.platform) {
    this.cfg = cfg;
    // agent hosts (Nick's mini, the Air) are watched for heavy work that skipped the pool
    this.agentHost = !/worker/i.test(String(cfg.role ?? '')) && cfg.leaks !== false;
    this.leakState = {};
    this.linux = platform === 'linux';
    this.mac = platform === 'darwin';
    this.rrRoot = expandHome(cfg.rrRoot ?? '~/rr');
    this.prevCpu = null;
    this.hist = [];
    this.runsPos = null; // {ino, size}
    this.peers = [];
    this.selfIps = [];
    this.wsl = this.linux && /microsoft/i.test(read('/proc/sys/kernel/osrelease') ?? '');
    this.tailscaleBin = this.mac && fs.existsSync('/Applications/Tailscale.app/Contents/MacOS/Tailscale') ? '/Applications/Tailscale.app/Contents/MacOS/Tailscale' : 'tailscale';
    this.ts = cached(() => this.readTailscale(), TS_EVERY_MS - 1000);
    this.pings = cached((peers) => this.pingPeers(peers), PING_EVERY_MS - 1000);
    this.hostMem = cached(() => this.readHostMem(), SLOW_CACHE_MS);
    this.pressure = cached(async () => parsePressure((await sh('memory_pressure', ['-Q'])) ?? ''), SLOW_CACHE_MS / 2);
    this.macStatic = cached(async () => ({ memsize: Number((await sh('sysctl', ['-n', 'hw.memsize'])) ?? 0) }), 3600_000);
  }

  cpuSnapshot() {
    if (this.linux) {
      const t = read('/proc/stat');
      if (t) return parseProcStat(t);
    }
    return fromOsCpus(os.cpus());
  }

  /** Called every SAMPLE_MS. */
  sample(now = Date.now()) {
    const cur = this.cpuSnapshot();
    const prev = this.prevCpu;
    this.prevCpu = cur;
    if (!prev) return;
    this.lastCores = cur.cores.map((c, i) => busyPct(prev.cores[i], c));
    this.lastCpu = busyPct(prev.all, cur.all);
    this.hist.push([now, this.lastCpu]);
    if (this.hist.length > 40) this.hist.shift();
  }

  info() {
    const fleet = fleetEntry(this.cfg.name, read(expandHome(this.cfg.fleetFile ?? '~/.claude-dotfiles/scripts/rdocker/fleet.json')));
    const cpus = os.cpus();
    let cpuModel = cpus[0]?.model?.trim() ?? '';
    let cores = cpus.length;
    let distro = `${os.type()} ${os.release()}`;
    if (this.linux) {
      const ci = parseCpuinfo(read('/proc/cpuinfo') ?? '');
      cpuModel = ci.model || cpuModel;
      cores = ci.cores || cores;
      distro = parseOsRelease(read('/etc/os-release') ?? '') || distro;
    }
    if (this.mac) {
      distro = `macOS ${os.release()}`;
      const p = Number(os.availableParallelism?.() ?? cpus.length);
      cores = p;
    }
    return {
      hostname: os.hostname(),
      os: process.platform,
      distro,
      kernel: os.release(),
      cpuModel,
      cores,
      threads: cpus.length,
      memTotal: os.totalmem(),
      wsl: this.wsl,
      role: String(this.cfg.role ?? fleet?.roles?.join(' + ') ?? ''),
      speed: Number.isFinite(this.cfg.speed) ? this.cfg.speed : Number.isFinite(fleet?.speed) ? fleet.speed : 1,
      tsIps: this.selfIps,
      reporter: VERSION,
      hook: this.agentHost ? hookState(read(expandHome(this.cfg.claudeSettings ?? '~/.claude/settings.json'))) : null,
    };
  }

  async readTailscale() {
    const out = await sh(this.tailscaleBin, ['status', '--json'], 4000);
    if (!out) return null;
    try {
      return parseTailscale(out);
    } catch {
      return null;
    }
  }

  async pingPeers(peers) {
    const targets = pingTargets(peers);
    const res = await Promise.all(targets.map((p) => sh(this.tailscaleBin, ['ping', '-c', '1', '--timeout', '2s', p.ip], 4000)));
    const map = new Map();
    targets.forEach((p, i) => {
      const r = parseTsPing(res[i] ?? '');
      if (r) map.set(p.ip, r.rttMs);
    });
    return map;
  }

  async readHostMem() {
    if (!this.wsl) return null;
    const out = await sh('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory | ConvertTo-Json -Compress'], 8000);
    return out ? parsePsMem(out) : null;
  }

  jobs() {
    const dir = path.join(this.rrRoot, 'slots');
    let files = [];
    try {
      files = fs.readdirSync(dir).filter((f) => /^\d+\.who$/.test(f));
    } catch {
      return [];
    }
    const out = [];
    for (const f of files) {
      const j = parseWho(read(path.join(dir, f)) ?? '', Number(f.split('.')[0]));
      if (!j) continue;
      if (this.linux && j.pid && fs.existsSync(`/proc/${j.pid}`)) j.cmd = jobCommand(j.pid);
      else if (this.linux && j.pid) continue; // stale .who of a dead runner
      out.push(j);
    }
    return out.sort((a, b) => a.slot - b.slot);
  }

  newRuns() {
    const f = path.join(this.rrRoot, 'log', 'runs.log');
    let st;
    try {
      st = fs.statSync(f);
    } catch {
      return [];
    }
    const first = this.runsPos === null;
    const rotated = !first && (st.ino !== this.runsPos.ino || st.size < this.runsPos.size);
    const start = first ? Math.max(0, st.size - 16_384) : rotated ? 0 : this.runsPos.size;
    this.runsPos = { ino: st.ino, size: st.size };
    if (st.size <= start) return [];
    const fd = fs.openSync(f, 'r');
    try {
      const buf = Buffer.alloc(Math.min(st.size - start, 1 << 20));
      fs.readSync(fd, buf, 0, buf.length, start);
      let text = buf.toString('utf8');
      if (start > 0 && first) text = text.slice(text.indexOf('\n') + 1);
      const runs = parseRunsLog(text);
      return first ? runs.slice(-15) : runs.slice(-50);
    } finally {
      fs.closeSync(fd);
    }
  }

  async frame({ withInfo = false, fast = false } = {}) {
    const now = Date.now();
    const uptime = os.uptime();
    let mem;
    let swap;
    let temp = null;
    let watts = null;
    let pressure = null;
    const disks = [];
    if (this.linux) {
      ({ mem, swap } = parseMeminfo(read('/proc/meminfo') ?? ''));
      temp = pickTemp(hwmonReadings());
      watts = parsePower(read(process.env.RD_POWER_FILE || '/run/rdocker/power'), now);
      const root = diskOf('/');
      if (root) disks.push(root);
      const mounts = read('/proc/mounts') ?? '';
      if (/ \/var\/lib\/docker /.test(mounts)) {
        const d = diskOf('/var/lib/docker');
        if (d) disks.push(d);
      }
    } else if (this.mac) {
      const [vm, sw, st, pr] = await Promise.all([sh('vm_stat', []), sh('sysctl', ['-n', 'vm.swapusage']), this.macStatic(), this.pressure()]);
      mem = macMem(parseVmStat(vm ?? ''), st.memsize || os.totalmem());
      swap = parseSwapusage(sw ?? '');
      pressure = pr;
      watts = parsePower(read(process.env.RD_POWER_FILE || '/Users/Shared/rdocker/power'), now); // com.rdocker.power (optional)
      const d = diskOf('/System/Volumes/Data') ?? diskOf('/');
      if (d) disks.push(d);
    } else {
      mem = { total: os.totalmem(), used: os.totalmem() - os.freemem(), avail: os.freemem() };
      swap = { total: 0, used: 0 };
    }

    const ts = await this.ts();
    if (ts) {
      this.selfIps = ts.self.ips;
      this.peers = ts.peers;
    }
    let links = this.peers;
    if (fast && this.cfg.pingPeers !== false && links.length) {
      const rtt = await this.pings(links);
      links = links.map((p) => ({ ...p, rttMs: rtt?.get(p.ip) ?? null }));
    }

    const leaks = this.agentHost ? scanLeaks(await sh('ps', ['-eo', 'pid=,time=,args='], 3000), this.leakState, now) : [];
    const jobs = this.jobs();
    const q = this.linux ? runnerQueue(new Set(jobs.map((j) => j.pid).filter(Boolean)), uptime) : { queued: 0, waitS: null };
    const hist = this.hist;
    this.hist = [];
    const frame = {
      t: 'f',
      ts: now,
      cpu: this.lastCpu ?? 0,
      cores: this.lastCores ?? [],
      load: os.loadavg().map((x) => Math.round(x * 100) / 100),
      mem,
      swap,
      disks,
      temp,
      watts,
      uptime: Math.round(uptime),
      hist,
      jobs: jobs.map(({ pid: _pid, ...j }) => j),
      queued: q.queued,
      waitS: q.waitS,
      runs: this.newRuns(),
      links,
      hostMem: await this.hostMem(),
      pressure,
      ...(leaks.length ? { leaks } : {}),
    };
    if (withInfo) frame.info = this.info();
    return frame;
  }
}

// ---------------------------------------------------------------------------- runtime

export function loadConfig(file) {
  const st = fs.statSync(file);
  if (process.platform !== 'win32' && (st.mode & 0o077) !== 0) {
    throw new Error(`${file} is readable by others (mode ${(st.mode & 0o777).toString(8)}); run: chmod 600 ${file}`);
  }
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const errs = validateConfig(cfg);
  if (errs.length) throw new Error(`${file}: ${errs.join('; ')}`);
  return cfg;
}

function log(...a) {
  console.log(new Date().toISOString(), ...a);
}

function run(cfg) {
  if (typeof WebSocket === 'undefined') throw new Error('this node has no global WebSocket; need node 22+');
  const col = new Collector(cfg);
  const notify = cfg.notify === true ? createNotifier() : null;
  let ws = null;
  let interval = SLOW_MS;
  let frameTimer = null;
  let infoAt = 0;
  let backoff = 1000;
  let sending = false;

  col.sample();
  const sampleLoop = () => {
    col.sample();
    setTimeout(sampleLoop, untilTick(Date.now(), SAMPLE_MS));
  };
  setTimeout(sampleLoop, untilTick(Date.now(), SAMPLE_MS));

  const send = async () => {
    if (!ws || ws.readyState !== WebSocket.OPEN || sending) return;
    sending = true;
    try {
      const withInfo = Date.now() - infoAt > 10 * 60_000;
      const f = await col.frame({ withInfo, fast: interval < SLOW_MS });
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(f));
        if (withInfo) infoAt = Date.now();
      }
    } catch (e) {
      log('frame failed:', e?.message ?? e);
    } finally {
      sending = false;
    }
  };
  const schedule = () => {
    clearTimeout(frameTimer);
    // +300 ms: let the 5 s CPU sample at the same boundary land first.
    frameTimer = setTimeout(async () => {
      await send();
      schedule();
    }, untilTick(Date.now(), interval) + 300);
  };

  const connect = () => {
    log(`connecting ${cfg.url} as ${cfg.name}`);
    const sock = new WebSocket(cfg.url);
    ws = sock;
    let helloOk = false;
    sock.addEventListener('open', () => sock.send(JSON.stringify({ ...signHello(cfg.name, cfg.key), ...(notify ? { notify: true } : {}) })));
    sock.addEventListener('message', (ev) => {
      let m;
      try {
        m = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      if (m?.t === 'alert' && notify) {
        void notify(m.events);
        return;
      }
      if (m?.t === 'mode' && Number.isFinite(m.ms) && m.ms >= 1000) {
        const first = !helloOk;
        helloOk = true;
        backoff = 1000;
        const faster = m.ms < interval;
        interval = m.ms;
        if (first) {
          infoAt = 0;
          log(`connected; frame every ${interval / 1000}s`);
        } else log(`mode -> every ${interval / 1000}s`);
        if (first || faster) void send(); // a new viewer sees fresh data at once
        schedule();
      }
    });
    sock.addEventListener('close', (ev) => {
      if (ws === sock) ws = null;
      clearTimeout(frameTimer);
      // 4401 = hello refused (wrong key / clock): no point hammering the Worker.
      const wait = ev.code === 4401 ? 5 * 60_000 : backoff + Math.random() * 1000;
      if (ev.code === 4401) log(`hello refused (${ev.reason}); check key, name and clock (chrony)`);
      else log(`disconnected (${ev.code}${ev.reason ? ` ${ev.reason}` : ''}); retry in ${Math.round(wait / 1000)}s`);
      backoff = Math.min(60_000, backoff * 2);
      setTimeout(connect, wait);
    });
    sock.addEventListener('error', () => {
      /* close follows */
    });
  };
  connect();
}

async function main(argv) {
  const arg = (k) => {
    const i = argv.indexOf(k);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  if (argv.includes('--version')) return console.log(VERSION);
  const file = arg('--config') ?? process.env.RD_REPORTER_CONFIG ?? path.join(os.homedir(), '.config/rdocker/reporter.json');
  if (argv.includes('--once')) {
    const c = new Collector({ name: 'once', role: 'test' });
    c.sample();
    await new Promise((r) => setTimeout(r, 1000));
    c.sample();
    console.log(JSON.stringify(await c.frame({ withInfo: true, fast: false }), null, 2));
    return;
  }
  run(loadConfig(file));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1])) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(`rd-reporter: ${e?.message ?? e}`);
    process.exit(78); // EX_CONFIG: systemd/launchd will retry after RestartSec
  });
}
