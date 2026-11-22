// Pool health in rd-reporter.mjs: runs.log v2 tail, rd-doctor status, the PoolHealth payload.
// Zero deps: `node --test reporter/tests/`.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import * as r from '../rd-reporter.mjs';

const NOW = Date.parse('2026-11-12T20:00:00Z');
const stamp = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, '+0000');
/** One runs.log line in rr_runner.pl's format; `pred` undefined = a pre-v2 line (no tab tail). */
const line = (agoMs, outcome, cmdS, pred) =>
  `${stamp(NOW - agoMs)} repo=dentall wt=w sha=s outcome=${outcome} prepare_s=1.0 cmd_s=${cmdS} argv=npx vitest run a` +
  (pred === undefined ? '' : `\trun=r1 owner=- cls=normal wait_s=0.0 exit_reason=pass setup=warm pred_s=${pred} client=abc pv=3`);
const DOCTOR = {
  v: 1, os: 'linux', ts: NOW / 1000 - 20, disabled: false, dry: false, drained: true, drain_since: NOW / 1000 - 1200,
  drain_reason: 'infra=3/300s', ok_streak: 0, infra_recent: 3, mem_free_pct: 41, disk_free_pct: 7, actions_1h: 2,
  last_action: '1800000000 drain infra=3/300s',
};

test('runs.log v2 tail: argv stops at the TAB, pred_s parsed; pre-v2 lines have no predS', () => {
  const [a, b, c] = r.parseRunsLog([line(0, 'rc=0', '12.0', '10.5'), line(0, 'rc=1', '3.0', '-'), line(0, 'rc=0', '3.0')].join('\n'));
  assert.equal(a.argv, 'npx vitest run a');
  assert.equal(a.predS, 10.5);
  assert.equal(b.predS, null);
  assert.equal('predS' in c, false);
  assert.equal(c.argv, 'npx vitest run a');
});

test('parseDoctor: the rd-doctor status file, trimmed; garbage and a missing ts are null', () => {
  assert.deepEqual(r.parseDoctor(JSON.stringify(DOCTOR)), {
    ts: DOCTOR.ts, disabled: false, dry: false, drained: true, drainSince: DOCTOR.drain_since, drainReason: 'infra=3/300s',
    infraRecent: 3, memFreePct: 41, diskFreePct: 7, actions1h: 2, lastAction: '1800000000 drain infra=3/300s',
  });
  const nulls = r.parseDoctor('{"v":1,"ts":5,"drain_since":null,"mem_free_pct":null,"disk_free_pct":null}');
  assert.deepEqual([nulls.drainSince, nulls.memFreePct, nulls.diskFreePct, nulls.actions1h, nulls.lastAction], [null, null, null, 0, '']);
  assert.equal(r.parseDoctor('{"v":1}'), null);
  assert.equal(r.parseDoctor('not json'), null);
  assert.equal(r.parseDoctor(null), null);
  assert.equal(r.parseDoctor('{"ts":5,"last_action":"' + 'x'.repeat(500) + '"}').lastAction.length, 160);
});

test('poolHealth: last-hour outcome counts, 24 h median prediction error over rc=0/1 runs >= 2 s', () => {
  const runs = r.parseRunsLog(
    [
      line(2 * 3600_000, 'rc=0', '10.0', '30'), // 24 h only: err 2.0
      line(30 * 3600_000, 'rc=0', '10.0', '10'), // older than 24 h: ignored
      line(10 * 60_000, 'rc=0', '10.0', '12'), // err 0.2
      line(9 * 60_000, 'rc=1', '20.0', '10'), // err 0.5
      line(8 * 60_000, 'rc=2', '20.0', '10'), // rc=2: not in pred
      line(7 * 60_000, 'rc=0', '1.5', '10'), // < 2 s: not in pred
      line(6 * 60_000, 'rc=0', '10.0', '-'), // no prediction
      line(5 * 60_000, 'lost rc=255', '-', '10'),
      line(4 * 60_000, 'busy', '-', '-'),
      line(3 * 60_000, 'warm', '-', '-'),
      line(2 * 60_000, 'abandoned-setup', '-', '-'),
    ].join('\n'),
  );
  const h = r.poolHealth(runs, null, NOW);
  assert.equal(h.at, NOW);
  assert.equal(h.doctor, null);
  assert.deepEqual(h.cls1h, { ok: 3, fail: 2, infra: 2, left: 1, warm: 1 });
  assert.deepEqual(h.out1h, { 'rc=0': 3, 'rc=1': 1, 'rc=2': 1, 'lost rc=255': 1, busy: 1, warm: 1, 'abandoned-setup': 1 });
  assert.deepEqual(h.pred, { err: 0.5, n: 3 }); // median of 0.2, 0.5, 2.0
  assert.equal(r.poolHealth([], null, NOW).pred, null);
  assert.deepEqual(r.poolHealth([], null, NOW).out1h, {});
});

test('poolHealth payload stays small: at most 24 outcome labels plus "other"', () => {
  const runs = r.parseRunsLog(Array.from({ length: 40 }, (_, i) => line(60_000, `rc=${i + 2}`, '5.0', '5')).join('\n'));
  const h = r.poolHealth(runs, r.parseDoctor(JSON.stringify({ ...DOCTOR, last_action: 'y'.repeat(400) })), NOW);
  assert.equal(Object.keys(h.out1h).length, 25);
  assert.equal(h.out1h.other, 16);
  assert.ok(JSON.stringify(h).length < 1200, `payload ${JSON.stringify(h).length} bytes`);
});

test('Collector.health: doctor file + runs.log (+ runs.log.1 for the rest of the day); null with neither', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rdhealth-'));
  fs.mkdirSync(path.join(root, 'log'));
  fs.mkdirSync(path.join(root, 'state'));
  const doctorFile = path.join(root, 'state', 'doctor.json');
  const c = new r.Collector({ name: 't', rrRoot: root, doctorFile, role: 'worker' }, 'darwin');
  assert.equal(c.health(NOW), null);

  fs.writeFileSync(path.join(root, 'log', 'runs.log.1'), `${line(5 * 3600_000, 'rc=0', '10.0', '15')}\n`);
  fs.writeFileSync(path.join(root, 'log', 'runs.log'), `${line(10 * 60_000, 'rc=0', '10.0', '11')}\n${line(5 * 60_000, 'busy', '-', '-')}\n`);
  let h = c.health(NOW);
  assert.equal(h.doctor, null);
  assert.deepEqual(h.out1h, { 'rc=0': 1, busy: 1 });
  assert.deepEqual(h.pred, { err: 0.3, n: 2 }); // 0.1 (runs.log) and 0.5 (runs.log.1)

  fs.writeFileSync(doctorFile, JSON.stringify(DOCTOR));
  h = c.health(NOW);
  assert.equal(h.doctor.drained, true);
  assert.equal(h.doctor.diskFreePct, 7);

  // a doctor alone (no runs.log yet) still reports
  fs.rmSync(path.join(root, 'log'), { recursive: true });
  assert.equal(c.health(NOW).doctor.ts, DOCTOR.ts);
  fs.rmSync(root, { recursive: true });
});

test('Collector frames: health with the first (info) frame, then only when recomputed; runs never carry predS', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rdhealth-'));
  fs.mkdirSync(path.join(root, 'log'));
  fs.writeFileSync(path.join(root, 'log', 'runs.log'), `${line(60_000, 'rc=0', '10.0', '11')}\n`);
  const c = new r.Collector({ name: 't', rrRoot: root, doctorFile: path.join(root, 'none.json'), role: 'worker', pingPeers: false, fleetFile: path.join(root, 'none') }, 'other');
  c.ts = async () => null; // no tailscale in tests
  const f1 = await c.frame({ withInfo: true });
  assert.ok(f1.health, 'first frame carries health');
  assert.equal(f1.runs.length, 1);
  assert.equal('predS' in f1.runs[0], false);
  const f2 = await c.frame();
  assert.equal(f2.health, undefined, 'unchanged health is not re-sent');
  const f3 = await c.frame({ withInfo: true });
  assert.ok(f3.health, 'an info frame (new connection) re-sends it');
  fs.rmSync(root, { recursive: true });

  // an agent host with no ~/rr and no doctor sends no health at all
  const bare = new r.Collector({ name: 'a', rrRoot: path.join(os.tmpdir(), 'rd-none-xyz'), doctorFile: '/nonexistent/doctor', role: 'worker', pingPeers: false }, 'other');
  bare.ts = async () => null;
  assert.equal((await bare.frame({ withInfo: true })).health, undefined);
});

// Same vectors as the dashboard's tests/pool-health.test.ts ("outcome classes"): the two classifiers must agree.
export const CLASS_VECTORS = {
  infra: ['lost rc=255', 'refused rc=69', 'busy', 'refused', 'rc=124', 'rc=134', 'rc=137', 'rc=72', 'rc=73', 'rc=75', 'rc=76', 'error rc=75'],
  fail: ['rc=1', 'rc=2', 'timeout rc=143', 'deps-failed', 'error rc=1'],
  left: ['abandoned-setup', 'moved', 'interrupted rc=130', 'interrupted', 'lost'],
  warm: ['warm'],
  ok: ['rc=0'],
};

test('outcomeClass mirrors the dashboard classifier', () => {
  for (const [cls, outs] of Object.entries(CLASS_VECTORS)) for (const o of outs) assert.equal(r.outcomeClass(o), cls, o);
});

test('class totals are complete even when the label list is truncated (49-run repro)', () => {
  // two runs each of rc=0..rc=23 plus one busy: 1/49 infra = 2.04 %, but "busy" falls outside the top 24 labels
  const lines = [];
  for (let rc = 0; rc <= 23; rc++) lines.push(line(60_000, `rc=${rc}`, '5.0', '5'), line(60_000, `rc=${rc}`, '5.0', '5'));
  lines.push(line(60_000, 'busy', '-', '-'));
  const h = r.poolHealth(r.parseRunsLog(lines.join('\n')), null, NOW);
  assert.equal('busy' in h.out1h, false, 'busy was truncated into "other"');
  assert.deepEqual(h.cls1h, { ok: 2, fail: 46, infra: 1, left: 0, warm: 0 }); // no infra rc in 0..23: the busy is the 1
});

test('readBounded / readTail: regular files only, never through a symlink, never past the cap', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rdbound-'));
  const ok = path.join(dir, 'doctor.json');
  fs.writeFileSync(ok, JSON.stringify(DOCTOR));
  assert.equal(r.parseDoctor(r.readBounded(ok, r.DOCTOR_READ_MAX)).ts, DOCTOR.ts);
  const big = path.join(dir, 'big.json');
  fs.writeFileSync(big, 'x'.repeat(r.DOCTOR_READ_MAX + 1));
  assert.equal(r.readBounded(big, r.DOCTOR_READ_MAX), null);
  const link = path.join(dir, 'link.json');
  fs.symlinkSync(ok, link);
  assert.equal(r.readBounded(link, r.DOCTOR_READ_MAX), null);
  assert.equal(r.readTail(link, 1000), null);
  assert.equal(r.readBounded(dir, r.DOCTOR_READ_MAX), null);
  assert.equal(r.readBounded(path.join(dir, 'missing'), 100), null);
  const fifo = path.join(dir, 'fifo');
  if (spawnSync('mkfifo', [fifo]).status === 0) {
    assert.equal(r.readBounded(fifo, r.DOCTOR_READ_MAX), null);
    assert.equal(r.readTail(fifo, 1000), null);
  }
  // a planted symlink at the doctor path is treated as no doctor
  const c = new r.Collector({ name: 't', rrRoot: path.join(dir, 'rr'), doctorFile: link, role: 'worker' }, 'darwin');
  assert.equal(c.health(NOW), null);
  fs.rmSync(dir, { recursive: true });
});

// ---- slot queue, wait / setup / 24 h stats, client routes (1.2.0) -----------------------------

/** A v2 line with explicit wait fields (`lock`/`slot` undefined = a row before lock_s/slot_s existed). */
const tailLine = (agoMs, outcome, cmdS, { wait = 0, setup = 'warm', slot } = {}) =>
  `${stamp(NOW - agoMs)} repo=dentall wt=w sha=s outcome=${outcome} prepare_s=1.0 cmd_s=${cmdS} argv=npx vitest run a` +
  `\trun=r1 owner=- cls=normal wait_s=${wait} exit_reason=pass setup=${setup} pred_s=- client=abc pv=3 node=22` +
  (slot === undefined ? '' : ` lock_s=0.0 slot_s=${slot}`);

test('waitQueue: live pids in <rrRoot>/wait are waiters, mean age from their epoch; dead pids, junk names and a symlinked dir are not', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rdw-'));
  const dir = path.join(root, 'wait');
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, '101'), `${NOW / 1000 - 30}.250\n`);
  fs.writeFileSync(path.join(dir, '102'), `${NOW / 1000 - 90}\n`);
  fs.writeFileSync(path.join(dir, '103'), `${NOW / 1000 - 999}\n`); // its run is gone
  fs.writeFileSync(path.join(dir, '104'), 'garbled'); // alive, no readable time: counted, not aged
  fs.writeFileSync(path.join(dir, 'x.tmp'), `${NOW / 1000}\n`);
  const alive = (pid) => pid !== 103;
  assert.deepEqual(r.waitQueue(dir, NOW, alive), { queued: 3, waitS: 60 });
  assert.deepEqual(r.waitQueue(path.join(root, 'missing'), NOW, alive), { queued: 0, waitS: null });
  fs.symlinkSync(dir, path.join(root, 'link'));
  assert.deepEqual(r.waitQueue(path.join(root, 'link'), NOW, alive), { queued: 0, waitS: null });
  fs.rmSync(path.join(dir, '101'));
  fs.rmSync(path.join(dir, '102'));
  fs.rmSync(path.join(dir, '104'));
  assert.deepEqual(r.waitQueue(dir, NOW, alive), { queued: 0, waitS: null });
});

test('waitQueue: the real process table (this pid alive, a reaped one not)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rdw-'));
  fs.writeFileSync(path.join(dir, String(process.pid)), `${Date.now() / 1000 - 10}\n`);
  const gone = spawnSync(process.execPath, ['-e', '0']).pid;
  fs.writeFileSync(path.join(dir, String(gone)), `${Date.now() / 1000}\n`);
  const q = r.waitQueue(dir, Date.now());
  assert.equal(q.queued, 1);
  assert.ok(q.waitS >= 9 && q.waitS <= 11);
});

test('runs.log tail: wait_s, slot_s and setup parsed; frames carry only the Run fields', () => {
  const [a, b] = r.parseRunsLog([tailLine(0, 'rc=0', '5.0', { wait: 12.5, setup: 'clone', slot: 3.5 }), tailLine(0, 'rc=0', '5.0', { setup: '-' })].join('\n'));
  assert.equal(a.waitS, 12.5);
  assert.equal(a.slotS, 3.5);
  assert.equal(a.setup, 'clone');
  assert.equal(b.slotS, null);
  assert.equal(b.setup, null);
});

test('poolHealth: wait p50/p90 over started runs, setup split over jobs, 24 h jobs and slot wait', () => {
  const lines = [];
  for (let i = 1; i <= 10; i++) lines.push(tailLine(60_000 * i, i <= 7 ? 'rc=0' : 'rc=1', '5.0', { wait: i * 10, setup: i <= 6 ? 'warm' : 'clone', slot: i }));
  lines.push(tailLine(70_000, 'abandoned-setup', '-', { wait: 500, setup: '-', slot: 500 })); // waited, never started
  lines.push(tailLine(80_000, 'warm', '-', { wait: 0, setup: 'warm', slot: 99 })); // a pre-warm: not a job, not a wait
  lines.push(tailLine(3 * 3600_000, 'rc=0', '5.0', { wait: 40 })); // older than the hour; pre-slot_s row: wait_s counts
  lines.push(tailLine(25 * 3600_000, 'rc=0', '5.0', { wait: 9999, slot: 9999 })); // older than the day
  const h = r.poolHealth(r.parseRunsLog(lines.join('\n')), null, NOW);
  assert.deepEqual(h.wait1h, { p50: 50, p90: 90, n: 10 });
  assert.deepEqual(h.setup1h, { warm: 6, clone: 4, cold: 0 });
  assert.deepEqual(h.day, { jobs: 11, slotS: 55 + 500 + 40 });
});

test('poolHealth: no v2 tail in the window (an old runner) -> wait1h, setup1h and day are null', () => {
  const h = r.poolHealth(r.parseRunsLog([line(60_000, 'rc=0', '3.0'), line(120_000, 'rc=1', '3.0')].join('\n')), null, NOW);
  assert.equal(h.wait1h, null);
  assert.equal(h.setup1h, null);
  assert.equal(h.day, null);
  assert.equal(r.quantile([5], 0.9), 5);
  assert.equal(r.quantile([1, 2, 3, 4], 0.5), 2);
});

test('route.log: one rrun per line by placement over 24 h; docker verbs and older lines ignored', () => {
  const at = (agoMs) => {
    const d = new Date(NOW - agoMs);
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  };
  const text = [
    `${at(60_000)} hp    rrun     npx vitest run rc=0 9.1s | /repo\tlock_s=0.0 slot_s=3.0`,
    `${at(70_000)} laptop rrun     pnpm -r typecheck rc=1 20.0s | /repo`,
    `${at(80_000)} cache rrun     npx tsc --noEmit rc=0 0.4s | /repo\tlock_s=0.0 cache_s=0.43`,
    `${at(90_000)} pcache rrun     npx tsc --noEmit rc=0 0.4s | /repo`,
    `${at(100_000)} local rrun     python3 -m unittest rc=exec 0.0s | /repo`,
    `${at(110_000)} fallback-local rrun     npx tsc --noEmit rc=exec 4.1s | /repo`,
    `${at(120_000)} none rrun     x rc=2 0.0s | /repo`,
    `${at(130_000)} mini  exec     postgres | /repo`,
    `${at(25 * 3600_000)} hp    rrun     old rc=0 1.0s | /repo`,
    'garbage',
  ].join('\n');
  const entries = r.parseRouteLog(text);
  const newest = Math.max(...entries.map((e) => e.ts));
  assert.deepEqual(r.routeStats(entries, NOW), { at: NOW, day: { rrun: 7, pool: 2, cache: 2, local: 1, fallback: 1 }, last: newest });
  // the newest rrun of any age (1.3.0): older than the 24 h counts still says when it last ran
  const old = r.parseRouteLog(`${at(30 * 3600_000)} hp    rrun     old rc=0 1.0s | /repo`);
  assert.deepEqual(r.routeStats(old, NOW), { at: NOW, day: { rrun: 0, pool: 0, cache: 0, local: 0, fallback: 0 }, last: old[0].ts });
});

test('Collector frames: queued from <rrRoot>/wait; route on agent hosts only', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rdq-'));
  fs.mkdirSync(path.join(root, 'wait'));
  fs.writeFileSync(path.join(root, 'wait', String(process.pid)), `${Date.now() / 1000 - 5}\n`);
  const routeLog = path.join(root, 'route.log');
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  fs.writeFileSync(routeLog, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())} fallback-local rrun     x rc=exec 1.0s | /r\n`);
  const worker = new r.Collector({ name: 'w', role: 'worker', rrRoot: root, routeLog, pingPeers: false, doctorFile: path.join(root, 'none') });
  const wf = await worker.frame();
  assert.equal(wf.queued, 1);
  assert.ok(wf.waitS >= 4 && wf.waitS <= 6);
  assert.equal('route' in wf, false);
  const agent = new r.Collector({ name: 'a', role: 'agents', rrRoot: root, routeLog, pingPeers: false, doctorFile: path.join(root, 'none') });
  const af = await agent.frame();
  assert.equal(af.route.day.fallback, 1);
});
