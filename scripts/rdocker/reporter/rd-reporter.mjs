#!/usr/bin/env node
// rd-reporter: pushes this machine's live stats to the fleet dashboard (Cloudflare Worker +
// Fleet Durable Object) over ONE WebSocket. Node 22+, zero dependencies, no sudo.
//
// Config: ~/.config/rdocker/reporter.json (mode 0600, refused otherwise), or $RD_REPORTER_CONFIG:
//   { "name": "hp", "url": "wss://<worker host>/ingest", "key": "<MACHINE_KEY_HP secret>",
//     "role": "home + worker",            // optional label shown on the dashboard
//     "pingPeers": true,                   // optional: tailscale ping online peers while viewed
//     "speed": 1.0,                        // optional: else fleet.json `speed` for this name, else 1
//     "rrRoot": "~/rr",                    // optional: rrun server root (slots, wait, runs.log)
//     "routeLog": "~/.local/state/rdocker/route.log", // optional (agent hosts): the rrun client's route.log
//     "notify": true,                      // optional: show fleet alerts on this machine (agent Macs)
//     "reach": true,                       // optional (agent hosts): probe each pool worker's sshd (default on)
//     "shareControl": true,                // optional (lent Macs, OWNER's reporter only): let dashboard admins
//                                          //   change this Mac's share switch (see share control below)
//     "agentTokens": false,                // optional (agent hosts): stop counting local AI-agent tokens (default on)
//     "controlOnly": true }                // optional, needs shareControl: a control-only helper for a Mac whose
//                                          //   stats reporter runs as another user (ethanair: rd). Sends no stats;
//                                          //   key = the separate MACHINE_CTL_KEY_<NAME> secret (see below)
// Protocol (dashboard/shared/protocol.ts is the typed source of truth):
//   -> {t:'hello', v:1, name, ts, nonce, sig[, notify:true]}  sig = hex HMAC-SHA256(key, "rd-ingest-v1|name|ts|nonce")
//   <- {t:'mode', ms}                           60000 when nobody watches, 5000 while a browser is open
//   -> {t:'f', ...frame}                        on wall-clock-aligned ticks of `ms`
//   <- {t:'alert', events:[{kind, alert}]}      notify:true only; once per fire / resolve (see notify below)
//   -> "ping"  <- "pong"                       after every frame; the DO's auto-response, feeds the watchdog
//   <- {t:'share', nonce, exp, cmd}             control:true only; -> {t:'share-ack', nonce, ok, code, out}
//   (hello carries control:true when shareControl is on AND this user may run the switch, see below)
//   controlOnly: -> {t:'hello', ..., ctl:true[, control:true]}  sig over "rd-ctl-v1|name|ts|nonce" with the
//   MACHINE_CTL_KEY_<NAME> key; then only "ping" (every 60 s) and share acks, never frames. The dashboard
//   keeps it beside the machine's stats socket and sends it the machine's share orders.
// CPU is sampled every 5 s locally; each frame carries the samples since the previous one (hist).
//
// Linux: /proc, /sys/class/hwmon, statfs; WSL: + Windows host RAM via powershell.exe (optional).
// macOS: vm_stat, sysctl, memory_pressure; temperature needs root there, so it is reported as null.
//   watts: the root rd-power sampler if present, else on laptops whole-system draw from ioreg
//   AppleSmartBattery (adapter input on AC, incl. charging; battery discharge otherwise).
// rrun: running jobs from <rrRoot>/slots/*.who (+ each job's cap, timeoutS, from <i>.own), finished
//   runs from <rrRoot>/log/runs.log. Linux: deadSlots = slots whose lock is still held (/proc/locks)
//   while the runner named in <i>.who is dead (readSlots; not measured on macOS).
//   queued / waitS: the runner's waiter list <rrRoot>/wait/<pid> (live pids; every OS), their mean age.
// Pool health (about once a minute): rd-doctor's status file (/run/rdocker/doctor, macOS <rrRoot>/state/
//   doctor.json, or "doctorFile" in the config), last-hour runs.log outcomes and submit-to-start wait
//   p50/p90 and worktree setup, 24 h job count, slot-wait total and prediction error.
// Agent hosts: route (24 h rruns by placement: pool, cache, local, fallback-local) from the client's
//   route.log (~/.local/state/rdocker/route.log, or "routeLog" in the config).
// Mac workers lent by their owner (lend): the owner's share switch /Users/Shared/rdocker/share (level),
//   root's rd-worker-mac status file /Users/Shared/rdocker/status ("jobs=N ts=EPOCH": pool jobs running
//   here) and the pool user's (rd) CPU from ps. All three are readable by the owner, whose reporter
//   cannot read rd's ~/rr (the Air: reporter `air` runs as the owner). Sent only where the status file exists.
// Agent hosts (agentTokens, every 10 min in a niced child): Claude Code + Codex token usage per local day
//   from ~/.claude/projects and ~/.codex/sessions, read incrementally (see agent tokens below).
// Agent hosts (reach, about once a minute): a plain TCP connect to every enabled pool worker's rd sshd
//   (fleet.json ip:port), closed at once, median of 3, 2 s timeout each, + direct/relay from tailscale
//   status. Runs in the background; each frame carries the latest result. No bandwidth test, by design.
// Install: copy this file to ~/.local/share/rdocker/reporter/ and load units/rd-reporter.service
// (systemd --user, Linux) or units/com.rdocker.reporter.plist (launchd, macOS).
// Flags: --once (print one frame as JSON, no network), --config <path>, --version,
//   --scan-agent-tokens [--claude-dir d --codex-dir d --state f] (one incremental token scan, JSON out),
//   --share-check (print whether this config's share control would accept orders here: ok or why).
import { execFile, spawn, spawnSync } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const VERSION = '1.7.0'; // 1.7.0: agentTokens (agent hosts: Claude Code + Codex tokens per local day, incremental background scan); 1.6.0: controlOnly (a share-control helper for a Mac whose stats reporter is another user); 1.5.0: reach (agent hosts: TCP connect time to each pool worker's sshd); 1.4.0: share control (owner opt-in shareControl; lend.ram); 1.3.0: lend (Mac share level, pool jobs here + last job, pool user CPU), route.last; 1.2.0: queued from <rrRoot>/wait (every OS), health wait1h/setup1h/day, route; 1.1.0: jobs[].timeoutS, deadSlots
const INGEST_V = 1;
const SAMPLE_MS = 5_000;
const SLOW_MS = 60_000;
const TS_EVERY_MS = 30_000;
const PING_EVERY_MS = 60_000;
const REACH_EVERY_MS = 60_000;
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

// ---- lend: a Mac worker lent by its owner (dashboard/shared/protocol.ts Lend) --------------------

/** The share-spec presets (rr_runner.pl share_presets: CPU % per level) and its old words. */
const SHARE_CPU = { low: 25, medium: 50, high: 100 };
const SHARE_ALIAS = { some: 'medium', max: 'high' };

/**
 * The owner's share file text -> {level, cpu: % of the cores lent}. MIRROR of rr_runner.pl share_spec:
 * null (no file) = "max", every core; a preset word (old words some/max too); `cpu=<10-100> ram=<1-256>`
 * (either or both) = "custom"; anything else, or "" (unreadable), = off. Off lends 0 %.
 */
export function parseShareLevel(text) {
  if (text == null) return { level: 'max', cpu: 100 };
  const off = { level: 'off', cpu: 0 };
  let s = String(text).trim();
  s = SHARE_ALIAS[s] ?? s;
  if (s === 'off') return off;
  if (SHARE_CPU[s]) return { level: s, cpu: SHARE_CPU[s] };
  const v = {};
  for (const w of s.split(/\s+/)) {
    const m = /^(cpu|ram)=(\d{1,3})$/.exec(w);
    if (!m || m[1] in v) return off;
    const n = Number(m[2]);
    if (m[1] === 'cpu' ? n < 10 || n > 100 : n < 1 || n > 256) return off;
    v[m[1]] = n;
  }
  return Object.keys(v).length ? { level: 'custom', cpu: v.cpu ?? 100 } : off;
}

/**
 * The RAM cap (GB) the share text gives a machine with `memBytes` of memory, as rdocker-share shows it
 * (share_caps ram_mb, then int GB): custom ram= as is; a preset its share of the memory; null = no cap
 * (no file, a custom pick without ram=) or off.
 */
const SHARE_RAM_PCT = { low: 25, medium: 50, high: 75 };
export function shareRamGb(text, memBytes) {
  if (text == null) return null;
  let s = String(text).trim();
  s = SHARE_ALIAS[s] ?? s;
  const { level } = parseShareLevel(text);
  if (level === 'off') return null;
  if (SHARE_RAM_PCT[s]) {
    const totMb = Math.floor(memBytes / 1048576);
    return totMb > 0 ? Math.floor(Math.floor((totMb * SHARE_RAM_PCT[s]) / 100) / 1024) : null;
  }
  const m = /(?:^|\s)ram=(\d{1,3})(?:\s|$)/.exec(s);
  return m ? Number(m[1]) : null;
}

/** rd-worker-mac's status file ("jobs=N" / "ts=EPOCH", rewritten at least every 45 s) -> N, null when missing, malformed or older than maxAgeS. */
export function parseWorkerStatus(text, nowMs, maxAgeS = 120) {
  const j = /^jobs=(\d{1,4})\s*$/m.exec(text ?? '');
  const t = /^ts=(\d{9,12})\s*$/m.exec(text ?? '');
  if (!j || !t) return null;
  const age = nowMs / 1000 - Number(t[1]);
  return age >= -60 && age <= maxAgeS ? Number(j[1]) : null;
}

/** `ps -axo user=,pcpu=` -> % of the whole machine used by `user`'s processes (sum of per-process % / cores), null without output. */
export function psUserCpu(text, user, ncpu) {
  if (text == null || !(ncpu > 0)) return null;
  let sum = 0;
  for (const line of text.split('\n')) {
    const m = /^\s*(\S+)\s+(\d+(?:\.\d+)?)\s*$/.exec(line);
    if (m && m[1] === user) sum += Number(m[2]);
  }
  return Math.min(100, Math.round((10 * sum) / ncpu) / 10);
}

/**
 * `ioreg -rn AppleSmartBattery` (Apple laptops, no root) -> whole-machine power draw.
 * Preferred: PowerTelemetryData.SystemLoad (mW), the machine's own draw excluding battery charging.
 * Fallback on AC: PowerTelemetryData.SystemPowerIn (mW) = power drawn from the adapter by the whole laptop,
 * which includes battery charging. On battery: Voltage (mV) x InstantAmperage (mA, negative while
 * discharging; ioreg may print it as a wrapped unsigned 64-bit value). Null when absent or implausible.
 */
export function parseSmartBattery(text) {
  if (!text || !/AppleSmartBattery/.test(text)) return null;
  const top = (k) => new RegExp(`^[\\s|]*"${k}" = (\\S+)`, 'm').exec(text)?.[1];
  const signed = (s) => {
    if (!/^-?\d+$/.test(s ?? '')) return null;
    let b = BigInt(s);
    if (b >= 1n << 63n) b -= 1n << 64n;
    return Number(b);
  };
  const ok = (w) => Number.isFinite(w) && w >= 1 && w <= 300;
  // SystemLoad (mW): what the machine itself draws, on AC or battery, excluding battery charging.
  const load = signed(/"SystemLoad"=(\d+)/.exec(text)?.[1]);
  if (load != null && ok(load / 1000)) return { watts: Math.round(load / 100) / 10, source: 'system' };
  const ext = top('ExternalConnected');
  if (ext !== 'No') {
    const mw = signed(/"SystemPowerIn"=(\d+)/.exec(text)?.[1]);
    if (mw != null && ok(mw / 1000)) return { watts: Math.round(mw / 100) / 10, source: 'adapter' };
  }
  if (ext !== 'Yes') {
    const mv = signed(top('Voltage'));
    const ma = signed(top('InstantAmperage'));
    if (mv != null && ma != null && ma < 0) {
      const w = (mv * -ma) / 1e6;
      if (ok(w)) return { watts: Math.round(w * 10) / 10, source: 'battery' };
    }
  }
  return null;
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

/** fleet.json -> enabled pool workers to probe, [{name, ip, port}] (never this machine; at most 16). */
export function reachTargets(text, selfName, selfIps = []) {
  if (!text) return [];
  try {
    const j = JSON.parse(text);
    const list = Array.isArray(j) ? j : Array.isArray(j?.machines) ? j.machines : [];
    return list
      .filter((m) => m && m.enabled !== false && Array.isArray(m.roles) && m.roles.includes('worker'))
      .filter((m) => typeof m.name === 'string' && m.name && typeof m.ip === 'string' && m.ip && m.name !== selfName && !selfIps.includes(m.ip))
      .map((m) => ({ name: m.name.slice(0, 32), ip: m.ip.slice(0, 64), port: Number.isInteger(m.port) && m.port > 0 && m.port < 65536 ? m.port : 22 }))
      .slice(0, 16);
  } catch {
    return [];
  }
}

/** ms to complete one TCP handshake with host:port (socket closed at once), or null on error/timeout. */
export function tcpConnectMs(host, port, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const sock = net.connect({ host, port });
    let done = false;
    const end = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(v);
    };
    const timer = setTimeout(() => end(null), timeoutMs);
    sock.once('connect', () => end(performance.now() - t0));
    sock.once('error', () => end(null));
  });
}

/** Median of `tries` sequential connects (successes only), 0.1 ms; null when none connected. */
export async function probeRtt(host, port, { tries = 3, timeoutMs = 2000, connect = tcpConnectMs } = {}) {
  const ok = [];
  for (let i = 0; i < tries; i++) {
    const v = await connect(host, port, timeoutMs);
    if (v !== null) ok.push(v);
  }
  return ok.length ? Math.round(median(ok) * 10) / 10 : null;
}

/** Tailscale path to `ip` from the peer list: true direct, false relayed (DERP), null unknown/offline. */
export function directOf(peers, ip) {
  const p = peers.find((x) => x.ip === ip);
  return p && p.online ? !p.relayed : null;
}

/** "2026-11-09T10:00:00-0800" -> ms epoch */
export function parseLogTime(s) {
  const iso = s.replace(/([+-]\d{2})(\d{2})$/, '$1:$2');
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : 0;
}

/**
 * rr runs.log lines -> runs (format: rr_runner.pl run_log). The v2 tail after the TAB (run= owner= cls=
 * wait_s= exit_reason= setup= pred_s= client= pv= node= lock_s= slot_s= spred_s=) is cut off argv; on lines that
 * have the tail its pred_s, wait_s, slot_s and setup come back as `predS`, `waitS`, `slotS`, `setup` (pool
 * health only: Collector.newRuns keeps just the RUN_KEYS fields in a frame).
 */
export function parseRunsLog(text) {
  const out = [];
  const re = /^(\S+) repo=(\S+) wt=\S+ sha=\S+ outcome=(.+?) prepare_s=(\S+) cmd_s=(\S+) argv=(.*)$/;
  const n = (x) => (x === '-' || x === undefined || x === '' || !Number.isFinite(Number(x)) ? null : Number(x));
  for (const line of text.split('\n')) {
    const m = re.exec(line);
    if (!m) continue;
    const tab = m[6].indexOf('\t');
    const run = { ts: parseLogTime(m[1]), repo: m[2], outcome: m[3], prepS: n(m[4]), cmdS: n(m[5]), argv: (tab < 0 ? m[6] : m[6].slice(0, tab)).slice(0, 160) };
    if (tab >= 0) {
      const tail = m[6].slice(tab + 1);
      const f = (k) => new RegExp(`(?:^|\\s)${k}=(\\S+)`).exec(tail)?.[1];
      run.predS = n(f('pred_s'));
      run.waitS = n(f('wait_s'));
      run.slotS = n(f('slot_s'));
      const setup = f('setup');
      run.setup = setup === 'warm' || setup === 'clone' || setup === 'cold' ? setup : null;
    }
    out.push(run);
  }
  return out;
}
/** The fields of a run that go into a frame (shared/protocol.ts Run). */
const RUN_KEYS = ['ts', 'repo', 'outcome', 'prepS', 'cmdS', 'argv'];
const frameRun = (r) => Object.fromEntries(RUN_KEYS.map((k) => [k, r[k]]));

// ---------------------------------------------------------------------------- client routes (agent hosts)
/**
 * The client's route.log (rd_run.py record: ONE line per rrun, its final placement) -> rrun entries:
 * "<YYYY-MM-DD HH:MM:SS local> <target> rrun <argv> rc=<rc> <s>s | <cwd>[TAB stages]". target = a worker
 * name, `cache` / `pcache` (a result-cache hit: nothing ran), `local` (run here by design),
 * `fallback-local` (the pool failed or was unreachable: the job ran on this Mac), `none`.
 */
export function parseRouteLog(text) {
  const out = [];
  const re = /^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) (\S+)\s+rrun\s/;
  for (const line of text.split('\n')) {
    const m = re.exec(line);
    if (!m) continue;
    const ts = new Date(`${m[1]}T${m[2]}`).getTime(); // this machine's local time, as rd_run.py writes it
    if (Number.isFinite(ts)) out.push({ ts, target: m[3] });
  }
  return out;
}

/** route.log entries -> RouteStats: the last 24 h's rruns by where they went (shared/protocol.ts). */
export function routeStats(entries, now) {
  const day = { rrun: 0, pool: 0, cache: 0, local: 0, fallback: 0 };
  let last = null; // the newest rrun of any age in the tail (1.3.0): use older than the 24 h counts
  for (const e of entries) {
    if (e.ts > now + 60_000) continue;
    if (last === null || e.ts > last) last = e.ts;
    if (e.ts <= now - DAY_MS) continue;
    day.rrun++;
    if (e.target === 'cache' || e.target === 'pcache') day.cache++;
    else if (e.target === 'local') day.local++;
    else if (e.target === 'fallback-local') day.fallback++;
    else if (e.target !== 'none') day.pool++;
  }
  return { at: now, day, last };
}

// ---------------------------------------------------------------------------- slot queue
/**
 * The runner's waiter list: rr_runner.pl join_waiters writes <rrRoot>/wait/<pid> ("<epoch>") while a
 * run waits for a slot and leave_waiters removes it at the slot (the same list rd_pool's probe counts
 * as `waiting`). A file whose pid is gone is a leftover, not a waiter (the probe's rule: kill 0, EPERM
 * counts as alive). -> {queued, waitS: their mean age in s, null when none has a readable time}.
 * Every platform; read-only (the runner prunes leftovers itself).
 */
export function waitQueue(dir, nowMs, alive = pidAlive) {
  let names = [];
  try {
    if (fs.lstatSync(dir).isSymbolicLink()) return { queued: 0, waitS: null };
    names = fs.readdirSync(dir);
  } catch {
    return { queued: 0, waitS: null };
  }
  let queued = 0;
  let ageSum = 0;
  let aged = 0;
  for (const f of names) {
    if (!/^\d+$/.test(f) || !alive(Number(f))) continue;
    queued++;
    const t = Number(/^(\d+(?:\.\d+)?)/.exec(readBounded(path.join(dir, f), 64) ?? '')?.[1]);
    if (Number.isFinite(t) && t > 0) {
      ageSum += Math.max(0, nowMs / 1000 - t);
      aged++;
    }
  }
  return { queued, waitS: aged ? Math.round(ageSum / aged) : null };
}
function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e?.code === 'EPERM';
  }
}

// ---------------------------------------------------------------------------- pool health
// Workers ship pool health about once a minute (dashboard/shared/protocol.ts PoolHealth): the rd-doctor
// status file, last-hour runs.log outcome counts and the 24 h runtime-prediction error. The dashboard
// derives the pool alerts from it. Absent on machines with neither a doctor nor a runs.log.

export const HEALTH_EVERY_MS = 60_000;
const HOUR_MS = 3600_000;
const DAY_MS = 24 * HOUR_MS;
/** Most distinct outcome labels per health (the rest are summed into "other"). */
const OUTCOMES_MAX = 24;
/** runs.log bytes read per health (runs.log, then runs.log.1 when runs.log does not reach back 24 h). */
const HEALTH_READ_MAX = 3 << 20;
/** The doctor's status is one small JSON object; anything bigger is not it. */
export const DOCTOR_READ_MAX = 16 << 10;

/**
 * What a runs.log outcome means for pool health. MIRROR of dashboard/shared/pool-health.ts
 * outcomeClass (same rules, same test vectors in tests/health.test.mjs and the dashboard's
 * tests/pool-health.test.ts): ok | fail (the command's own result) | infra (the pool failed it) |
 * left (the client went away: not a run) | warm (a pre-warm: not a job).
 */
export const INFRA_RC = new Set([124, 134, 137, 72, 73, 75, 76]);
export function outcomeClass(outcome) {
  const o = String(outcome).trim();
  const m = /^(?:([a-z-]+) )?rc=(\d+)$/.exec(o);
  if (m) {
    const kind = m[1] ?? '';
    const rc = Number(m[2]);
    if (kind === 'lost' || kind === 'refused') return 'infra';
    if (kind === 'interrupted') return 'left';
    if (kind === 'timeout') return 'fail';
    if (INFRA_RC.has(rc)) return 'infra';
    return rc === 0 && kind === '' ? 'ok' : 'fail';
  }
  const word = o.split(/\s+/)[0] ?? '';
  if (word === 'busy' || word === 'refused') return 'infra';
  if (word === 'warm') return 'warm';
  if (word === 'abandoned-setup' || word === 'moved' || word === 'lost' || word === 'interrupted') return 'left';
  return 'fail';
}

/** rd-doctor status JSON -> the trimmed DoctorStatus, or null (missing / garbled / no ts). */
export function parseDoctor(text) {
  if (!text) return null;
  let o;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (!o || typeof o !== 'object' || typeof o.ts !== 'number' || !Number.isFinite(o.ts)) return null;
  const num = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
  return {
    ts: o.ts,
    disabled: o.disabled === true,
    dry: o.dry === true,
    drained: o.drained === true,
    drainSince: num(o.drain_since),
    drainReason: String(o.drain_reason ?? '').slice(0, 80),
    infraRecent: num(o.infra_recent),
    memFreePct: num(o.mem_free_pct),
    diskFreePct: num(o.disk_free_pct),
    actions1h: num(o.actions_1h) ?? 0,
    lastAction: String(o.last_action ?? '').slice(0, 160),
  };
}

/**
 * runs (parseRunsLog) + doctor -> PoolHealth at `now`. Besides the outcome counts and the prediction
 * error (1.0): wait1h = p50 / p90 of wait_s (submit to start: the client's worktree-lane and other-worker
 * waits + this runner's slot wait) over the last hour's runs whose command started; setup1h = how those
 * jobs found their worktree (warm = reused mirror); day = the last 24 h's jobs (ok + fail + infra) and
 * the seconds runs spent waiting for a slot here (slot_s, else wait_s on rows before it existed). The
 * three are null without a v2 tail in the window (an old runner).
 */
export function poolHealth(runs, doctor, now) {
  const counts = new Map();
  const cls1h = { ok: 0, fail: 0, infra: 0, left: 0, warm: 0 };
  const errs = [];
  const waits = [];
  const setup1h = { warm: 0, clone: 0, cold: 0 };
  let setupN = 0;
  let dayJobs = 0;
  let daySlotS = 0;
  let tails = 0;
  for (const r of runs) {
    if (!r.ts || r.ts > now + 60_000 || r.ts <= now - DAY_MS) continue;
    const cls = outcomeClass(r.outcome);
    const job = cls === 'ok' || cls === 'fail' || cls === 'infra';
    if (r.ts > now - HOUR_MS) {
      counts.set(r.outcome, (counts.get(r.outcome) ?? 0) + 1);
      cls1h[cls]++; // complete totals: the label list below is truncated
      if (r.cmdS !== null && r.waitS != null) waits.push(r.waitS);
      if (job && r.setup) {
        setup1h[r.setup]++;
        setupN++;
      }
    }
    if ('waitS' in r) tails++;
    if (job) dayJobs++;
    if (cls !== 'warm') daySlotS += r.slotS ?? r.waitS ?? 0;
    if ((r.outcome === 'rc=0' || r.outcome === 'rc=1') && r.cmdS !== null && r.cmdS >= 2 && r.predS != null && r.predS >= 0) {
      errs.push(Math.abs(r.predS - r.cmdS) / r.cmdS);
    }
  }
  const sorted = [...counts].sort((a, b) => b[1] - a[1]);
  const out1h = Object.fromEntries(sorted.slice(0, OUTCOMES_MAX));
  const rest = sorted.slice(OUTCOMES_MAX).reduce((a, [, c]) => a + c, 0);
  if (rest) out1h.other = (out1h.other ?? 0) + rest;
  const r1 = (x) => Math.round(x * 10) / 10;
  return {
    at: now,
    doctor,
    out1h,
    cls1h,
    pred: errs.length ? { err: Math.round(median(errs) * 1000) / 1000, n: errs.length } : null,
    wait1h: waits.length ? { p50: r1(quantile(waits, 0.5)), p90: r1(quantile(waits, 0.9)), n: waits.length } : null,
    setup1h: setupN ? setup1h : null,
    day: tails ? { jobs: dayJobs, slotS: Math.round(daySlotS) } : null,
  };
}

/** Nearest-rank quantile (q in 0..1) of a non-empty list. */
export function quantile(xs, q) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))];
}

/** Median of a non-empty list. */
export function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/** Open a regular file (never through a symlink at the last component) -> fd, or null. */
function openRegular(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0) | (fs.constants.O_NONBLOCK ?? 0));
  } catch {
    return null; // missing, unreadable, or a symlink (ELOOP)
  }
  try {
    if (fs.fstatSync(fd).isFile()) return fd;
  } catch {
    /* fall through */
  }
  fs.closeSync(fd);
  return null; // a FIFO, device or directory
}

/** A whole small regular file, or null when it is missing, not a regular file, or over `max` bytes. */
export function readBounded(file, max) {
  const fd = openRegular(file);
  if (fd === null) return null;
  try {
    if (fs.fstatSync(fd).size > max) return null;
    const buf = Buffer.alloc(max + 1);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    return n > max ? null : buf.subarray(0, n).toString('utf8'); // grew while reading: refuse
  } catch {
    return null;
  } finally {
    fs.closeSync(fd);
  }
}

/** The last `max` bytes of a regular file from a whole line on, or null when it cannot be read. */
export function readTail(file, max) {
  if (max <= 0) return null;
  const fd = openRegular(file);
  if (fd === null) return null;
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - max);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    const text = buf.toString('utf8');
    return start > 0 ? text.slice(text.indexOf('\n') + 1) : text;
  } catch {
    return null;
  } finally {
    fs.closeSync(fd);
  }
}

/** <slot>.who: "<repo_slug> <epoch> <pid> <wt12>" */
export function parseWho(text, slot) {
  const [repo, t, pid] = text.trim().split(/\s+/);
  if (!repo || !t) return null;
  return { slot, repo, since: Number(t) * 1000, pid: Number(pid) || null, cmd: null };
}

/** A slot's .own is one line (cmd= is redacted and capped by the runner); anything larger is not ours. */
const OWN_READ_MAX = 16_384;

/** <slot>.own (rr_runner.pl write_slot_files): one line of tab-separated key=value, cmd= last. */
export function parseOwn(text) {
  const o = {};
  for (const kv of (text.split('\n')[0] ?? '').split('\t')) {
    const m = /^([a-z_]+)=(.*)$/s.exec(kv);
    if (m) o[m[1]] = m[2];
  }
  return o;
}

/** userspace dev_t -> "major:minor" (glibc encoding), the form /proc/locks uses (there in hex). */
export function devKey(dev) {
  const d = BigInt(dev);
  const major = ((d >> 8n) & 0xfffn) | ((d >> 32n) & ~0xfffn);
  const minor = (d & 0xffn) | ((d >> 12n) & ~0xffn);
  return `${major}:${minor}`;
}

/**
 * /proc/locks -> the set of "major:minor:inode" that some process holds a lock on (any kind; the
 * runner's slot lock is FLOCK). Blocked waiters ("N: -> FLOCK ...") hold nothing and are skipped.
 * Read-only: looking never takes or disturbs a lock.
 */
export function parseProcLocks(text) {
  const held = new Set();
  for (const line of text.split('\n')) {
    const m = /^\d+:\s+(?!->)\S+\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+):([0-9a-f]+):(\d+)\s/i.exec(line);
    if (m) held.add(`${parseInt(m[1], 16)}:${parseInt(m[2], 16)}:${m[3]}`);
  }
  return held;
}

/**
 * <rrRoot>/slots -> { jobs, deadSlots }.
 * jobs: one per <i>.who; `timeoutS` (the command's cap, s, 0 = none) when the slot's .own names the
 * same pid (never a leftover's). On Linux a .who whose pid is gone is not a job:
 *   - its slot lock (slots/<i>) still held (per /proc/locks, matched by device + inode) and the .who
 *     not older than the lock -> a DEAD SLOT: the runner died but something that inherited its lock
 *     fd keeps the slot taken, so the slot is lost until that process ends. (A .who older than the
 *     lock is the moment a new runner has flocked but not yet rewritten it: not dead.)
 *   - lock free -> a stale .who (rd-doctor removes it).
 * deadSlots is null where it is not measured: macOS has no /proc/locks, and its lsof does not report
 * flock state (an open fd, e.g. a runner probing the slot, is not a held lock), so it is skipped there.
 * opts: { linux, alive(pid), locks() -> /proc/locks text | null, cmd(pid) -> string | null }.
 */
export function readSlots(dir, { linux, alive, locks, cmd }) {
  let files;
  try {
    files = fs.readdirSync(dir).filter((f) => /^\d+\.who$/.test(f));
  } catch {
    return { jobs: [], deadSlots: linux ? [] : null };
  }
  const jobs = [];
  const deadSlots = [];
  let held = null;
  const statOf = (p) => {
    try {
      return fs.statSync(p);
    } catch {
      return null;
    }
  };
  for (const f of files) {
    const slot = Number(f.split('.')[0]);
    const j = parseWho(read(path.join(dir, f)) ?? '', slot);
    if (!j) continue;
    if (linux && j.pid && !alive(j.pid)) {
      const lk = statOf(path.join(dir, String(slot)));
      const who = statOf(path.join(dir, f));
      if (!lk || !who || who.mtimeMs < lk.mtimeMs) continue;
      held ??= parseProcLocks(locks() ?? '');
      if (held.has(`${devKey(lk.dev)}:${lk.ino}`)) deadSlots.push({ slot, repo: j.repo, since: j.since, pid: j.pid });
      continue;
    }
    const own = parseOwn(readBounded(path.join(dir, `${slot}.own`), OWN_READ_MAX) ?? ''); // no symlink, no FIFO
    if (j.pid && own.pid === String(j.pid) && /^\d+$/.test(own.timeout_s ?? '')) j.timeoutS = Number(own.timeout_s);
    if (linux && j.pid) j.cmd = cmd(j.pid);
    jobs.push(j);
  }
  const bySlot = (a, b) => a.slot - b.slot;
  return { jobs: jobs.sort(bySlot), deadSlots: linux ? deadSlots.sort(bySlot) : null };
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
/** A control-only helper's hello (a distinct prefix: never a valid stats hello). MIRROR of protocol.ts ctlHelloMessage. */
export const ctlHelloMessage = (name, ts, nonce) => `rd-ctl-v${INGEST_V}|${name}|${ts}|${nonce}`;

export function signHello(name, key, tsS = Math.floor(Date.now() / 1000), nonce = randomBytes(16).toString('hex'), ctl = false) {
  const sig = createHmac('sha256', key).update((ctl ? ctlHelloMessage : helloMessage)(name, tsS, nonce)).digest('hex');
  return { t: 'hello', v: INGEST_V, name, ts: tsS, nonce, sig, ...(ctl ? { ctl: true } : {}) };
}

/** ms until the next wall-clock multiple of `interval` (all reporters tick together). */
export function untilTick(now, interval) {
  const r = interval - (now % interval);
  return r < 50 ? r + interval : r;
}

/** Inbound-silence limit for an OPEN socket: 3 frame intervals, clamped to [3 min, 10 min]. */
export const silenceLimitMs = (intervalMs) => Math.min(10 * 60_000, Math.max(3 * 60_000, 3 * intervalMs));

/**
 * Watchdog decision (pure). The Worker only talks on hello / viewer change, so liveness comes from
 * the "ping" the reporter sends with every frame: the Durable Object answers it with "pong" via its
 * WebSocket auto-response (no wake). Returns a reason string when the socket should be dropped, else null.
 *   lastInboundAt  last message of any kind from the Worker (or the connect time)
 *   lastSendOkAt   last successful ws.send (or the connect time)
 *   bufferedHistory ws.bufferedAmount just BEFORE each recent frame, oldest first: what the previous
 *                   frame left unsent a whole interval later (0 on a healthy link)
 */
export function shouldReconnect({ now, open, lastInboundAt, lastSendOkAt, intervalMs, bufferedHistory = [], sendFailed = false }) {
  if (sendFailed) return 'send failed';
  const limit = silenceLimitMs(intervalMs);
  if (!open) return now - lastInboundAt > limit ? 'stuck connecting' : null;
  if (now - lastInboundAt > limit) return `no reply for ${Math.round((now - lastInboundAt) / 1000)}s`;
  if (now - lastSendOkAt > limit) return `nothing sent for ${Math.round((now - lastSendOkAt) / 1000)}s`;
  const h = bufferedHistory.slice(-3);
  if (h.length === 3 && h[0] > 0 && h[1] > h[0] && h[2] > h[1]) return `send buffer not draining (${h[2]} bytes)`;
  return null;
}

export function validateConfig(c) {
  const errs = [];
  if (!c || typeof c !== 'object') return ['config is not a JSON object'];
  if (typeof c.name !== 'string' || !/^[a-z0-9][a-z0-9-]{0,31}$/.test(c.name)) errs.push('name: lower-case a-z0-9-, max 32');
  if (typeof c.url !== 'string' || !/^wss?:\/\/[^/]+\/ingest$/.test(c.url)) errs.push('url: wss://<host>/ingest');
  else if (c.url.startsWith('ws://') && !/^ws:\/\/(localhost|127\.0\.0\.1)(:\d+)?\//.test(c.url)) errs.push('url: ws:// only for localhost');
  if (typeof c.key !== 'string' || c.key.length < 32) errs.push('key: at least 32 chars (npm run machine-key)');
  if (c.notify !== undefined && typeof c.notify !== 'boolean') errs.push('notify: true or false');
  if (c.shareControl !== undefined && typeof c.shareControl !== 'boolean') errs.push('shareControl: true or false');
  if (c.controlOnly !== undefined && typeof c.controlOnly !== 'boolean') errs.push('controlOnly: true or false');
  if (c.agentTokens !== undefined && typeof c.agentTokens !== 'boolean') errs.push('agentTokens: true or false');
  else if (c.controlOnly === true && c.shareControl !== true) errs.push('controlOnly needs shareControl: true');
  return errs;
}

// ---------------------------------------------------------------------------- alerts (notify:true)
// The Fleet DO sends each alert once when it fires and once when it resolves. Locally we still
// cap it: at most one fire notification per alert id per hour (an id is rule:machine[:detail], so a
// flapping machine cannot spam), a resolve only when its fire was shown, and more than
// NOTIFY_SUMMARY_OVER in one message collapse into a single summary notification.
export const NOTIFY_EVERY_MS = 3600_000;
export const NOTIFY_SUMMARY_OVER = 3;

/** "3:18 PM": 12-hour local time, like the dashboard (this machine's zone is its user's). */
const clock = (ms) => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
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

// ---------------------------------------------------------------------------- share control
// A dashboard admin may change this Mac's share switch (rdocker-share), the same choices as the SwiftBar
// menu. Fail-closed at every step; the DO validates too, this side trusts nothing it is sent:
//  - only when the OWNER set "shareControl": true in this reporter.json (absent/false: every order refused),
//    and only over wss:// (certificate-checked TLS: the hello HMAC authenticates us to the dashboard, TLS
//    authenticates the dashboard to us);
//  - only on macOS, with real uid = effective uid, never root, and only when this user owns the share file
//    /Users/Shared/rdocker/share AND its folder, neither writable by group/others (a reporter running as
//    the pool user rd, e.g. ethanair, must never change its owner's switch). The paths are fixed: no
//    config setting can point the check at another file or the order at another program;
//  - /usr/local/bin/rdocker-share must be a regular executable (not a symlink, no set-id bit) owned by root
//    or this user, in a folder owned by root, neither writable by group/others;
//  - an order is accepted only on the socket it was sent to, after the dashboard accepted our hello: it
//    carries that connection's hello nonce (`conn`), so an order cannot be replayed on another connection,
//    even after a restart; on the connection its own 32-hex nonce is single use (remembered past its
//    expiry); it is refused past its expiry (server clock) or when that expiry is further ahead than an
//    order's lifetime;
//  - every folder above both is root's or this user's and not writable by others (unless sticky), and
//    none of the four carries a macOS ACL;
//  - the command must match the allowlist exactly (parseShareCmd, MIRROR of dashboard shared/protocol.ts;
//    both test suites check the same vectors) and becomes argv (no shell), run in its own process group
//    that is killed whole at the timeout, with its own alarm as a backstop that outlives this process,
//    with an env of PATH + LC_ALL only, one at a time.
// Every accepted-for-checking order is answered with {t:'share-ack', nonce, ok, code, out}.

export const SHARE_RUN_TIMEOUT_MS = 15_000;
/** An order's lifetime (the DO's SHARE_ORDER_TTL_MS) plus the clock difference tolerated ahead. */
export const SHARE_MAX_AHEAD_MS = 65_000;
export const SHARE_FILE = '/Users/Shared/rdocker/share';
export const SHARE_CMD = '/usr/local/bin/rdocker-share';
const SHARE_ENV = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' };
const SHARE_WORDS = ['off', 'low', 'medium', 'high', 'stop'];
const SHARE_RANGE = { cpu: [10, 100], ram: [1, 256] };
const SEEN_MAX = 1000;
const NONCE_RE = /^[0-9a-f]{32}$/;

/** Strict allowlist: exactly {op:<word>} or {op:'cpu'|'ram', n:<integer in range>}; anything else = null. */
export function parseShareCmd(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const keys = Object.keys(raw).sort().join(',');
  if (typeof raw.op !== 'string') return null;
  if (SHARE_WORDS.includes(raw.op)) return keys === 'op' ? { op: raw.op } : null;
  if (raw.op !== 'cpu' && raw.op !== 'ram') return null;
  if (keys !== 'n,op' || typeof raw.n !== 'number' || !Number.isInteger(raw.n)) return null;
  const [lo, hi] = SHARE_RANGE[raw.op];
  return raw.n >= lo && raw.n <= hi ? { op: raw.op, n: raw.n } : null;
}

export const shareArgv = (c) => ('n' in c ? [c.op, String(c.n)] : [c.op]);

const writableByOthers = (st) => (st.mode & 0o022) !== 0;

/** The pool's own account: never allowed to run the share switch (rd-worker-mac runs jobs as it). */
const POOL_USER = 'rd';
/** This process's account name for `uid` (null when it cannot be told). */
function userName(uid) {
  try {
    const u = os.userInfo();
    return u.uid === uid ? u.username : null;
  } catch {
    return null;
  }
}

/**
 * Every folder above `dir` (up to /) must be a real folder (no symlink) owned by root or `uid`, and not
 * writable by group/others unless sticky (/Users/Shared is 1777: nobody else can rename what we own in it),
 * so nothing on the way can be swapped out from under the checked paths. -> null or the reason.
 */
function ancestorsWhy(dir, uid, lstat) {
  for (let p = path.dirname(dir); ; p = path.dirname(p)) {
    let st;
    try {
      st = lstat(p);
    } catch {
      return `${p} is missing`;
    }
    if (!st.isDirectory()) return `${p} is not a folder`;
    if (st.uid !== 0 && st.uid !== uid) return `${p} is not owned by root or this user`;
    if (writableByOthers(st) && (st.mode & 0o1000) === 0) return `${p} is writable by group or others`;
    if (p === path.dirname(p)) return null;
  }
}

/** macOS ACLs (`ls -lde`: a "+" after the mode, or numbered entries) on any of the paths: can grant write past the mode bits. */
export function hasAcl(paths, run = (args) => spawnSync('/bin/ls', args, { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', LC_ALL: 'C' }, timeout: 5000 })) {
  const r = run(['-lde', ...paths]);
  if (r.status !== 0 || typeof r.stdout !== 'string') return true; // cannot tell: refuse
  return r.stdout.split('\n').some((l) => /^\S{10}\+/.test(l) || /^\s*\d+:\s/.test(l));
}

/**
 * May this process run the share switch? -> {ok: true, cmd} or {ok: false, why}. Re-checked on every order.
 * deps (tests only; never from the config): platform, uid, euid, user, lstat, acl, shareFile, shareCmd.
 */
export function shareControlCheck(cfg, deps = {}) {
  const { platform = process.platform, uid = process.getuid?.() ?? -1, euid = process.geteuid?.() ?? -1, user = userName(uid), lstat = fs.lstatSync, acl = hasAcl, shareFile = SHARE_FILE, shareCmd = SHARE_CMD } = deps;
  if (cfg?.shareControl !== true) return { ok: false, why: 'shareControl is not enabled in reporter.json' };
  if (typeof cfg.url !== 'string' || !cfg.url.startsWith('wss://')) return { ok: false, why: 'share control needs a wss:// dashboard url' };
  if (platform !== 'darwin') return { ok: false, why: 'not a Mac' };
  if (uid === 0 || euid === 0) return { ok: false, why: 'the reporter runs as root' };
  if (!(uid > 0) || uid !== euid) return { ok: false, why: 'unknown or mixed user ids' };
  // The pool user never, even if it somehow came to own the share file (a bad restore): by account name.
  if (user === null || user === POOL_USER || user === cfg.poolUser) return { ok: false, why: `the reporter runs as the pool user (${user ?? 'unknown'})` };
  const look = (p) => {
    try {
      return lstat(p); // never follows a symlink
    } catch {
      return null;
    }
  };
  const dir = path.dirname(shareFile);
  const f = look(shareFile);
  const d = look(dir);
  if (!f || !f.isFile()) return { ok: false, why: `${shareFile} is missing or not a regular file` };
  if (!d || !d.isDirectory()) return { ok: false, why: `${dir} is missing or not a folder` };
  if (f.uid !== uid || d.uid !== uid) return { ok: false, why: `${shareFile} or its folder is not owned by this user` };
  if (writableByOthers(f) || writableByOthers(d)) return { ok: false, why: `${shareFile} or its folder is writable by group or others` };
  const c = look(shareCmd);
  const cd = look(path.dirname(shareCmd));
  if (!c || !c.isFile() || (c.mode & 0o111) === 0) return { ok: false, why: `${shareCmd} is missing or not an executable file` };
  if (c.mode & 0o6000) return { ok: false, why: `${shareCmd} is set-id` };
  if (c.uid !== 0 && c.uid !== uid) return { ok: false, why: `${shareCmd} is not owned by root or this user` };
  if (!cd || !cd.isDirectory() || (cd.uid !== 0 && cd.uid !== uid)) return { ok: false, why: `${path.dirname(shareCmd)} is not a folder owned by root or this user` };
  if (writableByOthers(c) || writableByOthers(cd)) return { ok: false, why: `${shareCmd} or its folder is writable by group or others` };
  const up = ancestorsWhy(dir, uid, lstat) ?? ancestorsWhy(path.dirname(shareCmd), uid, lstat);
  if (up) return { ok: false, why: up };
  if (acl([shareFile, dir, shareCmd, path.dirname(shareCmd)])) return { ok: false, why: 'an ACL on the share file, the switch or their folders' };
  return { ok: true, cmd: shareCmd };
}

/** First line of a process's output: printable, bounded. */
const firstLine = (s) => String(s ?? '').split('\n').map((l) => l.trim()).find(Boolean)?.replace(/[\x00-\x1f\x7f]+/g, ' ').slice(0, 200) ?? '';

/**
 * Run the switch: argv (no shell), its own process group (killed whole at the timeout: the switch's
 * own children, e.g. mv, cannot outlive it), a minimal env. -> {ok, out}. A timeout is a failure whose
 * effect is unknown (the switch may have written before it was killed); the next frame shows the level.
 */
export const runShare = (cmd, args, timeoutMs = SHARE_RUN_TIMEOUT_MS, deadlineS = Math.ceil(timeoutMs / 1000) + 1) =>
  new Promise((resolve) => {
    let out = '';
    let err = '';
    let timedOut = false;
    let child;
    try {
      // perl arms an alarm and execs the switch (argv, no shell): the deadline lives in the switch's own
      // process, so it holds even if this reporter dies mid-run (one more order cannot follow: the DO holds
      // the machine for the order's whole lease).
      child = spawn('/usr/bin/perl', ['-e', 'alarm shift @ARGV; exec { $ARGV[0] } @ARGV or exit 127', String(deadlineS), cmd, ...args], {
        env: SHARE_ENV,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: false,
      });
    } catch (e) {
      resolve({ ok: false, out: `could not start: ${e?.code ?? 'error'}` });
      return;
    }
    const cap = (s, d) => (s.length < 65536 ? s + d : s);
    child.stdout.on('data', (d) => (out = cap(out, d)));
    child.stderr.on('data', (d) => (err = cap(err, d)));
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch {
        /* already gone */
      }
    }, timeoutMs);
    child.on('error', (e) => {
      clearTimeout(timer);
      resolve({ ok: false, out: `could not start: ${e?.code ?? 'error'}` });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (timedOut) return resolve({ ok: false, out: `timed out after ${timeoutMs / 1000}s; the result is unknown` });
      const line = firstLine(out) || firstLine(err);
      resolve(code === 0 ? { ok: true, out: line } : { ok: false, out: line || (code === null ? 'killed' : code === 127 ? 'could not start' : `exit ${code}`) });
    });
  });

/**
 * The order handler for one reporter process: (order, conn) -> ack, or null for an order that cannot be
 * answered (no usable nonce). `conn` = the hello nonce of the socket the order arrived on (null = that
 * socket's hello is not accepted yet). deps (tests): check, run, now, log.
 */
export function createShareControl(cfg, { check = () => shareControlCheck(cfg), run: exec = runShare, now = Date.now, log: say = log } = {}) {
  const seen = new Map(); // nonce -> forget after (ms)
  let running = false;
  const ack = (nonce, code, out = '') => ({ t: 'share-ack', nonce, ok: code === 'ok', code, out: String(out).slice(0, 200) });
  return {
    /** Advertised in the hello: whether orders would be accepted right now. */
    enabled: () => check().ok === true,
    async handle(order, conn) {
      const nonce = order?.nonce;
      if (typeof nonce !== 'string' || !NONCE_RE.test(nonce)) {
        say('share: dropped an order without a valid nonce');
        return null;
      }
      if (!conn || order.conn !== conn) {
        say('share: refused an order not meant for this connection');
        return ack(nonce, 'replay');
      }
      const t = now();
      for (const [n, until] of seen) if (until < t) seen.delete(n);
      if (seen.has(nonce)) {
        say('share: refused a replayed order');
        return ack(nonce, 'replay');
      }
      if (seen.size >= SEEN_MAX) return ack(nonce, 'busy'); // cannot remember it: refuse (the DO sends at most 10 a minute)
      const exp = order.exp;
      const okExp = Number.isFinite(exp) && t <= exp && exp - t <= SHARE_MAX_AHEAD_MS;
      seen.set(nonce, (okExp ? exp : t) + SHARE_MAX_AHEAD_MS); // remembered past any expiry it could pass
      if (!okExp) {
        say('share: refused an expired order');
        return ack(nonce, 'expired');
      }
      const c = check();
      if (!c.ok) {
        say(`share: refused (${c.why})`);
        return ack(nonce, 'disabled', c.why);
      }
      const cmd = parseShareCmd(order.cmd);
      if (!cmd) {
        say('share: refused an order off the allowlist');
        return ack(nonce, 'invalid');
      }
      if (running) return ack(nonce, 'busy');
      running = true;
      try {
        const args = shareArgv(cmd);
        const r = await exec(c.cmd, args);
        say(`share: rdocker-share ${args.join(' ')} -> ${r.ok ? 'ok' : 'failed'}${r.out ? ` (${r.out})` : ''}`);
        return ack(nonce, r.ok ? 'ok' : 'failed', r.out);
      } finally {
        running = false;
      }
    },
  };
}

// ---------------------------------------------------------------------------- agent tokens (agent hosts)
// The dashboard's entropy panel counts the AI work this machine's agents asked of data centers. A niced
// child process of this script (`--scan-agent-tokens`, at most every AGENT_TOKENS_EVERY_MS, never in
// the frame path) reads only the bytes appended since its last scan of
//   Claude Code  ~/.claude/projects/**/*.jsonl  assistant lines' message.usage (subagent transcripts too)
//   Codex        ~/.codex/sessions/**/*.jsonl   token_count events' last_token_usage (one per turn)
// and adds them to per-local-day totals in ~/.local/state/rdocker/agent-tokens.json (per-file offset +
// inode/size/mtime, so an 18 GB tree costs one full pass, then only the new tail).
// Counting, all LOWER-BOUND safe:
//   - Claude Code writes the same message's usage on several lines (one per content block), and a
//     forked subagent's transcript repeats its parent's messages: each message.id counts once, at its
//     first line, against a bounded set of the most recent ids (AGENT_TOKENS_RECENT_IDS, all files).
//   - Codex: a turn counts once via last_token_usage (never the running total_token_usage); an event
//     whose running total did not change is a repeat and is skipped; a replayed event (same timestamp
//     and total, e.g. a resumed session's copy) is caught by the same recent set.
// Frame field `agentTokens` = { days: { 'YYYY-MM-DD': { claude: {out,in,cw,cr}, codex: {out,in,cr} } },
// since }, last AGENT_TOKENS_DAYS days, sent when it changed and with every info frame (~10 min).
// Codex `in` = input minus cached; `cr` = cached input. Config: "agentTokens": false turns it off.
export const AGENT_TOKENS_EVERY_MS = 10 * 60_000;
const AGENT_TOKENS_FIRST_MS = 30_000; // first scan this long after start (frames come first)
export const AGENT_TOKENS_DAYS = 400;
export const AGENT_TOKENS_RECENT_IDS = 50_000;
const AGENT_TOKENS_TIMEOUT_MS = 30 * 60_000;
const AGENT_TOKENS_SAVE_MS = 60_000; // checkpoint the state this often during a long (first) scan
const TOKEN_READ_CHUNK = 1 << 20;
const TOKEN_LINE_MAX = 64 << 20; // a longer "line" is not a transcript line: skipped
const CLAUDE_MARK = Buffer.from('"usage":{');
const CODEX_MARK = Buffer.from('"token_count"');

/** Local calendar day of an epoch-ms time, YYYY-MM-DD (the reporter's time zone). */
export function localDay(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const tokenCount = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.round(v) : 0);

/** One Claude Code transcript line -> { id, day, out, in, cw, cr }, or null (not an assistant message with usage). */
export function claudeUsage(line) {
  let o;
  try {
    o = JSON.parse(line);
  } catch {
    return null;
  }
  const m = o?.type === 'assistant' ? o.message : null;
  const u = m?.usage;
  const t = Date.parse(o?.timestamp);
  if (!u || typeof u !== 'object' || typeof m.id !== 'string' || !m.id || !Number.isFinite(t)) return null;
  return { id: m.id, day: localDay(t), out: tokenCount(u.output_tokens), in: tokenCount(u.input_tokens), cw: tokenCount(u.cache_creation_input_tokens), cr: tokenCount(u.cache_read_input_tokens) };
}

/** One Codex rollout line -> { total, key, day, out, in, cr } for a token_count event with last_token_usage, else null. */
export function codexUsage(line) {
  let o;
  try {
    o = JSON.parse(line);
  } catch {
    return null;
  }
  const info = o?.type === 'event_msg' && o.payload?.type === 'token_count' ? o.payload.info : null;
  const last = info?.last_token_usage;
  const tot = info?.total_token_usage;
  const t = Date.parse(o?.timestamp);
  if (!last || typeof last !== 'object' || !tot || typeof tot !== 'object' || !Number.isFinite(t)) return null;
  const total = [tot.input_tokens, tot.cached_input_tokens, tot.output_tokens, tot.total_tokens].map(tokenCount).join('/');
  const input = tokenCount(last.input_tokens);
  const cached = Math.min(input, tokenCount(last.cached_input_tokens));
  return { total, key: `x:${o.timestamp}:${total}`, day: localDay(t), out: tokenCount(last.output_tokens), in: input - cached, cr: cached };
}

/** Insertion-ordered id set that forgets its oldest entries past `max`. */
class RecentIds {
  constructor(list, max) {
    this.max = max;
    this.set = new Set(Array.isArray(list) ? list.slice(-max) : []);
  }
  /** true when `id` is new (and remembers it); false for a repeat. */
  add(id) {
    if (this.set.has(id)) return false;
    this.set.add(id);
    if (this.set.size > this.max) this.set.delete(this.set.values().next().value);
    return true;
  }
  list() {
    return [...this.set];
  }
}

export const emptyTokenState = () => ({ v: 1, since: null, files: {}, recent: [], days: {} });

export function loadTokenState(file) {
  try {
    const s = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (s?.v === 1 && s.files && typeof s.files === 'object' && s.days && typeof s.days === 'object') return { ...emptyTokenState(), ...s };
  } catch {
    /* first run, or unreadable: start over */
  }
  return emptyTokenState();
}

function saveTokenState(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

const ZERO = { claude: { out: 0, in: 0, cw: 0, cr: 0 }, codex: { out: 0, in: 0, cr: 0 } };

function addTokens(state, day, prov, u) {
  const d = (state.days[day] ??= {});
  const p = (d[prov] ??= { ...ZERO[prov] });
  for (const k of Object.keys(p)) p[k] += u[k];
  if (!state.since || day < state.since) state.since = day;
}

/** Count one candidate line into `state` (rec = the file's state record; codex keeps its last running total there). */
export function countTokenLine(kind, line, rec, recent, state) {
  if (kind === 'claude') {
    const u = claudeUsage(line);
    if (!u || !recent.add(u.id)) return;
    if (u.out + u.in + u.cw + u.cr > 0) addTokens(state, u.day, 'claude', u);
    return;
  }
  const u = codexUsage(line);
  if (!u || u.total === rec.last) return; // a repeat of the previous event (running total unchanged)
  rec.last = u.total;
  if (!recent.add(u.key)) return; // the same event seen in another file (replay)
  if (u.out + u.in + u.cr > 0) addTokens(state, u.day, 'codex', u);
}

/**
 * Stream [start, end) of `file` in chunks and call onLine for each COMPLETE line that contains `mark`
 * (a byte search, so lines that cannot carry usage are never decoded). Returns the offset just past
 * the last complete line: a line still being written is read again next time.
 */
export async function readNewLines(file, start, end, mark, onLine) {
  const fh = await fs.promises.open(file, 'r');
  try {
    const buf = Buffer.allocUnsafe(TOKEN_READ_CHUNK);
    let pos = start;
    let done = start; // offset after the last complete line
    let carry = null;
    let skipping = false; // inside an over-long line: drop bytes until its newline
    while (pos < end) {
      const { bytesRead } = await fh.read(buf, 0, Math.min(TOKEN_READ_CHUNK, end - pos), pos);
      if (!bytesRead) break;
      const chunk = buf.subarray(0, bytesRead);
      const data = carry ? Buffer.concat([carry, chunk]) : chunk;
      const base = pos - (carry?.length ?? 0);
      pos += bytesRead;
      let from = 0;
      let nl;
      while ((nl = data.indexOf(10, from)) !== -1) {
        if (!skipping) {
          const line = data.subarray(from, nl);
          if (line.indexOf(mark) !== -1) onLine(line.toString('utf8'));
        }
        skipping = false;
        from = nl + 1;
        done = base + from;
      }
      carry = from < data.length ? Buffer.from(data.subarray(from)) : null;
      if (carry && carry.length > TOKEN_LINE_MAX) {
        carry = null;
        skipping = true;
      }
    }
    return done;
  } finally {
    await fh.close();
  }
}

async function listJsonl(root) {
  const out = [];
  const walk = async (dir) => {
    let ents;
    try {
      ents = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(p);
    }
  };
  await walk(root);
  // sorted: a session's transcript sits next to its subagents' (dedupe window locality)
  return out.sort();
}

/** The frame payload: per-day totals of the last AGENT_TOKENS_DAYS days. */
export const agentTokensPayload = (state) => ({ days: state.days, since: state.since });

/**
 * One incremental scan: new bytes of every transcript, the totals updated, the state saved (also
 * checkpointed during a long first scan). Files that vanished leave the state; their days stay.
 */
export async function scanAgentTokens({ claudeDir, codexDir, stateFile, now = Date.now() }) {
  const t0 = Date.now();
  const state = loadTokenState(stateFile);
  const recent = new RecentIds(state.recent, AGENT_TOKENS_RECENT_IDS);
  const files = {};
  let bytes = 0;
  let read = 0;
  let savedAt = t0;
  const snapshot = (fileMap) => ({ ...state, files: fileMap, recent: recent.list() });
  for (const [kind, dir, mark] of [['claude', claudeDir, CLAUDE_MARK], ['codex', codexDir, CODEX_MARK]]) {
    if (!dir) continue;
    for (const f of await listJsonl(dir)) {
      let st;
      try {
        st = await fs.promises.stat(f);
      } catch {
        continue;
      }
      const prev = state.files[f];
      if (prev && prev.ino === st.ino && prev.size === st.size && prev.mtimeMs === st.mtimeMs) {
        files[f] = prev;
        continue;
      }
      const same = prev && prev.ino === st.ino && st.size >= prev.off;
      const start = same ? prev.off : 0;
      const rec = { ino: st.ino, size: st.size, mtimeMs: st.mtimeMs, off: start, ...(kind === 'codex' ? { last: same ? (prev.last ?? null) : null } : {}) };
      try {
        rec.off = await readNewLines(f, start, st.size, mark, (line) => countTokenLine(kind, line, rec, recent, state));
      } catch {
        if (prev) files[f] = prev; // unreadable now: try again next scan
        continue;
      }
      bytes += rec.off - start;
      read++;
      files[f] = rec;
      if (Date.now() - savedAt > AGENT_TOKENS_SAVE_MS) {
        saveTokenState(stateFile, snapshot({ ...state.files, ...files }));
        savedAt = Date.now();
      }
    }
  }
  const cutoff = localDay(now - AGENT_TOKENS_DAYS * 86_400_000);
  state.days = Object.fromEntries(Object.entries(state.days).filter(([d]) => d > cutoff).sort(([a], [b]) => (a < b ? -1 : 1)));
  const out = snapshot(files);
  saveTokenState(stateFile, out);
  return { files: read, bytes, ms: Date.now() - t0, agentTokens: agentTokensPayload(out) };
}

/** Totals over every kept day, for the log line. */
export function tokenTotals(payload) {
  const t = { claude: { ...ZERO.claude }, codex: { ...ZERO.codex } };
  for (const d of Object.values(payload?.days ?? {})) for (const prov of ['claude', 'codex']) for (const k of Object.keys(t[prov])) t[prov][k] += d?.[prov]?.[k] ?? 0;
  return t;
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
    // rd-doctor's status file (written by root on Linux, by the user's launchd job on macOS)
    this.doctorFile = expandHome(cfg.doctorFile ?? process.env.RD_DOCTOR_STATUS ?? (this.linux ? '/run/rdocker/doctor' : path.join(this.rrRoot, 'state', 'doctor.json')));
    this.healthC = cached(async () => this.health(), HEALTH_EVERY_MS - 1000);
    // agent hosts: where their rruns went (route.log), recomputed about once a minute
    this.routeLog = expandHome(cfg.routeLog ?? '~/.local/state/rdocker/route.log');
    this.routeC = cached(async () => this.route(), HEALTH_EVERY_MS - 1000);
    // Mac workers: the owner's share switch + root's job count (readable without access to rd's ~/rr)
    const shared = this.mac ? '/Users/Shared/rdocker' : null;
    this.shareFile = expandHome(cfg.shareFile ?? process.env.RR_SHARE_FILE ?? (shared ? `${shared}/share` : ''));
    this.statusFile = expandHome(cfg.statusFile ?? process.env.RD_STATUS_FILE ?? (shared ? `${shared}/status` : ''));
    this.poolUser = String(cfg.poolUser ?? 'rd');
    // when a pool job last ran here (the status count is live only): kept across restarts in a small file
    this.lendStateFile = expandHome(cfg.lendStateFile ?? '~/.local/state/rdocker/lend-last-job');
    this.lendJobAt = undefined; // loaded on first use
    this.lendSavedAt = 0;
    this.healthSent = null;
    this.peers = [];
    this.selfIps = [];
    this.fleetFile = expandHome(cfg.fleetFile ?? '~/.claude-dotfiles/scripts/rdocker/fleet.json');
    // agent hosts: latest TCP connect times to the pool workers (background, never delays a frame)
    this.reachOn = !/worker/i.test(String(cfg.role ?? '')) && cfg.reach !== false; // agent hosts (not tied to `leaks`)
    this.reach = null; // [{to, ip, rttMs, at}]
    this.reachAt = 0;
    this.reachBusy = false;
    // agent hosts: AI tokens from the local agent logs (a niced child scans them; see agent tokens above)
    this.tokensOn = !/worker/i.test(String(cfg.role ?? '')) && cfg.agentTokens !== false;
    this.tokenDirs = { claudeDir: expandHome(cfg.claudeProjects ?? '~/.claude/projects'), codexDir: expandHome(cfg.codexSessions ?? '~/.codex/sessions'), stateFile: expandHome(cfg.agentTokensState ?? '~/.local/state/rdocker/agent-tokens.json') };
    this.tokens = null; // latest agentTokens payload
    this.tokensKey = '';
    this.tokensSent = '';
    this.tokensAt = Date.now() - AGENT_TOKENS_EVERY_MS + AGENT_TOKENS_FIRST_MS;
    this.tokensBusy = false;
    this.wsl = this.linux && /microsoft/i.test(read('/proc/sys/kernel/osrelease') ?? '');
    this.tailscaleBin = this.mac && fs.existsSync('/Applications/Tailscale.app/Contents/MacOS/Tailscale') ? '/Applications/Tailscale.app/Contents/MacOS/Tailscale' : 'tailscale';
    this.ts = cached(() => this.readTailscale(), TS_EVERY_MS - 1000);
    this.pings = cached((peers) => this.pingPeers(peers), PING_EVERY_MS - 1000);
    this.hostMem = cached(() => this.readHostMem(), SLOW_CACHE_MS);
    this.pressure = cached(async () => parsePressure((await sh('memory_pressure', ['-Q'])) ?? ''), SLOW_CACHE_MS / 2);
    this.macStatic = cached(async () => ({ memsize: Number((await sh('sysctl', ['-n', 'hw.memsize'])) ?? 0) }), 3600_000);
    // Apple laptops: whole-machine draw without root. At most one ioreg per frame; a Mac with no
    // battery (mini, Studio) prints nothing and is not asked again.
    this.noBattery = false;
    this.battery = cached(async () => {
      const out = await sh('ioreg', ['-rn', 'AppleSmartBattery']);
      if (out === '') this.noBattery = true;
      return parseSmartBattery(out);
    }, SAMPLE_MS - 1000);
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
    const fleet = fleetEntry(this.cfg.name, read(this.fleetFile));
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

  /** Start a reach probe when one is due (agent hosts); the result lands in this.reach for later frames. */
  kickReach(now = Date.now()) {
    if (!this.reachOn || this.reachBusy || now - this.reachAt < REACH_EVERY_MS - 1000) return;
    this.reachAt = now;
    this.reachBusy = true;
    fs.promises
      .readFile(this.fleetFile, 'utf8')
      .catch(() => null)
      .then((text) => Promise.all(reachTargets(text, this.cfg.name, this.selfIps).map(async (t) => ({ to: t.name, ip: t.ip, rttMs: await probeRtt(t.ip, t.port), at: Date.now() }))))
      .then((r) => {
        this.reach = r.length ? r : null;
      })
      .catch(() => {})
      .finally(() => {
        this.reachBusy = false;
      });
  }

  async readHostMem() {
    if (!this.wsl) return null;
    const out = await sh('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory | ConvertTo-Json -Compress'], 8000);
    return out ? parsePsMem(out) : null;
  }

  /** Shared/rdocker/share text: null = no file (lends everything), '' = not a small regular file (off), as the runner reads it. */
  shareText() {
    try {
      fs.lstatSync(this.shareFile);
    } catch (e) {
      if (e?.code === 'ENOENT') return null;
    }
    return readBounded(this.shareFile, 64) ?? ''; // no-follow, non-blocking, regular files only, at most 64 bytes
  }

  /** ms of the last frame that saw a pool job running here (null: none on record); saved at most once a minute. */
  lendLastJob(jobs, now) {
    if (this.lendJobAt === undefined) {
      const t = Number((readBounded(this.lendStateFile, 32) ?? '').trim());
      this.lendJobAt = Number.isFinite(t) && t > 0 && t <= now + 60_000 ? t : null;
    }
    if (jobs > 0) {
      this.lendJobAt = now;
      if (now - this.lendSavedAt >= 60_000) {
        this.lendSavedAt = now;
        try {
          fs.mkdirSync(path.dirname(this.lendStateFile), { recursive: true, mode: 0o700 });
          const tmp = `${this.lendStateFile}.${process.pid}.tmp`;
          fs.writeFileSync(tmp, `${now}\n`, { mode: 0o600 });
          fs.renameSync(tmp, this.lendStateFile);
        } catch {
          /* best effort: the time is still sent from memory */
        }
      }
    }
    return this.lendJobAt;
  }

  /** shared/protocol.ts Lend, or null where there is no rd-worker-mac status file (not a lent Mac). */
  async lend(now) {
    if (!this.statusFile || !fs.existsSync(this.statusFile)) return null;
    const text = this.shareText();
    const { level, cpu } = parseShareLevel(text);
    const ps = await sh('ps', ['-axo', 'user=,pcpu='], 3000);
    const jobs = parseWorkerStatus(readBounded(this.statusFile, 256), now);
    return { at: now, level, cpu, ram: shareRamGb(text, os.totalmem()), jobs, busy: psUserCpu(ps, this.poolUser, os.cpus().length), lastJob: this.lendLastJob(jobs ?? 0, now) };
  }

  slots() {
    return readSlots(path.join(this.rrRoot, 'slots'), {
      linux: this.linux,
      alive: (pid) => fs.existsSync(`/proc/${pid}`),
      locks: () => read('/proc/locks'),
      cmd: jobCommand,
    });
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
      const runs = parseRunsLog(text).map(frameRun);
      return first ? runs.slice(-15) : runs.slice(-50);
    } finally {
      fs.closeSync(fd);
    }
  }

  /** PoolHealth now, or null on a machine with neither a doctor nor a runs.log. */
  health(now = Date.now()) {
    const doctor = parseDoctor(readBounded(this.doctorFile, DOCTOR_READ_MAX));
    const log = path.join(this.rrRoot, 'log', 'runs.log');
    const text = readTail(log, HEALTH_READ_MAX);
    if (text === null && !doctor) return null;
    let runs = parseRunsLog(text ?? '');
    if (!runs.length || runs[0].ts > now - DAY_MS) {
      const older = readTail(`${log}.1`, HEALTH_READ_MAX - (text?.length ?? 0));
      if (older) runs = [...parseRunsLog(older), ...runs];
    }
    return poolHealth(runs, doctor, now);
  }

  /** RouteStats now, or null without a route.log (not an rrun client). */
  route(now = Date.now()) {
    const text = readTail(this.routeLog, HEALTH_READ_MAX);
    if (text === null) return null;
    let entries = parseRouteLog(text);
    if (!entries.length || entries[0].ts > now - DAY_MS) {
      const older = readTail(`${this.routeLog}.1`, HEALTH_READ_MAX - text.length);
      if (older) entries = [...parseRouteLog(older), ...entries];
    }
    return routeStats(entries, now);
  }

  /** Start a background agent-token scan when one is due (agent hosts); its result rides a later frame. */
  kickTokens(now) {
    if (!this.tokensOn || this.tokensBusy || now - this.tokensAt < AGENT_TOKENS_EVERY_MS) return;
    this.tokensBusy = true;
    this.tokensAt = now;
    const d = this.tokenDirs;
    const args = [fileURLToPath(import.meta.url), '--scan-agent-tokens', '--claude-dir', d.claudeDir, '--codex-dir', d.codexDir, '--state', d.stateFile];
    let out = '';
    let err = '';
    const child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => child.kill('SIGTERM'), AGENT_TOKENS_TIMEOUT_MS);
    child.stdout.on('data', (b) => (out = (out + b).slice(-(4 << 20))));
    child.stderr.on('data', (b) => (err = (err + b).slice(-2000)));
    child.on('error', (e) => log('agent tokens: scan did not start:', e?.message ?? e));
    child.on('close', (code) => {
      clearTimeout(timer);
      this.tokensBusy = false;
      let r = null;
      try {
        r = JSON.parse(out.trim().split('\n').pop() ?? '');
      } catch {
        /* reported below */
      }
      if (code !== 0 || !r?.agentTokens) {
        log(`agent tokens: scan failed (exit ${code}): ${err.trim().split('\n').pop() ?? ''}`);
        return;
      }
      const key = JSON.stringify(r.agentTokens);
      const t = tokenTotals(r.agentTokens);
      log(
        `agent tokens: scan ok, ${r.files} file(s) read, ${(r.bytes / 1e6).toFixed(1)} MB new in ${(r.ms / 1000).toFixed(1)}s; ` +
          `since ${r.agentTokens.since ?? '-'}: claude out=${t.claude.out} in=${t.claude.in} cw=${t.claude.cw} cr=${t.claude.cr}, codex out=${t.codex.out} in=${t.codex.in} cr=${t.codex.cr}`,
      );
      this.tokens = r.agentTokens;
      this.tokensKey = key;
    });
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
      // No root sampler: laptops report whole-system draw (adapter input on AC, battery discharge otherwise).
      if (watts == null && !this.noBattery) watts = (await this.battery())?.watts ?? null;
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
    this.kickReach(now);
    this.kickTokens(now);
    let links = this.peers;
    if (fast && this.cfg.pingPeers !== false && links.length) {
      const rtt = await this.pings(links);
      links = links.map((p) => ({ ...p, rttMs: rtt?.get(p.ip) ?? null }));
    }

    const leaks = this.agentHost ? scanLeaks(await sh('ps', ['-eo', 'pid=,time=,args='], 3000), this.leakState, now) : [];
    const { jobs, deadSlots } = this.slots();
    const q = waitQueue(path.join(this.rrRoot, 'wait'), now);
    const route = this.agentHost ? await this.routeC() : null;
    const lend = await this.lend(now);
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
      ...(this.reach ? { reach: this.reach.map((x) => ({ ...x, direct: directOf(this.peers, x.ip) })) } : {}), // agent hosts, latest probe
      ...(route ? { route } : {}), // agent hosts with a route.log; small, so every frame
      ...(lend ? { lend } : {}), // lent Mac workers (status file present); small, so every frame
      ...(deadSlots?.length ? { deadSlots } : {}), // Linux only; absent = none (or not measured)
    };
    // Agent tokens: only when changed, and with every info frame (a restarted dashboard gets them back).
    if (this.tokens && (withInfo || this.tokensKey !== this.tokensSent)) {
      frame.agentTokens = this.tokens;
      this.tokensSent = this.tokensKey;
    }
    if (withInfo) frame.info = this.info();
    // Pool health: only when recomputed (about once a minute) or with info (a new connection).
    const health = await this.healthC();
    if (health && (withInfo || health !== this.healthSent)) {
      frame.health = health;
      this.healthSent = health;
    }
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
  // controlOnly: no collector, no frames; the "ping" keep-alive alone, at the idle pace.
  const ctlOnly = cfg.controlOnly === true;
  const col = ctlOnly ? null : new Collector(cfg);
  const notify = cfg.notify === true && !ctlOnly ? createNotifier() : null;
  const share = createShareControl(cfg);
  let ws = null;
  let interval = SLOW_MS;
  let frameTimer = null;
  let infoAt = 0;
  let backoff = 1000;
  let sending = false;

  if (col) {
    col.sample();
    const sampleLoop = () => {
      col.sample();
      setTimeout(sampleLoop, untilTick(Date.now(), SAMPLE_MS));
    };
    setTimeout(sampleLoop, untilTick(Date.now(), SAMPLE_MS));
  }

  // Watchdog state for the current socket (see shouldReconnect).
  let lastInboundAt = 0;
  let lastSendOkAt = 0;
  let buffered = [];

  const send = async () => {
    if (!ws || ws.readyState !== WebSocket.OPEN || sending) return;
    sending = true;
    try {
      const withInfo = Date.now() - infoAt > 10 * 60_000;
      let f = null;
      try {
        if (col) f = await col.frame({ withInfo, fast: interval < SLOW_MS });
      } catch (e) {
        log('frame failed:', e?.message ?? e);
        return;
      }
      const sock = ws;
      if (sock && sock.readyState === WebSocket.OPEN) {
        buffered = [...buffered.slice(-2), sock.bufferedAmount]; // leftover from the previous frame
        try {
          if (f) sock.send(JSON.stringify(f));
          // Keep-alive: the Worker auto-answers "ping" with "pong" without waking, so an idle
          // reporter still hears back once per frame and the watchdog can tell the link is alive.
          sock.send('ping');
        } catch (e) {
          drop(sock, `send failed: ${e?.message ?? e}`);
          return;
        }
        lastSendOkAt = Date.now();
        if (withInfo) infoAt = Date.now();
      }
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

  const retry = (code, reason) => {
    // 4401 = hello refused (wrong key / clock): no point hammering the Worker.
    const wait = code === 4401 ? 5 * 60_000 : backoff + Math.random() * 1000;
    if (code === 4401) log(`hello refused (${reason}); check key, name and clock (chrony)`);
    else log(`disconnected (${code}${reason ? ` ${reason}` : ''}); retry in ${Math.round(wait / 1000)}s`);
    backoff = Math.min(60_000, backoff * 2);
    setTimeout(connect, wait);
  };
  // Abandon a socket that looks dead and reconnect now. A half-open TCP link may never deliver
  // the close event, so we do not wait for it: the old socket is marked and its events ignored.
  const drop = (sock, reason) => {
    if (sock.rdDropped) return;
    sock.rdDropped = true;
    if (ws === sock) ws = null;
    clearTimeout(frameTimer);
    try {
      sock.close(4000, reason.slice(0, 100));
    } catch {
      /* already closing */
    }
    retry(4000, `watchdog: ${reason}`);
  };

  const connect = () => {
    log(`connecting ${cfg.url} as ${cfg.name}${ctlOnly ? ' (control-only: share orders, no stats)' : ''}`);
    const sock = new WebSocket(cfg.url);
    ws = sock;
    lastInboundAt = lastSendOkAt = Date.now();
    buffered = [];
    let helloOk = false;
    let conn = null; // this socket's hello nonce: share orders must carry it
    sock.addEventListener('open', () => {
      try {
        const control = share.enabled();
        if (cfg.shareControl === true && !control) log(`share control is on in the config but refused: ${shareControlCheck(cfg).why}`);
        const hello = signHello(cfg.name, cfg.key, undefined, undefined, ctlOnly);
        conn = hello.nonce;
        sock.send(JSON.stringify({ ...hello, ...(notify ? { notify: true } : {}), ...(control ? { control: true } : {}) }));
      } catch (e) {
        drop(sock, `hello send failed: ${e?.message ?? e}`);
      }
    });
    sock.addEventListener('message', (ev) => {
      if (sock.rdDropped) return;
      lastInboundAt = Date.now(); // any message counts, "pong" included
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
      if (m?.t === 'share') {
        void share.handle(m, helloOk ? conn : null).then((a) => {
          if (!a || sock.rdDropped || sock.readyState !== WebSocket.OPEN) return;
          try {
            sock.send(JSON.stringify(a));
          } catch {
            /* the DO times the order out */
          }
          if (a.ok) void send(); // show the new level at once
        });
        return;
      }
      if (m?.t === 'mode' && Number.isFinite(m.ms) && m.ms >= 1000) {
        const first = !helloOk;
        helloOk = true;
        backoff = 1000;
        const ms = ctlOnly ? SLOW_MS : m.ms; // a helper has nothing to show a viewer
        const faster = ms < interval;
        interval = ms;
        if (first) {
          infoAt = 0;
          log(ctlOnly ? 'connected (control-only)' : `connected; frame every ${interval / 1000}s`);
        } else log(`mode -> every ${interval / 1000}s`);
        if (first || faster) void send(); // a new viewer sees fresh data at once
        schedule();
      }
    });
    sock.addEventListener('close', (ev) => {
      if (sock.rdDropped) return; // the watchdog already scheduled the reconnect
      sock.rdDropped = true;
      if (ws === sock) ws = null;
      clearTimeout(frameTimer);
      retry(ev.code, ev.reason);
    });
    sock.addEventListener('error', () => {
      /* close follows */
    });
  };
  setInterval(() => {
    const sock = ws;
    if (!sock || sock.rdDropped) return;
    const reason = shouldReconnect({
      now: Date.now(),
      open: sock.readyState === WebSocket.OPEN,
      lastInboundAt,
      lastSendOkAt,
      intervalMs: interval,
      bufferedHistory: buffered,
    });
    if (reason) drop(sock, reason);
  }, 15_000);
  connect();
}

async function main(argv) {
  const arg = (k) => {
    const i = argv.indexOf(k);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  if (argv.includes('--version')) return console.log(VERSION);
  if (argv.includes('--scan-agent-tokens')) {
    // The background agent-token scan (Collector.kickTokens): lowest CPU priority, one JSON line out.
    try {
      os.setPriority(19);
    } catch {
      /* not permitted: run at normal priority */
    }
    const r = await scanAgentTokens({ claudeDir: arg('--claude-dir'), codexDir: arg('--codex-dir'), stateFile: arg('--state') ?? expandHome('~/.local/state/rdocker/agent-tokens.json') });
    console.log(JSON.stringify(r));
    return;
  }
  const file = arg('--config') ?? process.env.RD_REPORTER_CONFIG ?? path.join(os.homedir(), '.config/rdocker/reporter.json');
  if (argv.includes('--share-check')) {
    // Installers: would this config's share control accept orders here, as this user? (prints ok or why)
    const c = shareControlCheck(loadConfig(file));
    console.log(c.ok ? 'ok' : c.why);
    process.exitCode = c.ok ? 0 : 1;
    return;
  }
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
