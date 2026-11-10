// Parser tests for rd-reporter.mjs. Zero deps: `node --test reporter/tests/`.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import * as r from '../rd-reporter.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fx = (f) => fs.readFileSync(path.join(here, 'fixtures', f), 'utf8');

test('/proc/stat deltas -> total and per-core busy %', () => {
  const a = r.parseProcStat(fx('proc_stat_a.txt'));
  const b = r.parseProcStat(fx('proc_stat_b.txt'));
  assert.equal(a.cores.length, 2);
  // busy = (dtotal - didle) / dtotal, idle = idle + iowait
  assert.equal(r.busyPct(a.all, b.all), 80); // dtotal 1000, didle 200
  assert.equal(r.busyPct(a.cores[0], b.cores[0]), 92.9); // dtotal 700, didle 50
  assert.equal(r.busyPct(a.cores[1], b.cores[1]), 50); // dtotal 300, didle 150
  assert.equal(r.busyPct(null, b.all), 0);
  assert.equal(r.busyPct(b.all, b.all), 0);
});

test('/proc/meminfo -> used = total - available, swap', () => {
  const m = r.parseMeminfo(fx('meminfo.txt'));
  assert.deepEqual(m.mem, { total: 8000000 * 1024, used: 6000000 * 1024, avail: 2000000 * 1024 });
  assert.deepEqual(m.swap, { total: 2000000 * 1024, used: 500000 * 1024 });
});

test('loadavg', () => assert.deepEqual(r.parseLoadavg('0.52 1.10 2.00 2/345 6789\n'), [0.52, 1.1, 2]));

test('vm_stat -> Activity-Monitor-style used memory', () => {
  const vm = r.parseVmStat(fx('vm_stat.txt'));
  assert.equal(vm.pageSize, 16384);
  assert.equal(vm.pages.pages_wired_down, 150000);
  assert.equal(vm.pages.anonymous_pages, 350000);
  assert.equal(vm.pages.pages_occupied_by_compressor, 100000);
  const total = 16 * 1024 ** 3;
  const m = r.macMem(vm, total);
  // (350000 - 10000 + 150000 + 100000) * 16384
  assert.equal(m.used, 590000 * 16384);
  assert.equal(m.avail, total - m.used);
});

test('sysctl vm.swapusage + memory_pressure', () => {
  assert.deepEqual(r.parseSwapusage('total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)'), {
    total: 2048 * 1024 ** 2,
    used: Math.round(1024.5 * 1024 ** 2),
  });
  assert.deepEqual(r.parseSwapusage('total = 0.00M  used = 0.00M  free = 0.00M'), { total: 0, used: 0 });
  assert.equal(r.parsePressure('The system has 17179869184 (1048576 pages with a page size of 16384).\nSystem-wide memory free percentage: 62%\n'), 62);
  assert.equal(r.parsePressure('nope'), null);
});

test('cpuinfo -> model, physical cores, threads', () => {
  assert.deepEqual(r.parseCpuinfo(fx('cpuinfo.txt')), { model: 'Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz', cores: 2, threads: 4 });
  assert.equal(r.parseOsRelease('NAME="Ubuntu"\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n'), 'Ubuntu 24.04.1 LTS');
});

test('hwmon temperature pick', () => {
  assert.equal(
    r.pickTemp([
      { chip: 'nvme', label: 'Composite', value: 70 },
      { chip: 'coretemp', label: 'Core 0', value: 55 },
      { chip: 'coretemp', label: 'Package id 0', value: 58.25 },
    ]),
    58.3,
  );
  assert.equal(r.pickTemp([{ chip: 'k10temp', label: 'Tctl', value: 71 }]), 71);
  assert.equal(r.pickTemp([{ chip: 'acpitz', label: '', value: 40 }, { chip: 'acpitz', label: '', value: 47 }]), 47);
  assert.equal(r.pickTemp([{ chip: 'nvme', label: '', value: 33 }]), 33);
  assert.equal(r.pickTemp([{ chip: 'x', label: '', value: NaN }]), null);
  assert.equal(r.pickTemp([]), null);
});

test('tailscale status: relayed = online peer with empty CurAddr', () => {
  const t = r.parseTailscale(fx('tailscale_status.json'));
  assert.deepEqual(t.self, { host: 'hp-prodesk', ips: ['100.64.0.1', 'fd7a:115c:a1e0::1'] });
  const by = Object.fromEntries(t.peers.map((p) => [p.host, p]));
  assert.equal(by.odwin.relayed, false); // Relay set but CurAddr present = direct
  assert.equal(by.odwin.curAddr, '192.168.1.20:41641');
  assert.equal(by['macbook-air'].relayed, true);
  assert.equal(by['macbook-air'].relay, 'ord');
  assert.equal(by['openclaw-macmini'].relayed, false); // offline is not "relayed"
  assert.equal(by['openclaw-macmini'].online, false);
});

test('tailscale ping', () => {
  assert.deepEqual(r.parseTsPing('pong from odwin (100.64.0.2) via 192.168.1.20:41641 in 3ms'), { via: '192.168.1.20:41641', rttMs: 3 });
  assert.deepEqual(r.parseTsPing('pong from air (100.64.0.3) via DERP(ord) in 41ms'), { via: 'DERP(ord)', rttMs: 41 });
  assert.equal(r.parseTsPing('timeout'), null);
});

test('runs.log lines (rr_runner.pl run_log format)', () => {
  const runs = r.parseRunsLog(fx('runs.log'));
  assert.equal(runs.length, 3);
  assert.deepEqual(runs[0], { ts: Date.parse('2026-11-09T18:00:00Z'), repo: 'dentall', outcome: 'rc=0', prepS: 3.2, cmdS: 41, argv: 'npm run test:db -- referrals' });
  assert.equal(runs[1].outcome, 'rc=2');
  assert.deepEqual([runs[2].outcome, runs[2].prepS, runs[2].cmdS, runs[2].argv], ['busy', null, null, 'npx vitest run src/a b c']);
});

test('.who slots and argv redaction', () => {
  assert.deepEqual(r.parseWho('dentall 1800000000 4242 abc123def456\n', 1), { slot: 1, repo: 'dentall', since: 1800000000000, pid: 4242, cmd: null });
  assert.equal(r.parseWho('', 0), null);
  assert.equal(r.redactArgv(['node', 'x.js', '--token=abc', '-e', 'SECRET=1', 'FOO=bar']), 'node x.js --token=<redacted> -e <redacted> FOO=<redacted>');
});

test('WSL host memory from powershell JSON', () => {
  assert.deepEqual(r.parsePsMem('{"TotalVisibleMemorySize":16000000,"FreePhysicalMemory":4000000}'), { total: 16000000 * 1024, free: 4000000 * 1024 });
  assert.equal(r.parsePsMem('not json'), null);
});

test('signed hello matches the Worker HMAC format', () => {
  const h = r.signHello('hp', 'k'.repeat(40), 1800000000, 'a'.repeat(32));
  const want = createHmac('sha256', 'k'.repeat(40)).update(`rd-ingest-v1|hp|1800000000|${'a'.repeat(32)}`).digest('hex');
  assert.deepEqual(h, { t: 'hello', v: 1, name: 'hp', ts: 1800000000, nonce: 'a'.repeat(32), sig: want });
  assert.match(r.signHello('hp', 'k'.repeat(40)).nonce, /^[0-9a-f]{32}$/);
});

test('wall-clock aligned ticks', () => {
  assert.equal(r.untilTick(1_000_000, 30_000), 20_000);
  assert.equal(r.untilTick(29_990, 30_000), 30_010); // too close: skip to the next one
});

test('config validation + 0600 enforcement', () => {
  assert.deepEqual(r.validateConfig({ name: 'hp', url: 'wss://fleet.example/ingest', key: 'k'.repeat(32) }), []);
  assert.equal(r.validateConfig({ name: 'HP', url: 'http://x/ingest', key: 'short' }).length, 3);
  assert.equal(r.validateConfig({ name: 'hp', url: 'ws://evil.example/ingest', key: 'k'.repeat(32) }).length, 1);
  assert.deepEqual(r.validateConfig({ name: 'hp', url: 'ws://localhost:5173/ingest', key: 'k'.repeat(32) }), []);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rdrep-'));
  const f = path.join(dir, 'reporter.json');
  fs.writeFileSync(f, JSON.stringify({ name: 'hp', url: 'wss://fleet.example/ingest', key: 'k'.repeat(32) }), { mode: 0o644 });
  assert.throws(() => r.loadConfig(f), /chmod 600/);
  fs.chmodSync(f, 0o600);
  assert.equal(r.loadConfig(f).name, 'hp');
  fs.rmSync(dir, { recursive: true });
});

test('fleet.json entry lookup (speed/roles fallback)', () => {
  const txt = JSON.stringify({ machines: [{ name: 'hp', speed: 1, roles: ['home', 'worker'] }] });
  assert.deepEqual(r.fleetEntry('hp', txt), { name: 'hp', speed: 1, roles: ['home', 'worker'] });
  assert.equal(r.fleetEntry('x', txt), null);
  assert.equal(r.fleetEntry('hp', '[{"name":"hp","speed":0.35}]').speed, 0.35);
  assert.equal(r.fleetEntry('hp', 'nope'), null);
});

test('Collector on a fake rr root: jobs + incremental runs.log', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rdrr-'));
  fs.mkdirSync(path.join(root, 'slots'));
  fs.mkdirSync(path.join(root, 'log'));
  fs.writeFileSync(path.join(root, 'slots', '0.who'), 'dentall 1800000000 999999 abc\n');
  fs.copyFileSync(path.join(here, 'fixtures', 'runs.log'), path.join(root, 'log', 'runs.log'));
  const c = new r.Collector({ name: 't', rrRoot: root }, 'darwin');
  assert.deepEqual(c.jobs().map((j) => [j.slot, j.repo]), [[0, 'dentall']]);
  assert.equal(c.newRuns().length, 3);
  assert.equal(c.newRuns().length, 0);
  fs.appendFileSync(path.join(root, 'log', 'runs.log'), '2026-11-09T11:00:00+0000 repo=x wt=y sha=z outcome=rc=0 prepare_s=1.0 cmd_s=2.0 argv=eslint .\n');
  assert.deepEqual(c.newRuns().map((x) => x.argv), ['eslint .']);
  fs.rmSync(root, { recursive: true });
});

test('parsePower: fresh averaged watts from rd-power, null when stale or garbled', () => {
  const now = 1_800_000_000_000;
  assert.equal(r.parsePower('47.3 1800000000\n', now), 47.3);
  assert.equal(r.parsePower('12 1799999990', now), 12);
  assert.equal(r.parsePower('47.3 1799999900', now), null); // 100 s old: sampler stopped
  assert.equal(r.parsePower('', now), null);
  assert.equal(r.parsePower(null, now), null);
  assert.equal(r.parsePower('hot 1800000000', now), null);
  assert.equal(r.parsePower('99999 1800000000', now), null);
});
