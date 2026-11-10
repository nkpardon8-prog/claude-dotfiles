// Alert delivery tests for rd-reporter.mjs (notify:true machines). Commands are mocked.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as r from '../rd-reporter.mjs';

const T = 1_800_000_000_000;
const alert = (id, extra = {}) => ({ id, rule: 'offline', machine: id.split(':')[1], severity: 'crit', message: `${id} msg`, firedAt: T, resolvedAt: null, ...extra });
const fire = (id, extra) => ({ kind: 'fire', alert: alert(id, extra) });
const resolve = (id, extra) => ({ kind: 'resolve', alert: alert(id, { resolvedAt: T + 7 * 60_000, ...extra }) });
const quiet = () => {};

test('plan: fire shows once per id per hour, resolve only after a shown fire', () => {
  let p = r.planNotifications([fire('offline:hp')], new Map(), T);
  assert.deepEqual(p.notes.map((n) => n.title), ['CRIT offline:hp msg']);
  // Flap: resolve shown, the re-fire within the hour is suppressed, its resolve too.
  p = r.planNotifications([resolve('offline:hp')], p.seen, T + 7 * 60_000);
  assert.deepEqual(p.notes.map((n) => n.title), ['OK offline:hp msg']);
  assert.match(p.notes[0].body, /resolved after 7 min/);
  p = r.planNotifications([fire('offline:hp', { firedAt: T + 10 * 60_000 })], p.seen, T + 10 * 60_000);
  assert.deepEqual(p.notes, []);
  p = r.planNotifications([resolve('offline:hp', { firedAt: T + 10 * 60_000 })], p.seen, T + 12 * 60_000);
  assert.deepEqual(p.notes, []);
  // An hour after the last shown fire it may show again.
  p = r.planNotifications([fire('offline:hp', { firedAt: T + 61 * 60_000 })], p.seen, T + 61 * 60_000);
  assert.equal(p.notes.length, 1);
  // A resolve for something this process never showed (e.g. after a restart) stays quiet.
  assert.deepEqual(r.planNotifications([resolve('disk:air:/')], new Map(), T).notes, []);
  // Garbage is ignored.
  assert.deepEqual(r.planNotifications([null, { kind: 'fire' }, { kind: 'x', alert: alert('a:b') }], new Map(), T).notes, []);
  assert.deepEqual(r.planNotifications('nope', new Map(), T).notes, []);
});

test('plan: more than 3 at once collapse into one summary; 3 stay separate', () => {
  const three = r.planNotifications(['a', 'b', 'c'].map((m) => fire(`offline:${m}`)), new Map(), T);
  assert.equal(three.notes.length, 3);
  const five = r.planNotifications(['a', 'b', 'c', 'd', 'e'].map((m) => fire(`offline:${m}`)), new Map(), T);
  assert.equal(five.notes.length, 1);
  assert.equal(five.notes[0].title, '5 fleet alerts');
  assert.equal(five.notes[0].body.split('\n').length, 5);
  assert.equal(five.seen.size, 5); // each id is still rate-limited afterwards
  assert.deepEqual(r.planNotifications([fire('offline:a')], five.seen, T + 60_000).notes, []);
});

test('plan: memory of shown ids is pruned after two hours', () => {
  const p = r.planNotifications([fire('offline:hp')], new Map(), T);
  assert.equal(r.planNotifications([], p.seen, T + 3 * 3600_000).seen.size, 0);
});

test('findRunpane: PATH first, then ~/.pane/bin', () => {
  const has = (set) => (p) => set.has(p);
  assert.equal(r.findRunpane({ PATH: '/usr/bin:/opt/x' }, has(new Set(['/opt/x/runpane', '/h/.pane/bin/runpane'])), '/h'), '/opt/x/runpane');
  assert.equal(r.findRunpane({ PATH: '/usr/bin' }, has(new Set(['/h/.pane/bin/runpane'])), '/h'), '/h/.pane/bin/runpane');
  assert.equal(r.findRunpane({}, has(new Set()), '/h'), null);
});

function mockRun(results) {
  const calls = [];
  return {
    calls,
    run: async (cmd, args) => {
      calls.push([cmd, ...args]);
      const res = results[cmd.endsWith('runpane') ? 'runpane' : cmd];
      return res ?? { ok: false, stdout: '' };
    },
  };
}
const note = { title: 'CRIT hp offline', body: 'since 12:00:00 · "spine" fleet' };

test('deliver: runpane notify --ui info when Pane answers', async () => {
  const m = mockRun({ runpane: { ok: true, stdout: '{"ok":true,"id":"N-1"}' } });
  assert.equal(await r.deliverNotification(note, { platform: 'darwin', runpane: '/p/runpane', run: m.run, log: quiet }), 'runpane');
  assert.deepEqual(m.calls, [['/p/runpane', 'notify', '--ui', 'info', '--title', 'CRIT hp offline', '--context', note.body, '--json']]);
});

test('deliver: falls back to osascript when Pane is not running or runpane fails', async () => {
  for (const rp of [{ ok: true, stdout: '{"unavailable":"Pane is not running.","next":"Ask in the terminal instead."}' }, { ok: false, stdout: '' }, { ok: true, stdout: 'not json' }]) {
    const m = mockRun({ runpane: rp, osascript: { ok: true, stdout: '' } });
    assert.equal(await r.deliverNotification(note, { platform: 'darwin', runpane: '/p/runpane', run: m.run, log: quiet }), 'osascript');
    assert.equal(m.calls[1][0], 'osascript');
    assert.equal(m.calls[1][2], 'display notification "since 12:00:00 · \\"spine\\" fleet" with title "CRIT hp offline"');
  }
  const none = mockRun({ osascript: { ok: true, stdout: '' } });
  assert.equal(await r.deliverNotification(note, { platform: 'darwin', runpane: null, run: none.run, log: quiet }), 'osascript');
  assert.equal(none.calls.length, 1);
});

test('deliver: log only off macOS without runpane, or when osascript fails', async () => {
  const lines = [];
  const m = mockRun({});
  assert.equal(await r.deliverNotification(note, { platform: 'linux', runpane: null, run: m.run, log: (...a) => lines.push(a.join(' ')) }), 'log');
  assert.deepEqual(m.calls, []);
  assert.match(lines[0], /alert: CRIT hp offline/);
  const bad = mockRun({ osascript: { ok: false, stdout: '' } });
  assert.equal(await r.deliverNotification(note, { platform: 'darwin', runpane: null, run: bad.run, log: quiet }), 'log');
});

test('appleString escapes quotes, backslashes and newlines', () => {
  assert.equal(r.appleString('a "b" \\ c\nd'), '"a \\"b\\" \\\\ c; d"');
});

test('createNotifier: delivers planned notes one at a time, rate limits repeats', async () => {
  const m = mockRun({ osascript: { ok: true, stdout: '' } });
  const n = r.createNotifier({ platform: 'darwin', runpane: null, run: m.run, log: quiet });
  await n([fire('offline:a'), fire('disk:b:/')], T);
  await n([fire('offline:a', { firedAt: T + 1 })], T + 60_000); // repeat within the hour
  assert.equal(m.calls.length, 2);
});

test('validateConfig: notify must be a boolean', () => {
  const base = { name: 'air', url: 'wss://x.example/ingest', key: 'k'.repeat(40) };
  assert.deepEqual(r.validateConfig({ ...base, notify: true }), []);
  assert.deepEqual(r.validateConfig({ ...base, notify: 'yes' }), ['notify: true or false']);
});
