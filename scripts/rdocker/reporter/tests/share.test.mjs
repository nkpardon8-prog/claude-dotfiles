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

test('config: shareControl must be a boolean', () => {
  const ok = { name: 'air', url: 'wss://x.example/ingest', key: 'k'.repeat(40) };
  assert.deepEqual(r.validateConfig({ ...ok, shareControl: true }), []);
  assert.equal(r.validateConfig({ ...ok, shareControl: 'yes' }).length, 1);
});

test('config: controlOnly must be a boolean and needs shareControl', () => {
  const ok = { name: 'ethanair', url: 'wss://x.example/ingest', key: 'k'.repeat(40) };
  assert.deepEqual(r.validateConfig({ ...ok, shareControl: true, controlOnly: true }), []);
  assert.deepEqual(r.validateConfig({ ...ok, controlOnly: true }), ['controlOnly needs shareControl: true']);
  assert.deepEqual(r.validateConfig({ ...ok, shareControl: false, controlOnly: true }), ['controlOnly needs shareControl: true']);
  assert.deepEqual(r.validateConfig({ ...ok, shareControl: true, controlOnly: 'yes' }), ['controlOnly: true or false']);
});

test('hello: a control-only helper signs the rd-ctl prefix and says ctl:true; a stats hello does neither', async () => {
  const { createHmac } = await import('node:crypto');
  const key = 'k'.repeat(40);
  const nonce = 'a'.repeat(32);
  const h = r.signHello('ethanair', key, 1_700_000_000, nonce, true);
  assert.equal(h.ctl, true);
  assert.equal(h.sig, createHmac('sha256', key).update(`rd-ctl-v1|ethanair|1700000000|${nonce}`).digest('hex'));
  assert.equal(h.sig, '033f0edbf1614a9d82a2f034844e4103d7d12c92eb72ba469297587a124b1693'); // the same vector as dashboard tests/share-control.test.ts
  const s = r.signHello('ethanair', key, 1_700_000_000, nonce);
  assert.equal('ctl' in s, false);
  assert.equal(s.sig, createHmac('sha256', key).update(`rd-ingest-v1|ethanair|1700000000|${nonce}`).digest('hex'));
  assert.notEqual(h.sig, s.sig);
});

// ---- who may run the switch
const UID = 501;
const st = (o) => ({ isFile: () => o.kind === 'file', isDirectory: () => o.kind === 'dir', uid: o.uid ?? UID, mode: o.mode ?? 0o100755 });
const TREE = {
  '/Users/Shared/rdocker/share': st({ kind: 'file', mode: 0o100644 }),
  '/Users/Shared/rdocker': st({ kind: 'dir', mode: 0o40755 }),
  '/usr/local/bin/rdocker-share': st({ kind: 'file', uid: 0 }),
  '/usr/local/bin': st({ kind: 'dir', uid: 0, mode: 0o40755 }),
  '/usr/local': st({ kind: 'dir', uid: 0, mode: 0o40755 }),
  '/usr': st({ kind: 'dir', uid: 0, mode: 0o40755 }),
  '/Users/Shared': st({ kind: 'dir', uid: 0, mode: 0o41777 }),
  '/Users': st({ kind: 'dir', uid: 0, mode: 0o40755 }),
  '/': st({ kind: 'dir', uid: 0, mode: 0o40755 }),
};
const lstatOf = (over = {}) => {
  const tree = { ...TREE, ...over };
  return (p) => {
    if (!tree[p]) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
    return tree[p];
  };
};
const CFG = { shareControl: true, url: 'wss://spine.example/ingest' };
const check = (cfg = CFG, deps = {}) => r.shareControlCheck(cfg, { platform: 'darwin', uid: UID, euid: UID, user: 'ethanball', lstat: lstatOf(), acl: () => false, ...deps });
const why = (over, deps = {}) => check(CFG, { lstat: lstatOf(over), ...deps }).why ?? 'ok';

test('check: only with shareControl:true over wss, on macOS, not root, as the owner of the share file and folder', () => {
  assert.deepEqual(check(), { ok: true, cmd: '/usr/local/bin/rdocker-share' });
  assert.equal(check({ url: CFG.url }).ok, false);
  assert.equal(check({ ...CFG, shareControl: 'true' }).ok, false);
  assert.equal(check({ ...CFG, shareControl: false }).ok, false);
  assert.match(check({ ...CFG, url: 'ws://localhost:8787/ingest' }).why, /wss/);
  assert.match(check(CFG, { platform: 'linux' }).why, /not a Mac/);
  assert.match(check(CFG, { uid: 0, euid: 0 }).why, /root/);
  // The pool user is refused by name even when it owns both paths (UID matches the tree).
  assert.match(check(CFG, { user: 'rd' }).why, /pool user \(rd\)/);
  assert.match(check({ ...CFG, poolUser: 'pool2' }, { user: 'pool2' }).why, /pool user/);
  assert.match(check(CFG, { user: null }).why, /pool user \(unknown\)/);
  assert.match(check(CFG, { euid: 0 }).why, /root/);
  assert.match(check(CFG, { euid: 502 }).why, /mixed/);
  // ethanair: the reporter runs as rd (uid 502), the share file belongs to its owner (501)
  assert.match(check(CFG, { uid: 502, euid: 502 }).why, /not owned by this user/);
  assert.match(why({ '/Users/Shared/rdocker': st({ kind: 'dir', uid: 0 }) }), /not owned by this user/);
  assert.match(why({ '/Users/Shared/rdocker/share': undefined }), /missing/);
  assert.match(why({ '/Users/Shared/rdocker/share': st({ kind: 'link' }) }), /not a regular file/); // lstat: a symlink is refused
  assert.match(why({ '/Users/Shared/rdocker': st({ kind: 'dir', mode: 0o40775 }) }), /writable by group/);
  assert.match(why({ '/Users/Shared/rdocker/share': st({ kind: 'file', mode: 0o100666 }) }), /writable by group/);
  // the config cannot move the checked file or the program
  assert.equal(check({ ...CFG, shareFile: '/tmp/mine', shareCmd: '/tmp/x' }).ok, true);
  assert.equal(check({ ...CFG, shareFile: '/tmp/mine', shareCmd: '/tmp/x' }).cmd, '/usr/local/bin/rdocker-share');
});

test('check: rdocker-share must be a root/own, non-set-id, non-symlink executable in a root-owned folder, none writable by others', () => {
  const C = '/usr/local/bin/rdocker-share';
  assert.match(why({ [C]: undefined }), /missing/);
  assert.match(why({ [C]: st({ kind: 'link', uid: 0 }) }), /not an executable/);
  assert.match(why({ [C]: st({ kind: 'file', uid: 0, mode: 0o100777 }) }), /writable/);
  assert.match(why({ [C]: st({ kind: 'file', uid: 0, mode: 0o100644 }) }), /not an executable/);
  assert.match(why({ [C]: st({ kind: 'file', uid: 0, mode: 0o104755 }) }), /set-id/);
  assert.match(why({ [C]: st({ kind: 'file', uid: 502 }) }), /not owned by root or this user/);
  assert.match(why({ '/usr/local/bin': st({ kind: 'dir', uid: 502 }) }), /folder owned by root/);
  assert.match(why({ '/usr/local/bin': st({ kind: 'dir', uid: 0, mode: 0o40777 }) }), /writable/);
  assert.equal(why({ [C]: st({ kind: 'file', uid: UID, mode: 0o100700 }) }), 'ok');
});

test('check: every folder above both paths is root/own and not open to others unless sticky; no ACLs', () => {
  assert.equal(why({}), 'ok'); // /Users/Shared 1777 (sticky) is fine
  assert.match(why({ '/Users/Shared': st({ kind: 'dir', uid: 0, mode: 0o40777 }) }), /\/Users\/Shared is writable/);
  assert.match(why({ '/usr/local': st({ kind: 'dir', uid: 502 }) }), /\/usr\/local is not owned/);
  assert.match(why({ '/usr/local': st({ kind: 'link', uid: 0 }) }), /\/usr\/local is not a folder/);
  assert.match(why({ '/Users': st({ kind: 'dir', uid: 0, mode: 0o40775 }) }), /\/Users is writable/);
  assert.match(check(CFG, { acl: () => true }).why, /ACL/);
  // the ls -lde parser
  const ls = (stdout, status = 0) => () => ({ status, stdout });
  assert.equal(r.hasAcl(['/x'], ls('drwxr-xr-x  5 me  staff  160 Nov 22 10:27 /x\n')), false);
  assert.equal(r.hasAcl(['/x'], ls('drwxr-xr-x+ 5 me  staff  160 Nov 22 10:27 /x\n 0: group:everyone deny delete\n')), true);
  assert.equal(r.hasAcl(['/x'], ls('-rw-r--r--@ 1 me  staff  4 Nov 22 10:24 /x\n')), false);
  assert.equal(r.hasAcl(['/x'], ls('', 1)), true);
});

// ---- orders
const T = 1_800_000_000_000;
const N = (i) => i.toString(16).padStart(32, '0');
const CONN = 'c'.repeat(32);
function ctl({ enabled = true, result = { ok: true, out: 'Sharing is LOW' }, clock = { t: T } } = {}) {
  const calls = [];
  let gate = null;
  const c = r.createShareControl(
    CFG,
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
  const handle = (o, conn = CONN) => c.handle(o, conn);
  return { c, handle, calls, clock, hold: () => { let open; gate = new Promise((res) => (open = res)); return () => { gate = null; open(); }; } };
}
const order = (i, cmd, exp = T + 60_000, conn = CONN) => ({ t: 'share', nonce: N(i), exp, conn, cmd });

test('order: runs the allowlisted argv and acks with the nonce', async () => {
  const { c, handle, calls } = ctl();
  assert.deepEqual(await handle(order(1, { op: 'low' })), { t: 'share-ack', nonce: N(1), ok: true, code: 'ok', out: 'Sharing is LOW' });
  assert.deepEqual(await handle(order(2, { op: 'cpu', n: 75 })), { t: 'share-ack', nonce: N(2), ok: true, code: 'ok', out: 'Sharing is LOW' });
  assert.deepEqual(calls, [['/usr/local/bin/rdocker-share', 'low'], ['/usr/local/bin/rdocker-share', 'cpu', '75']]);
  assert.equal(c.enabled(), true);
});

test('order: only on the connection it was sent to, after the hello was accepted', async () => {
  const { handle, calls } = ctl();
  assert.equal((await handle(order(1, { op: 'low' }), null)).code, 'replay'); // hello not accepted yet
  assert.equal((await handle(order(2, { op: 'low' }, T + 60_000, 'd'.repeat(32)))).code, 'replay'); // another connection's order
  assert.equal((await handle({ ...order(3, { op: 'low' }), conn: undefined })).code, 'replay');
  assert.deepEqual(calls, []);
});

test('order: a failing switch is acked as failed', async () => {
  const { handle } = ctl({ result: { ok: false, out: 'rdocker share: could not write' } });
  assert.deepEqual(await handle(order(1, { op: 'off' })), { t: 'share-ack', nonce: N(1), ok: false, code: 'failed', out: 'rdocker share: could not write' });
});

test('order: refused when the owner did not opt in; nothing runs', async () => {
  const { c, handle, calls } = ctl({ enabled: false });
  const a = await handle(order(1, { op: 'low' }));
  assert.equal(a.code, 'disabled');
  assert.equal(a.ok, false);
  assert.equal(c.enabled(), false);
  assert.deepEqual(calls, []);
});

test('order: replays, expired orders, far-future expiry and bad nonces are refused', async () => {
  const { handle, calls, clock } = ctl();
  await handle(order(1, { op: 'low' }));
  assert.equal((await handle(order(1, { op: 'low' }))).code, 'replay');
  assert.equal((await handle(order(2, { op: 'low' }, T - 1))).code, 'expired');
  assert.equal((await handle(order(3, { op: 'low' }, T + 66_000))).code, 'expired');
  assert.equal((await handle(order(4, { op: 'low' }, 'soon'))).code, 'expired');
  assert.equal((await handle(order(2, { op: 'low' }))).code, 'replay'); // a refused nonce stays used
  assert.equal(await handle({ t: 'share', nonce: 'nope', exp: T + 1000, conn: CONN, cmd: { op: 'low' } }), null);
  assert.equal(await handle({ t: 'share', exp: T + 1000, conn: CONN, cmd: { op: 'low' } }), null);
  // at its expiry it still runs; a moment after it does not; the nonce is remembered after
  clock.t = T + 60_000;
  assert.equal((await handle(order(5, { op: 'high' }))).code, 'ok');
  clock.t = T + 60_001;
  assert.equal((await handle(order(6, { op: 'high' }))).code, 'expired');
  assert.equal((await handle(order(1, { op: 'low' }))).code, 'replay');
  assert.deepEqual(calls.length, 2);
});

test('order: off the allowlist is refused without running anything', async () => {
  const { handle, calls } = ctl();
  for (const [i, cmd] of [[1, { op: 'status' }], [2, { op: 'cpu', n: '50' }], [3, { op: 'low; reboot' }], [4, 'low'], [5, null]]) {
    assert.equal((await handle(order(i, cmd))).code, 'invalid', JSON.stringify(cmd));
  }
  assert.deepEqual(calls, []);
});

test('order: one at a time', async () => {
  const { handle, calls, hold } = ctl();
  const release = hold();
  const first = handle(order(1, { op: 'low' }));
  await new Promise((res) => setImmediate(res));
  assert.equal((await handle(order(2, { op: 'high' }))).code, 'busy');
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
  assert.deepEqual(await r.runShare(slow, [], 300), { ok: false, out: 'timed out after 0.3s; the result is unknown' });
  assert.ok(Date.now() - t0 < 3000);
  // the switch's own children die with it (its process group is killed whole)
  const pidFile = path.join(tmp, 'child.pid');
  const parent = path.join(tmp, 'parent.sh');
  fs.writeFileSync(parent, `#!/bin/sh\n/bin/sleep 30 &\necho $! > '${pidFile}'\nwait\n`, { mode: 0o755 });
  assert.equal((await r.runShare(parent, [], 300)).ok, false);
  const child = Number(fs.readFileSync(pidFile, 'utf8'));
  await new Promise((res) => setTimeout(res, 100));
  assert.throws(() => process.kill(child, 0), /ESRCH/);
  assert.deepEqual(await r.runShare(path.join(tmp, 'nope'), []), { ok: false, out: 'could not start' });
  // the switch's own alarm (1 s here) ends it even when nobody kills it: a 60 s timer stands in for a dead reporter
  const t1 = Date.now();
  assert.deepEqual(await r.runShare(slow, [], 60_000, 1), { ok: false, out: 'killed' });
  assert.ok(Date.now() - t1 < 4000);
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
  const cfg = { shareControl: true, url: 'wss://spine.example/ingest' };
  const c = r.createShareControl(cfg, { check: () => r.shareControlCheck(cfg, { shareFile: file, shareCmd: wrap }), log: () => {} });
  assert.equal(c.enabled(), true);
  const now = Date.now();
  const a = await c.handle({ t: 'share', nonce: N(1), exp: now + 60_000, conn: CONN, cmd: { op: 'low' } }, CONN);
  assert.equal(a.code, 'ok', a.out);
  assert.match(a.out, /Sharing is LOW/);
  assert.equal(fs.readFileSync(file, 'utf8'), 'low\n');
  const b = await c.handle({ t: 'share', nonce: N(2), exp: now + 60_000, conn: CONN, cmd: { op: 'cpu', n: 50 } }, CONN);
  assert.equal(b.code, 'ok', b.out);
  assert.match(fs.readFileSync(file, 'utf8'), /^cpu=50 ram=\d+\n$/);
  const s = await c.handle({ t: 'share', nonce: N(3), exp: now + 60_000, conn: CONN, cmd: { op: 'stop' } }, CONN);
  assert.equal(s.code, 'ok', s.out);
  assert.equal(fs.readFileSync(file, 'utf8'), 'off\n');
  assert.ok(fs.existsSync(path.join(tmp, 'stop-jobs')));
  fs.rmSync(tmp, { recursive: true, force: true });
});
