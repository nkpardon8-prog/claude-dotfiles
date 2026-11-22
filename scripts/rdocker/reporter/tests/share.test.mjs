// Share control in rd-reporter.mjs: the command allowlist (same vectors as the dashboard's
// tests/share-control.test.ts), who may run the switch, nonce / expiry / replay handling, the argv-only
// runner with its minimal env and timeout, and (macOS) one real round trip through rdocker-share.sh.
// Zero deps: `node --test reporter/tests/`.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import * as r from '../rd-reporter.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHARE_SH = path.resolve(HERE, '../../share/rdocker-share.sh');

// Kept identical to dashboard tests/share-control.test.ts: [input, argv or null].
const VECTORS = [
  [{ op: 'off' }, ['off']],
  [{ op: 'low' }, ['low']],
  [{ op: 'medium' }, ['medium']],
  [{ op: 'high' }, ['high']],
  [{ op: 'stop' }, ['stop']],
  [{ op: 'cpu', n: 10 }, ['cpu', '10']],
  [{ op: 'cpu', n: 100 }, ['cpu', '100']],
  [{ op: 'ram', n: 1 }, ['ram', '1']],
  [{ op: 'ram', n: 256 }, ['ram', '256']],
  [{ op: 'cpu', n: 9 }, null],
  [{ op: 'cpu', n: 101 }, null],
  [{ op: 'cpu', n: 50.5 }, null],
  [{ op: 'cpu', n: '50' }, null],
  [{ op: 'cpu' }, null],
  [{ op: 'ram', n: 0 }, null],
  [{ op: 'ram', n: 257 }, null],
  [{ op: 'ram', n: -4 }, null],
  [{ op: 'off', n: 1 }, null],
  [{ op: 'low', extra: true }, null],
  [{ op: 'cpu', n: 50, x: 1 }, null],
  [{ op: 'some' }, null],
  [{ op: 'max' }, null],
  [{ op: 'status' }, null],
  [{ op: 'info' }, null],
  [{ op: 'OFF' }, null],
  [{ op: 'off; rm -rf /' }, null],
  [{ op: ' off' }, null],
  [{ op: ['off'] }, null],
  [{ cpu: 50 }, null],
  [{}, null],
  [['off'], null],
  ['off', null],
  [null, null],
  [42, null],
];

test('allowlist: exactly the dashboard vectors', () => {
  for (const [input, argv] of VECTORS) {
    const c = r.parseShareCmd(input);
    assert.deepEqual(c === null ? null : r.shareArgv(c), argv, JSON.stringify(input));
  }
});

test('config: shareControl must be a boolean, shareCmd an absolute path', () => {
  const ok = { name: 'air', url: 'wss://x.example/ingest', key: 'k'.repeat(40) };
  assert.deepEqual(r.validateConfig({ ...ok, shareControl: true, shareCmd: '/usr/local/bin/rdocker-share' }), []);
  assert.equal(r.validateConfig({ ...ok, shareControl: 'yes' }).length, 1);
  assert.equal(r.validateConfig({ ...ok, shareCmd: 'rdocker-share' }).length, 1);
});

// ---- who may run the switch
const UID = 501;
const st = (o) => ({ isFile: () => o.kind === 'file', isDirectory: () => o.kind === 'dir', uid: o.uid ?? UID, mode: o.mode ?? 0o100755 });
const fsOf = (over = {}) => {
  const tree = {
    '/Users/Shared/rdocker/share': st({ kind: 'file', mode: 0o100644 }),
    '/Users/Shared/rdocker': st({ kind: 'dir', mode: 0o40755 }),
    '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: 0 }),
    ...over,
  };
  const get = (p) => {
    if (!tree[p]) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
    return tree[p];
  };
  return { lstat: get, stat: get };
};
const check = (cfg, deps = {}) => r.shareControlCheck(cfg, { platform: 'darwin', uid: UID, ...fsOf(), ...deps });

test('check: only with shareControl:true, on macOS, not root, as the owner of the share file and folder', () => {
  assert.deepEqual(check({ shareControl: true }), { ok: true, cmd: '/usr/local/bin/rdocker-share' });
  assert.equal(check({}).ok, false);
  assert.equal(check({ shareControl: 'true' }).ok, false);
  assert.equal(check({ shareControl: false }).ok, false);
  assert.match(check({ shareControl: true }, { platform: 'linux' }).why, /not a Mac/);
  assert.match(check({ shareControl: true }, { uid: 0 }).why, /root/);
  // ethanair: the reporter runs as rd (uid 502), the share file belongs to its owner (501)
  assert.match(check({ shareControl: true }, { uid: 502 }).why, /not owned by this user/);
  assert.match(check({ shareControl: true }, fsOf({ '/Users/Shared/rdocker': st({ kind: 'dir', uid: 0 }) })).why, /\/Users\/Shared\/rdocker is not owned/);
  assert.match(check({ shareControl: true }, fsOf({ '/Users/Shared/rdocker/share': undefined })).why, /missing/);
  // a symlinked share file (lstat sees the link) is refused
  assert.match(check({ shareControl: true }, fsOf({ '/Users/Shared/rdocker/share': st({ kind: 'link' }) })).why, /not a regular file/);
});

test('check: rdocker-share must be an executable owned by root or this user, not group/other writable', () => {
  assert.match(check({ shareControl: true }, fsOf({ '/usr/local/bin/rdocker-share': undefined })).why, /missing/);
  assert.match(check({ shareControl: true }, fsOf({ '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: 0, mode: 0o100777 }) })).why, /writable/);
  assert.match(check({ shareControl: true }, fsOf({ '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: 0, mode: 0o100644 }) })).why, /not an executable/);
  assert.match(check({ shareControl: true }, fsOf({ '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: 502 }) })).why, /not owned by root or this user/);
  assert.equal(check({ shareControl: true }, fsOf({ '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: UID, mode: 0o100700 }) })).ok, true);
  const custom = check({ shareControl: true, shareCmd: '/opt/x/rs' }, fsOf({ '/opt/x/rs': st({ kind: 'file', uid: 0 }) }));
  assert.deepEqual(custom, { ok: true, cmd: '/opt/x/rs' });
});

// ---- orders
const T = 1_800_000_000_000;
const N = (i) => i.toString(16).padStart(32, '0');
function ctl({ enabled = true, result = { ok: true, out: 'Sharing is LOW' }, clock = { t: T } } = {}) {
  const calls = [];
  let gate = null;
  const c = r.createShareControl(
    { shareControl: enabled },
    {
      check: () => (enabled ? { ok: true, cmd: '/usr/local/bin/rdocker-share' } : { ok: false, why: 'shareControl is not enabled in reporter.json' }),
      run: async (cmd, args) => {
        calls.push([cmd, ...args]);
        if (gate) await gate;
        return result;
      },
      now: () => clock.t,
      log: () => {},
    },
  );
  return { c, calls, clock, hold: () => { let open; gate = new Promise((res) => (open = res)); return () => { gate = null; open(); }; } };
}
const order = (i, cmd, exp = T + 60_000) => ({ t: 'share', nonce: N(i), exp, cmd });

test('order: runs the allowlisted argv and acks with the nonce', async () => {
  const { c, calls } = ctl();
  assert.deepEqual(await c.handle(order(1, { op: 'low' })), { t: 'share-ack', nonce: N(1), ok: true, code: 'ok', out: 'Sharing is LOW' });
  assert.deepEqual(await c.handle(order(2, { op: 'cpu', n: 75 })), { t: 'share-ack', nonce: N(2), ok: true, code: 'ok', out: 'Sharing is LOW' });
  assert.deepEqual(calls, [['/usr/local/bin/rdocker-share', 'low'], ['/usr/local/bin/rdocker-share', 'cpu', '75']]);
  assert.equal(c.enabled(), true);
});

test('order: a failing switch is acked as failed', async () => {
  const { c } = ctl({ result: { ok: false, out: 'rdocker share: could not write' } });
  assert.deepEqual(await c.handle(order(1, { op: 'off' })), { t: 'share-ack', nonce: N(1), ok: false, code: 'failed', out: 'rdocker share: could not write' });
});

test('order: refused when the owner did not opt in; nothing runs', async () => {
  const { c, calls } = ctl({ enabled: false });
  const a = await c.handle(order(1, { op: 'low' }));
  assert.equal(a.code, 'disabled');
  assert.equal(a.ok, false);
  assert.equal(c.enabled(), false);
  assert.deepEqual(calls, []);
});

test('order: replays, expired orders, far-future expiry and bad nonces are refused', async () => {
  const { c, calls, clock } = ctl();
  await c.handle(order(1, { op: 'low' }));
  assert.equal((await c.handle(order(1, { op: 'low' }))).code, 'replay');
  assert.equal((await c.handle(order(2, { op: 'low' }, T - 10_000))).code, 'expired');
  assert.equal((await c.handle(order(3, { op: 'low' }, T + 10 * 60_000))).code, 'expired');
  assert.equal((await c.handle(order(4, { op: 'low' }, 'soon'))).code, 'expired');
  assert.equal((await c.handle(order(2, { op: 'low' }))).code, 'replay'); // a refused nonce stays used
  assert.equal(await c.handle({ t: 'share', nonce: 'nope', exp: T + 1000, cmd: { op: 'low' } }), null);
  assert.equal(await c.handle({ t: 'share', exp: T + 1000, cmd: { op: 'low' } }), null);
  // within the skew allowance an order just past exp still runs; the nonce is still remembered after
  clock.t = T + 60_000 + 4_000;
  assert.equal((await c.handle(order(5, { op: 'high' }))).code, 'ok');
  clock.t = T + 60_000 + 6_000;
  assert.equal((await c.handle(order(6, { op: 'high' }))).code, 'expired');
  assert.equal((await c.handle(order(1, { op: 'low' }))).code, 'replay');
  assert.deepEqual(calls.length, 2);
});

test('order: off the allowlist is refused without running anything', async () => {
  const { c, calls } = ctl();
  for (const [i, cmd] of [[1, { op: 'status' }], [2, { op: 'cpu', n: '50' }], [3, { op: 'low; reboot' }], [4, 'low'], [5, null]]) {
    assert.equal((await c.handle(order(i, cmd))).code, 'invalid', JSON.stringify(cmd));
  }
  assert.deepEqual(calls, []);
});

test('order: one at a time', async () => {
  const { c, calls, hold } = ctl();
  const release = hold();
  const first = c.handle(order(1, { op: 'low' }));
  await new Promise((res) => setImmediate(res));
  assert.equal((await c.handle(order(2, { op: 'high' }))).code, 'busy');
  release();
  assert.equal((await first).code, 'ok');
  assert.equal(calls.length, 1);
});

// ---- the runner
test('runShare: argv only (no shell), PATH + LC_ALL only in the env', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rd-share-env-'));
  const script = path.join(tmp, 'dump.sh');
  fs.writeFileSync(script, '#!/bin/sh\nprintf "%s|" "$@"; /usr/bin/env | /usr/bin/sort | /usr/bin/tr "\\n" " "\n', { mode: 0o755 });
  const out = await r.runShare(script, ['low; touch /tmp/pwned', '$(id)']);
  assert.equal(out.ok, true);
  assert.match(out.out, /^low; touch \/tmp\/pwned\|\$\(id\)\|/); // passed through verbatim as two argv words
  const vars = out.out.split('|').pop().trim().split(' ').map((kv) => kv.split('=')[0]).filter((k) => !['PWD', 'SHLVL', '_', '__CF_USER_TEXT_ENCODING', 'OLDPWD'].includes(k));
  assert.deepEqual(vars.sort(), ['LC_ALL', 'PATH']);
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('runShare: killed at its timeout, exit codes become failures', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rd-share-to-'));
  const slow = path.join(tmp, 'slow.sh');
  fs.writeFileSync(slow, '#!/bin/sh\nexec /bin/sleep 5\n', { mode: 0o755 });
  const fail = path.join(tmp, 'fail.sh');
  fs.writeFileSync(fail, '#!/bin/sh\necho "rdocker share: cpu must be 10-100" >&2\nexit 2\n', { mode: 0o755 });
  const t0 = Date.now();
  assert.deepEqual(await r.runShare(slow, [], 300), { ok: false, out: 'timed out after 0.3s' });
  assert.ok(Date.now() - t0 < 3000);
  assert.deepEqual(await r.runShare(fail, ['cpu', '5']), { ok: false, out: 'rdocker share: cpu must be 10-100' });
  fs.rmSync(tmp, { recursive: true, force: true });
});

// ---- lend.ram: what the switch shows
test('shareRamGb matches rdocker-share info (presets per machine size, custom, off, no file)', () => {
  const GB = 1024 ** 3;
  assert.equal(r.shareRamGb(null, 16 * GB), null);
  assert.equal(r.shareRamGb('off', 16 * GB), null);
  assert.equal(r.shareRamGb('cpu=50', 16 * GB), null);
  assert.equal(r.shareRamGb('cpu=50 ram=6', 16 * GB), 6);
  assert.equal(r.shareRamGb('ram=4', 16 * GB), 4);
  assert.equal(r.shareRamGb('ram=999', 16 * GB), null); // invalid = off
  assert.equal(r.shareRamGb('some', 16 * GB), 8);
  for (const mem of [8, 16, 24, 64]) {
    const res = spawnSync('/bin/sh', [SHARE_SH, 'info'], {
      env: { PATH: '/usr/bin:/bin', RR_SHARE_FILE: '/nonexistent/share', RR_SYSCTL_hw_memsize: String(mem * GB), RR_SYSCTL_hw_logicalcpu: '8', RR_OS: 'linux' },
      encoding: 'utf8',
    });
    for (const p of ['low', 'medium', 'high']) {
      const want = new RegExp(`^p_${p}=\\d+ (\\d*)$`, 'm').exec(res.stdout)?.[1];
      assert.equal(String(r.shareRamGb(p, mem * GB)), want, `${p} on ${mem} GB`);
    }
  }
});

// ---- one real round trip through rdocker-share.sh (macOS: the check needs a Mac and file ownership)
test('real switch: a low order rewrites the share file, stop asks for the stop', { skip: process.platform !== 'darwin' || process.getuid() === 0 }, async () => {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'rd-share-real-')));
  const file = path.join(tmp, 'share');
  fs.writeFileSync(file, 'off\n');
  // the runner passes no env through, so a wrapper points the switch at the temp file
  const wrap = path.join(tmp, 'rdocker-share');
  fs.writeFileSync(wrap, `#!/bin/sh\nRR_SHARE_FILE='${file}' RR_SLOTS_DIR='${tmp}/slots' exec /bin/sh '${SHARE_SH}' "$@"\n`, { mode: 0o755 });
  fs.chmodSync(wrap, 0o755);
  fs.chmodSync(tmp, 0o755);
  const c = r.createShareControl({ shareControl: true, shareFile: file, shareCmd: wrap }, { log: () => {} });
  assert.equal(c.enabled(), true);
  const now = Date.now();
  const a = await c.handle({ t: 'share', nonce: N(1), exp: now + 60_000, cmd: { op: 'low' } });
  assert.equal(a.code, 'ok', a.out);
  assert.match(a.out, /Sharing is LOW/);
  assert.equal(fs.readFileSync(file, 'utf8'), 'low\n');
  const b = await c.handle({ t: 'share', nonce: N(2), exp: now + 60_000, cmd: { op: 'cpu', n: 50 } });
  assert.equal(b.code, 'ok', b.out);
  assert.match(fs.readFileSync(file, 'utf8'), /^cpu=50 ram=\d+\n$/);
  const s = await c.handle({ t: 'share', nonce: N(3), exp: now + 60_000, cmd: { op: 'stop' } });
  assert.equal(s.code, 'ok', s.out);
  assert.equal(fs.readFileSync(file, 'utf8'), 'off\n');
  assert.ok(fs.existsSync(path.join(tmp, 'stop-jobs')));
  fs.rmSync(tmp, { recursive: true, force: true });
});
