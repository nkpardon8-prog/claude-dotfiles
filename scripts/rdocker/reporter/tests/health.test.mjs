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
