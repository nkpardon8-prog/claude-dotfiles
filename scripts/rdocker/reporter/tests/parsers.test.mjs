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

test('runs.log truthful labels (2026-11-11) and the v2 tail parse', () => {
  const line = (o, p, c) => `2026-11-11T18:00:00-0700 repo=dentall wt=w sha=s outcome=${o} prepare_s=${p} cmd_s=${c} argv=npm test\trun=x owner=- cls=normal wait_s=0.0 exit_reason=x setup=cold pred_s=12.5 client=abc1234 pv=1`;
  const runs = r.parseRunsLog(['abandoned-setup', 'moved', 'warm', 'lost rc=255'].map((o) => line(o, '9.5', '-')).join('\n'));
  assert.deepEqual(runs.map((x) => x.outcome), ['abandoned-setup', 'moved', 'warm', 'lost rc=255']);
  assert.equal(runs[0].prepS, 9.5);
  assert.equal(runs[0].ts, Date.parse('2026-11-12T01:00:00Z'));
});

test('.who slots and argv redaction', () => {
  assert.deepEqual(r.parseWho('dentall 1800000000 4242 abc123def456\n', 1), { slot: 1, repo: 'dentall', since: 1800000000000, pid: 4242, cmd: null });
  assert.equal(r.parseWho('', 0), null);
  assert.equal(r.redactArgv(['node', 'x.js', '--token=abc', '-e', 'SECRET=1', 'FOO=bar']), 'node x.js --token=<redacted> -e <redacted> FOO=<redacted>');
});

test('.own fields, dev_t -> major:minor, /proc/locks holders (waiters hold nothing)', () => {
  assert.deepEqual(r.parseOwn('id=s:1\tname=a b\tpid=42\tlabel=ab\ttimeout_s=600\tcmd=x=1\ty\n'), { id: 's:1', name: 'a b', pid: '42', label: 'ab', timeout_s: '600', cmd: 'x=1' });
  assert.equal(r.devKey(2050), '8:2'); // rd-hp /dev/sda2: stat %d 2050, /proc/locks "08:02"
  assert.equal(r.devKey(0x10302), '259:2'); // nvme0n1p2 (major 259 needs the high bits)
  const held = r.parseProcLocks(
    ['1: FLOCK  ADVISORY  WRITE 164104 08:02:9870908 0 EOF', '1: -> FLOCK  ADVISORY  WRITE 999 08:02:777 0 EOF', '2: POSIX  ADVISORY  WRITE 419 00:19:610 0 EOF', '3: FLOCK  ADVISORY  WRITE 5 103:02:12 0 EOF'].join('\n'),
  );
  assert.deepEqual([...held].sort(), ['0:25:610', '259:2:12', '8:2:9870908']);
});

test('readSlots: timeoutS from a matching .own; Linux dead slot = lock held + .who pid dead + .who not older than the lock', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rdrep-slots-'));
  try {
    const put = (f, s, mtimeS) => {
      fs.writeFileSync(path.join(dir, f), s);
      if (mtimeS) fs.utimesSync(path.join(dir, f), mtimeS, mtimeS);
    };
    const T = 1_800_000_000;
    // 0: live job with a cap; 1: live job whose .own is a leftover (other pid); 2: dead pid, lock held;
    // 3: dead pid, lock free (stale .who); 4: dead pid, lock held, .who OLDER than the lock (a new runner
    // has just flocked and not yet rewritten it: not dead); 5: live job, .own with no timeout_s (old runner).
    for (let i = 0; i <= 5; i++) put(String(i), '', T + 100);
    put('0.who', `acme ${T} 100 aaaaaaaaaaaa\n`, T + 100);
    put('0.own', 'id=s\tpid=100\ttimeout_s=600\tcmd=npm test\n');
    put('1.who', `acme ${T} 101 aaaaaaaaaaaa\n`, T + 100);
    put('1.own', 'id=s\tpid=7\ttimeout_s=60\tcmd=npm test\n');
    put('2.who', `beta ${T} 202 bbbbbbbbbbbb\n`, T + 100);
    put('3.who', `gamma ${T} 303 cccccccccccc\n`, T + 100);
    put('4.who', `delta ${T} 404 dddddddddddd\n`, T + 50);
    put('5.who', `acme ${T} 105 aaaaaaaaaaaa\n`, T + 100);
    put('5.own', 'id=s\tpid=105\tlabel=ab\tcmd=npm test\n');
    const key = (i) => {
      const st = fs.statSync(path.join(dir, String(i)));
      const [maj, min] = r.devKey(st.dev).split(':').map((n) => Number(n).toString(16));
      return `${maj}:${min}:${st.ino}`;
    };
    const locks = [2, 4].map((i, n) => `${n + 1}: FLOCK  ADVISORY  WRITE 1 ${key(i)} 0 EOF`).join('\n') + '\n';
    const alive = (pid) => [100, 101, 105].includes(pid);
    let lockReads = 0;
    const opts = { linux: true, alive, locks: () => (lockReads++, locks), cmd: (pid) => `cmd-${pid}` };
    const { jobs, deadSlots } = r.readSlots(dir, opts);
    assert.deepEqual(jobs.map((j) => [j.slot, j.timeoutS, j.cmd]), [[0, 600, 'cmd-100'], [1, undefined, 'cmd-101'], [5, undefined, 'cmd-105']]);
    assert.deepEqual(deadSlots, [{ slot: 2, repo: 'beta', since: T * 1000, pid: 202 }]);
    assert.equal(lockReads, 1); // /proc/locks read once per scan, and only when some .who pid is dead

    // .own read like the other slot files: a symlink is never followed (nor a FIFO opened blocking).
    fs.renameSync(path.join(dir, '0.own'), path.join(dir, 'real.own'));
    fs.symlinkSync(path.join(dir, 'real.own'), path.join(dir, '0.own'));
    assert.equal(r.readSlots(dir, opts).jobs[0].timeoutS, undefined);
    fs.rmSync(path.join(dir, '0.own'));
    fs.renameSync(path.join(dir, 'real.own'), path.join(dir, '0.own'));

    // macOS: no liveness check, every .who is a job; dead slots not measured (null), /proc/locks never read.
    lockReads = 0;
    const mac = r.readSlots(dir, { ...opts, linux: false });
    assert.deepEqual(mac.jobs.map((j) => j.slot), [0, 1, 2, 3, 4, 5]);
    assert.equal(mac.deadSlots, null);
    assert.equal(lockReads, 0);
    // No slots dir yet.
    assert.deepEqual(r.readSlots(path.join(dir, 'nope'), opts), { jobs: [], deadSlots: [] });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
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
  assert.deepEqual(c.slots().jobs.map((j) => [j.slot, j.repo]), [[0, 'dentall']]);
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

test('leak detection: ps time, classification, redaction', () => {
  assert.equal(r.psTimeS('12:34.56'), 754.56); // mac m:ss.ss
  assert.equal(r.psTimeS('01:02:03'), 3723); // linux hh:mm:ss
  assert.equal(r.psTimeS('1-00:00:01'), 86401);
  assert.equal(r.psTimeS('junk'), null);
  // heavy dev work that skipped the pool
  assert.equal(r.leakKind('npm exec vitest run src/a.test.ts'), 'vitest');
  assert.equal(r.leakKind('node /x/node_modules/.bin/tsc --noEmit -p .'), 'tsc');
  assert.equal(r.leakKind('node /x/node_modules/.bin/next build'), 'build');
  assert.equal(r.leakKind('node /x/node_modules/.bin/eslint client/src'), 'eslint');
  assert.equal(r.leakKind('/usr/bin/python3 -m pytest tests'), 'python');
  // allowed locally / not dev work
  for (const a of [
    'node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js',
    'claude --resume',
    'node /x/node_modules/.bin/vite --config vite.connect.config.ts',
    'node /x/node_modules/.bin/vite --strictPort --host 127.0.0.1 --port 5261',
    'python3 -m uvicorn api.main:app --host 0.0.0.0 --port 8000',
    'python3 -m celery -A api.jobs worker --loglevel=info',
    'node /x/typescript/lib/tsserver.js --useInferredProjectPerProjectRoot',
    'node /x/node_modules/.bin/vitest --watch',
    'npx chrome-devtools-mcp@latest',
    '/usr/bin/python3 /Users/x/.claude-dotfiles/scripts/rdocker/rd_run.py npx tsc',
    '/sbin/launchd',
  ])
    assert.equal(r.leakKind(a), null, a);
  assert.equal(r.leakKind('node /x/node_modules/.bin/vite build'), 'build');
  const red = r.redactArgs('node /Users/o/Developer/CODEBASES/integrateAPI/projects/dentall/run.mjs --token=abc123 KEY:zzz ' + 'A'.repeat(40));
  assert.match(red, /\/Users\/o\/Developer\/CODEBASES\/integrateAPI\/projects\/dentall\/run\.mjs/); // paths stay readable
  assert.match(red, /--token=\*\*\*/);
  assert.match(red, /KEY:\*\*\*/);
  assert.doesNotMatch(red, /AAAA/);
});

test('leak detection: scanLeaks baseline, window, threshold, new pids', () => {
  const st = {};
  const ps = (rows) => rows.map(([pid, t, a]) => `${pid} ${t} ${a}`).join('\n');
  const T = 1_800_000_000_000;
  // first scan = baseline only, even for a busy process
  assert.deepEqual(r.scanLeaks(ps([[10, '5:00.00', 'node x/tsc --noEmit']]), st, T), []);
  // +20 cpu-s within the window -> one leak, then the counter resets
  let out = r.scanLeaks(ps([[10, '5:20.00', 'node x/tsc --noEmit']]), st, T + 60_000);
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, 'tsc');
  assert.equal(out[0].cpuS, 20);
  assert.deepEqual(r.scanLeaks(ps([[10, '5:25.00', 'node x/tsc --noEmit']]), st, T + 120_000), []); // 5 s < 15
  // a slow trickle never adds up: 10 s, then the window expires before the next 10 s
  const slow = {};
  r.scanLeaks(ps([[20, '0:00.00', 'node x/eslint .']]), slow, T);
  assert.deepEqual(r.scanLeaks(ps([[20, '0:10.00', 'node x/eslint .']]), slow, T + 60_000), []);
  assert.deepEqual(r.scanLeaks(ps([[20, '0:20.00', 'node x/eslint .']]), slow, T + 300_000), []);
  // a pid first seen after the baseline started since: all its CPU counts
  out = r.scanLeaks(ps([[10, '5:25.00', 'node x/tsc --noEmit'], [30, '0:40.00', 'npm exec vitest run a.test.ts'], [31, '9:00.00', 'claude']]), st, T + 180_000);
  assert.deepEqual(out.map((l) => [l.pid, l.kind, l.cpuS]), [[30, 'vitest', 40]]);
});

test('hookState: auto-offload hook wired or not', () => {
  assert.equal(r.hookState('{"hooks":{"PreToolUse":[{"hooks":[{"command":"python3 ~/.claude-dotfiles/scripts/hooks/rrun-route.py"}]}]}}'), 'ok');
  assert.equal(r.hookState('{"hooks":{}}'), 'missing');
  assert.equal(r.hookState(null), 'missing');
});

test('pingTargets: every online peer with an ip, phones included, capped at 16', async () => {
  const { pingTargets } = await import('../rd-reporter.mjs');
  const peers = [
    { host: 'phone', ip: '100.1.1.1', os: 'iOS', online: true },
    { host: 'tab', ip: '100.1.1.2', os: 'android', online: true },
    { host: 'off', ip: '100.1.1.3', os: 'linux', online: false },
    { host: 'noip', ip: '', os: 'linux', online: true },
  ];
  assert.deepEqual(pingTargets(peers).map((p) => p.host), ['phone', 'tab']);
  const many = Array.from({ length: 20 }, (_, i) => ({ host: 'h' + i, ip: '100.2.0.' + i, os: 'linux', online: true }));
  assert.equal(pingTargets(many).length, 16);
});

test('parseSmartBattery: AC = SystemPowerIn (fixture from an M4 MacBook Air), battery = V x I', () => {
  const ac = fx('ioreg_smartbattery_ac.txt');
  assert.deepEqual(r.parseSmartBattery(ac), { watts: 6.4, source: 'system' }); // SystemLoad: own draw, not battery charging
  const noLoad = ac.replace(/"SystemLoad"=\d+,?/, '');
  assert.deepEqual(r.parseSmartBattery(noLoad), { watts: 32.7, source: 'adapter' }); // fallback: SystemPowerIn=32690 mW
  // Same machine unplugged (edited copy): SystemPowerIn reads 0, current is negative and may be uint64-wrapped.
  const bat = noLoad // fallback path: no SystemLoad reading
    .replace('"ExternalConnected" = Yes', '"ExternalConnected" = No')
    .replace(/"SystemPowerIn"=\d+/, '"SystemPowerIn"=0')
    .replace(/^([\s|]*"Voltage" = )\d+/m, (_, k) => `${k}12000`)
    .replace(/^([\s|]*"InstantAmperage" = )\d+/m, (_, k) => `${k}18446744073709551116`); // -500 mA as uint64
  assert.deepEqual(r.parseSmartBattery(bat), { watts: 6, source: 'battery' });
  assert.deepEqual(r.parseSmartBattery(bat.replace('18446744073709551116', '-750')), { watts: 9, source: 'battery' });
  assert.equal(r.parseSmartBattery(bat.replace('18446744073709551116', '1200')), null); // positive current off AC: no draw figure
  assert.equal(r.parseSmartBattery(noLoad.replace(/"SystemPowerIn"=\d+/, '"SystemPowerIn"=0')), null); // AC but no telemetry
  assert.equal(r.parseSmartBattery(noLoad.replace(/"SystemPowerIn"=\d+/, '"SystemPowerIn"=900000')), null); // 900 W: implausible
  assert.equal(r.parseSmartBattery(''), null); // desktop Mac: no AppleSmartBattery
  assert.equal(r.parseSmartBattery(null), null);
  assert.doesNotMatch(ac, /HHY3|F8YH/); // serials redacted
});

test('shouldReconnect: silence, stalled sends, undrained buffer, send errors', () => {
  const t0 = 1_800_000_000_000;
  const base = { now: t0, open: true, lastInboundAt: t0, lastSendOkAt: t0, intervalMs: 60_000, bufferedHistory: [0, 0, 0] };
  assert.equal(r.shouldReconnect(base), null);
  assert.equal(r.silenceLimitMs(5_000), 180_000); // floor 3 min
  assert.equal(r.silenceLimitMs(120_000), 360_000); // 3 x interval
  assert.equal(r.silenceLimitMs(3600_000), 600_000); // cap 10 min
  // idle reporter (60 s frames, pong each frame): 2.9 min of silence is fine, 3.1 min is not
  assert.equal(r.shouldReconnect({ ...base, now: t0 + 174_000, lastSendOkAt: t0 + 170_000 }), null);
  assert.match(r.shouldReconnect({ ...base, now: t0 + 186_000, lastSendOkAt: t0 + 180_000 }), /no reply for 186s/);
  assert.match(r.shouldReconnect({ ...base, now: t0 + 186_000, lastInboundAt: t0 + 180_000 }), /nothing sent/);
  // never reached OPEN within the limit
  assert.equal(r.shouldReconnect({ ...base, open: false, now: t0 + 60_000 }), null);
  assert.equal(r.shouldReconnect({ ...base, open: false, now: t0 + 200_000 }), 'stuck connecting');
  // leftover before each send: growing 3 frames in a row = not draining; a single blip is not
  assert.match(r.shouldReconnect({ ...base, bufferedHistory: [900, 1900, 2800] }), /not draining \(2800 bytes\)/);
  assert.equal(r.shouldReconnect({ ...base, bufferedHistory: [0, 1900, 2800] }), null);
  assert.equal(r.shouldReconnect({ ...base, bufferedHistory: [900, 1900, 1900] }), null);
  assert.equal(r.shouldReconnect({ ...base, bufferedHistory: [900, 1900] }), null);
  assert.equal(r.shouldReconnect({ ...base, sendFailed: true }), 'send failed');
});
