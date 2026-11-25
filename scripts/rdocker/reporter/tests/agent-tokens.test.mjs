// Agent-token counting in rd-reporter.mjs: Claude Code dedupe, Codex token_count shape, incremental offsets.
// Zero deps: `node --test reporter/tests/`.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import * as r from '../rd-reporter.mjs';

const T = '2026-11-20T12:00:00.000Z';
const day = r.localDay(Date.parse(T));

/** A Claude Code assistant line as written on disk (one per content block, same usage on each). */
const claude = (id, u, ts = T) =>
  JSON.stringify({
    parentUuid: null,
    type: 'assistant',
    timestamp: ts,
    message: { model: 'claude-x', id, type: 'message', role: 'assistant', content: [{ type: 'text', text: 'hi "usage":{ inside text' }], usage: { input_tokens: u[0], cache_creation_input_tokens: u[1], cache_read_input_tokens: u[2], output_tokens: u[3], output_tokens_details: { thinking_tokens: 0 }, iterations: [{ input_tokens: 999, output_tokens: 999 }] } },
  });
const user = (text) => JSON.stringify({ type: 'user', timestamp: T, message: { role: 'user', content: text } });

/** A Codex token_count event (real shape, ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl). */
const codex = (total, last, ts = T) =>
  JSON.stringify({
    timestamp: ts,
    ordinal: 1,
    type: 'event_msg',
    payload: {
      type: 'token_count',
      info: {
        total_token_usage: { input_tokens: total[0], cached_input_tokens: total[1], cache_write_input_tokens: 0, output_tokens: total[2], reasoning_output_tokens: 0, total_tokens: total[0] + total[2] },
        last_token_usage: { input_tokens: last[0], cached_input_tokens: last[1], cache_write_input_tokens: 0, output_tokens: last[2], reasoning_output_tokens: 0, total_tokens: last[0] + last[2] },
        last_usage_includes_reasoning: true,
        model_context_window: 475000,
      },
      rate_limits: { limit_id: 'codex' },
    },
  });

function tree() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rd-tokens-'));
  const c = path.join(dir, 'claude', 'proj');
  const x = path.join(dir, 'codex', '2026', '11', '20');
  fs.mkdirSync(path.join(c, 'sess', 'subagents'), { recursive: true });
  fs.mkdirSync(x, { recursive: true });
  return { dir, claudeDir: path.join(dir, 'claude'), codexDir: path.join(dir, 'codex'), stateFile: path.join(dir, 'state', 'agent-tokens.json'), c, x };
}
const scan = (t) => r.scanAgentTokens({ claudeDir: t.claudeDir, codexDir: t.codexDir, stateFile: t.stateFile, now: Date.parse(T) });

test('claudeUsage reads the top-level usage, not iterations; non-assistant lines are null', () => {
  assert.deepEqual(r.claudeUsage(claude('msg_1', [3, 100, 2000, 50])), { id: 'msg_1', day, out: 50, in: 3, cw: 100, cr: 2000 });
  assert.equal(r.claudeUsage(user('"usage":{')), null);
  assert.equal(r.claudeUsage('{not json "usage":{'), null);
});

test('codexUsage: per-turn last_token_usage, input minus cached, cached separate; other events null', () => {
  const u = r.codexUsage(codex([77980, 45056, 234], [39532, 38272, 133]));
  assert.deepEqual({ out: u.out, in: u.in, cr: u.cr, day: u.day }, { out: 133, in: 39532 - 38272, cr: 38272, day });
  assert.equal(u.total, '77980/45056/234/78214');
  assert.equal(r.codexUsage(JSON.stringify({ timestamp: T, type: 'event_msg', payload: { type: 'token_count', info: null } })), null);
  assert.equal(r.codexUsage(JSON.stringify({ timestamp: T, type: 'event_msg', payload: { type: 'agent_message' } })), null);
});

test('dedupe: one message on several lines counts once; a forked subagent repeating it counts once', async () => {
  const t = tree();
  const a = claude('msg_A', [2, 10, 100, 7]);
  fs.writeFileSync(path.join(t.c, 'sess.jsonl'), [user('go'), a, a, a, claude('msg_B', [1, 0, 50, 3])].join('\n') + '\n');
  fs.writeFileSync(path.join(t.c, 'sess', 'subagents', 'agent-1.jsonl'), [a, claude('msg_C', [0, 0, 0, 1])].join('\n') + '\n');
  const res = await scan(t);
  assert.deepEqual(res.agentTokens.days[day].claude, { out: 11, in: 3, cw: 10, cr: 150 });
  assert.equal(res.agentTokens.since, day);
});

test('codex: a repeated running total is skipped; running totals are never summed', async () => {
  const t = tree();
  const lines = [codex([100, 40, 10], [100, 40, 10]), codex([100, 40, 10], [100, 40, 10]), codex([300, 160, 25], [200, 120, 15])];
  fs.writeFileSync(path.join(t.x, 'rollout-a.jsonl'), lines.join('\n') + '\n');
  const res = await scan(t);
  assert.deepEqual(res.agentTokens.days[day].codex, { out: 25, in: 60 + 80, cr: 160 });
});

test('incremental: only new bytes are read; a half-written last line waits for its newline', async () => {
  const t = tree();
  const f = path.join(t.c, 'sess.jsonl');
  fs.writeFileSync(f, claude('msg_1', [1, 0, 0, 10]) + '\n');
  const first = await scan(t);
  assert.equal(first.files, 1);
  assert.equal(first.agentTokens.days[day].claude.out, 10);

  const again = await scan(t); // nothing changed: the file is not opened
  assert.equal(again.files, 0);
  assert.equal(again.bytes, 0);

  const next = claude('msg_2', [0, 0, 0, 5]);
  fs.appendFileSync(f, next.slice(0, 40)); // a line still being written
  const partial = await scan(t);
  assert.equal(partial.bytes, 0);
  assert.equal(partial.agentTokens.days[day].claude.out, 10);

  fs.appendFileSync(f, next.slice(40) + '\n' + claude('msg_1', [1, 0, 0, 10]) + '\n'); // msg_1 again: a repeat
  const done = await scan(t);
  assert.equal(done.bytes, Buffer.byteLength(next) + 1 + Buffer.byteLength(claude('msg_1', [1, 0, 0, 10])) + 1);
  assert.equal(done.agentTokens.days[day].claude.out, 15);
  const st = JSON.parse(fs.readFileSync(t.stateFile, 'utf8'));
  assert.equal(st.files[f].off, fs.statSync(f).size);
  assert.equal((fs.statSync(t.stateFile).mode & 0o777).toString(8), '600');
});

test('a deleted transcript leaves the state but its days stay; a replaced file is read from 0', async () => {
  const t = tree();
  const f = path.join(t.c, 'sess.jsonl');
  fs.writeFileSync(f, claude('msg_1', [0, 0, 0, 10]) + '\n');
  await scan(t);
  fs.rmSync(f);
  const gone = await scan(t);
  assert.equal(gone.agentTokens.days[day].claude.out, 10);
  assert.equal(Object.keys(JSON.parse(fs.readFileSync(t.stateFile, 'utf8')).files).length, 0);
  fs.writeFileSync(f, claude('msg_9', [0, 0, 0, 4]) + '\n');
  const back = await scan(t);
  assert.equal(back.agentTokens.days[day].claude.out, 14);
});

test('days older than AGENT_TOKENS_DAYS are dropped; local-day bucketing', async () => {
  const t = tree();
  const old = new Date(Date.parse(T) - (r.AGENT_TOKENS_DAYS + 3) * 86_400_000).toISOString();
  fs.writeFileSync(path.join(t.c, 'sess.jsonl'), [claude('msg_old', [0, 0, 0, 1], old), claude('msg_new', [0, 0, 0, 2])].join('\n') + '\n');
  const res = await scan(t);
  assert.deepEqual(Object.keys(res.agentTokens.days), [day]);
  assert.equal(res.agentTokens.since, day); // since = the first day the kept totals cover
  assert.match(r.localDay(Date.parse(T)), /^\d{4}-\d{2}-\d{2}$/);
});

test('validateConfig: agentTokens must be a boolean', () => {
  const base = { name: 'air', url: 'wss://x.example/ingest', key: 'k'.repeat(40) };
  assert.deepEqual(r.validateConfig({ ...base, agentTokens: false }), []);
  assert.deepEqual(r.validateConfig({ ...base, agentTokens: 'no' }), ['agentTokens: true or false']);
});
