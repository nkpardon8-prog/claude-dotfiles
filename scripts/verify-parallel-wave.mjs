#!/usr/bin/env node
// verify-parallel-wave.mjs - the fail-closed gate for the write-wave machinery.
//
// SCHEMA AUTHORITY: docs/wave-plan-schema.md. Every rule below cites the section it
// implements. When this file and that file disagree, that file wins and this file is the
// bug (schema doc, header + section 8).
//
// Three modes:
//   --validate-plan <wave_plan.json> --repo-root <p> --base-sha <sha>   (schema doc, s4)
//   --wave-state <wave-state.json>                                      (schema doc, s6)
//   --log-decision <serial|fan_out> --reason <token> --repo-root <p>    (schema doc, s7.2)
//
// Exit codes (schema doc, s2.5): 0 pass, 1 rule violation, 2 usage or environment error.
// BOTH 1 and 2 block the wave - there is no advisory exit.
//
// Every invocation that names a mode appends EXACTLY ONE event line to
// <waves dir>/rework.log, on both exit paths (schema doc, s7). An invocation that names no
// mode at all cannot be attributed to a tool_mode in the closed set, so it prints usage and
// exits 2 without an event - inventing a fourth tool_mode would break the closed set the
// measurement contract rests on.
//
// Requirements: node >= 18, zero dependencies. All git name lists are read with -z and split
// on NUL, and every diff pins --no-renames so a rename counts BOTH sides (schema doc, s6.5).

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// ---------------------------------------------------------------------------
// Constants - all frozen by docs/wave-plan-schema.md
// ---------------------------------------------------------------------------

const SCHEMA_VERSION = 'parallelizer.v1.1';
const WAVE_WIDTH_MAX = 4; // s2.5 - a constant, never an input
const EVENT_CAP_BYTES = 480; // s7.1 - the line INCLUDING its newline
const REPO_ROOT_TRUNC_CHARS = 80; // s7.1 overflow rule, step 1
const CHUNK_ID_RE = /^[a-z0-9][a-z0-9-]{0,31}$/; // s2.1
const SHA40_RE = /^[0-9a-f]{40}$/;
const GLOB_RE = /[*?[\]]/; // s2.2
const CONFIDENCE = new Set(['high', 'medium', 'low']); // s2.5
const VERDICTS = new Set(['FAN_OUT', 'SERIAL_CORRECT']); // s2.5
const DECISIONS = new Set(['serial', 'fan_out']); // s7 decision field
const TOOL_MODES = new Set(['validate-plan', 'wave-state', 'log-decision']); // s7
const REASONS = new Set([ // s7.2 - CLOSED set; an unknown token is rejected
  // orchestrator serial-gate + checker-pass tokens (carried from v1)
  'lt2_chunks', 'no_review', 'dirty_repo_root', 'merge_in_progress', 'pct_unknown',
  'pct_over_60', 'stale_wave', 'dotfiles_unpaused', 'serial_correct',
  'low_confidence', 'fan_out',
  // v1.1 - de-aliased outcome tokens (schema doc s7.2, change control s8). Each names a
  // DISTINCT event that v1 flattened into `malformed`/`fan_out`:
  'rule_violation',   // a real schema/rule violation of a plan or a wave-state (exit 1)
  'usage_error',      // a CLI/argument usage error (exit 2)
  'io_error',         // unreadable/unparseable input, or a git/environment failure (exit 2)
  'merge_success',    // merge-wave integrated the wave (exit 0)
  'merge_conflict',   // merge-wave hit a conflict/refusal and merged nothing further (exit 1)
  // retained as the fail-closed fallback when an unknown token reaches writeEvent
  'malformed',
]);
const METACHARS = [';', '|', '&', '$', '`', '>', '<', '\n']; // s2.4 stage 1
const PKG_RUNNERS = ['npm', 'yarn', 'pnpm']; // s2.4 stage 2
const TYPECHECK_SCRIPTS = ['typecheck', 'tsc', 'lint', 'check', 'test']; // s2.4 floor

const WAVES_DIR = process.env.PARALLEL_WAVES_DIR && process.env.PARALLEL_WAVES_DIR.length > 0
  ? process.env.PARALLEL_WAVES_DIR
  : path.join(os.homedir(), '.claude', 'parallel-waves');

// ---------------------------------------------------------------------------
// Event log (schema doc, s7)
// ---------------------------------------------------------------------------

// Everything the event needs, filled in as the run learns it. The catch-all handler reads
// this, so an unexpected throw still produces exactly one honest event.
const ctx = {
  tool_mode: null, // null => no mode named => no event (see header)
  decision: null,
  verdict: null,
  repo_root: '',
  wave: null,
};

let eventWritten = false;

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function encodeEvent(ev) {
  return `${JSON.stringify(ev)}\n`;
}

// s7.1: fixed key ORDER, then the deterministic overflow rule. `truncated` is added last,
// as the ninth key; object spread preserves the original position of repo_root.
function buildEventLine(exitCode, reason) {
  const base = {
    ts: nowIso(),
    tool_mode: ctx.tool_mode,
    decision: DECISIONS.has(ctx.decision) ? ctx.decision : null,
    verdict: VERDICTS.has(ctx.verdict) ? ctx.verdict : null,
    exit: exitCode,
    repo_root: typeof ctx.repo_root === 'string' ? ctx.repo_root : '',
    wave: Number.isInteger(ctx.wave) ? ctx.wave : null,
    reason,
  };
  let line = encodeEvent(base);
  if (Buffer.byteLength(line, 'utf8') <= EVENT_CAP_BYTES) return line;
  const step1 = { ...base, repo_root: base.repo_root.slice(-REPO_ROOT_TRUNC_CHARS), truncated: true };
  line = encodeEvent(step1);
  if (Buffer.byteLength(line, 'utf8') <= EVENT_CAP_BYTES) return line;
  return encodeEvent({ ...step1, repo_root: '' });
}

function writeEvent(exitCode, reason) {
  if (eventWritten) return; // exactly one event per invocation
  if (!TOOL_MODES.has(ctx.tool_mode)) return; // no mode named - see header
  eventWritten = true;
  const safeReason = REASONS.has(reason) ? reason : 'malformed';
  try {
    fs.mkdirSync(WAVES_DIR, { recursive: true });
    fs.appendFileSync(path.join(WAVES_DIR, 'rework.log'), buildEventLine(exitCode, safeReason));
  } catch (err) {
    // The event log is telemetry; losing it must never change a verdict. Say so loudly and
    // keep the exit code the checker already decided.
    process.stderr.write(`verify-parallel-wave: WARNING - could not append event to ${WAVES_DIR}/rework.log: ${err && err.message}\n`);
  }
}

function finish(exitCode, reason) {
  writeEvent(exitCode, reason);
  process.exit(exitCode);
}

function usage(message) {
  if (message) process.stderr.write(`verify-parallel-wave: ${message}\n`);
  process.stderr.write(
    'usage:\n'
    + '  verify-parallel-wave.mjs --validate-plan <wave_plan.json> --repo-root <path> --base-sha <sha>\n'
    + '  verify-parallel-wave.mjs --wave-state <wave-state.json>\n'
    + '  verify-parallel-wave.mjs --log-decision <serial|fan_out> --reason <token> --repo-root <path>\n'
    + '  verify-parallel-wave.mjs --emit-event --exit <n> --reason <token> --repo-root <path> --wave <n>\n',
  );
  finish(2, 'usage_error');
}

// ---------------------------------------------------------------------------
// git (execFileSync, never a shell)
// ---------------------------------------------------------------------------

function gitRun(repo, args) {
  try {
    const out = execFileSync('git', ['-C', repo, ...args], {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { ok: true, code: 0, out, err: '' };
  } catch (err) {
    return {
      ok: false,
      code: typeof err.status === 'number' ? err.status : 2,
      out: err.stdout ? String(err.stdout) : '',
      err: err.stderr ? String(err.stderr) : String((err && err.message) || 'git failed'),
    };
  }
}

// Every git NAME LIST is read with -z and split here. Splitting on newlines would corrupt
// any path containing one.
function splitZ(out) {
  return String(out).split('\0').filter((s) => s.length > 0);
}

function isGitRepo(dir) {
  return fs.existsSync(dir) && gitRun(dir, ['rev-parse', '--git-dir']).ok;
}

function isAncestor(repo, ancestorSha, descendantRef) {
  return gitRun(repo, ['merge-base', '--is-ancestor', ancestorSha, descendantRef]).ok;
}

function revParse(repo, ref) {
  const r = gitRun(repo, ['rev-parse', ref]);
  return r.ok ? r.out.trim() : null;
}

// s6.11 / s6.3: `git status --porcelain -z`. Records are `XY <path>\0`, and a rename or copy
// record is followed by a second record holding the ORIGINAL path. Both sides are returned:
// a rename that moves a file out of a declared set is a real change to both paths.
function statusPaths(repo, includeUntracked) {
  const args = ['status', '--porcelain', '-z'];
  if (!includeUntracked) args.push('--untracked-files=no');
  const r = gitRun(repo, args);
  if (!r.ok) return null;
  const records = splitZ(r.out);
  const paths = [];
  for (let i = 0; i < records.length; i += 1) {
    const rec = records[i];
    if (rec.length < 4) { paths.push(rec); continue; }
    const xy = rec.slice(0, 2);
    paths.push(rec.slice(3));
    if (xy.includes('R') || xy.includes('C')) {
      i += 1;
      if (i < records.length) paths.push(records[i]);
    }
  }
  return paths;
}

// ---------------------------------------------------------------------------
// Path rules (schema doc, s2.2 and s2.3)
// ---------------------------------------------------------------------------

function normalizePath(raw) {
  let e = String(raw);
  while (e.startsWith('./')) e = e.slice(2); // s2.2: "./" prefixes normalized away
  return e;
}

// Returns [] when the entry is legal. `allowPrefix` is false for reads[] (s2.2: a subtree
// read would fence off a directory the chunk merely consumes).
function pathIssues(raw, allowPrefix) {
  if (typeof raw !== 'string') return ['is not a string'];
  const issues = [];
  if (raw.includes('\\')) issues.push('contains a backslash (Windows path)');
  if (raw.startsWith('/')) issues.push('is absolute');
  const e = normalizePath(raw);
  if (e === '' || e === '.') issues.push('is empty or "." after normalization');
  if (GLOB_RE.test(e)) issues.push('contains a glob metacharacter');
  const isPrefix = e.endsWith('/');
  if (isPrefix && !allowPrefix) issues.push('is a subtree prefix but only exact file paths are allowed here');
  const body = isPrefix ? e.slice(0, -1) : e;
  if (body === '') {
    if (e !== '' && e !== '.') issues.push('is empty or "." after normalization');
  } else {
    const segs = body.split('/');
    if (segs.some((s) => s === '')) issues.push('contains an empty segment');
    if (segs.some((s) => s === '..')) issues.push('contains a ".." segment');
    // s2.2: a "." segment (e.g. src/./x) is rejected too - normalizePath only strips a
    // LEADING "./", so a mid-path "." would otherwise dodge the rule-9 write-into-read check.
    if (segs.some((s) => s === '.')) issues.push('contains a "." segment');
  }
  return issues;
}

// Validates one declared list; returns { entries, issues } with entries NORMALIZED.
function validatePathList(list, label, allowPrefix) {
  const issues = [];
  const entries = [];
  if (!Array.isArray(list)) return { entries, issues: [`${label} is not an array`] };
  const seen = new Set();
  for (const raw of list) {
    const found = pathIssues(raw, allowPrefix);
    for (const f of found) issues.push(`${label} entry ${JSON.stringify(raw)} ${f}`);
    if (typeof raw !== 'string') continue;
    const norm = normalizePath(raw);
    if (seen.has(norm)) issues.push(`${label} entry ${JSON.stringify(raw)} duplicates another entry`);
    seen.add(norm);
    entries.push(norm);
  }
  return { entries, issues };
}

// s2.3 matches(e, p)
function matches(entry, p) {
  return entry.endsWith('/') ? p.startsWith(entry) : p === entry;
}

// s2.3 overlap(a, b)
function overlaps(a, b) {
  if (a === b) return true;
  if (a.endsWith('/') && b.startsWith(a)) return true;
  if (b.endsWith('/') && a.startsWith(b)) return true;
  return false;
}

// Every overlapping pair between two declared sets - reported, not just counted, because the
// operator has to see WHICH paths collided.
function overlappingPairs(setA, setB) {
  const pairs = [];
  for (const a of setA) for (const b of setB) if (overlaps(a, b)) pairs.push([a, b]);
  return pairs;
}

// s2.3 Divergence 7: a trailing-"/" entry is valid ONLY for a directory absent at the sha.
function dirExistsAtSha(repo, sha, dir) {
  const r = gitRun(repo, ['ls-tree', '-z', sha, '--', dir]);
  if (!r.ok) return null; // caller turns this into an environment error
  return splitZ(r.out).length > 0;
}

// Resolve symlinks where the path exists so that /tmp vs /private/tmp (macOS) does not turn
// an identical directory into an inequality.
function realPathOrResolve(p) {
  const abs = path.resolve(p);
  try { return fs.realpathSync(abs); } catch { return abs; }
}

function samePath(a, b) {
  if (path.resolve(a) === path.resolve(b)) return true;
  return realPathOrResolve(a) === realPathOrResolve(b);
}

// s5: the dirty-tree exemption applies ONLY when impl_plan_path resolves UNDER repo_root.
function relativeUnder(root, target) {
  const rel = path.relative(realPathOrResolve(root), realPathOrResolve(target));
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join('/');
}

// ---------------------------------------------------------------------------
// Small shape helpers
// ---------------------------------------------------------------------------

const isStr = (v) => typeof v === 'string';
const isNonEmptyStr = (v) => typeof v === 'string' && v.length > 0;
const isArr = Array.isArray;
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = (v) => Number.isInteger(v);

function readJson(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    return { ok: false, reason: `cannot read ${file}: ${err && err.message}` };
  }
  try {
    return { ok: true, value: JSON.parse(raw) };
  } catch (err) {
    return { ok: false, reason: `cannot parse ${file} as JSON: ${err && err.message}` };
  }
}

function report(violations) {
  for (const v of violations) process.stderr.write(`VIOLATION ${v}\n`);
}

// ---------------------------------------------------------------------------
// Plan<->state binding sidecar (schema doc, s4a + s6a - the C2 fix)
// ---------------------------------------------------------------------------

// The canonical per-wave content whose sha256 binds a runtime wave_state to the wave_plan that
// --validate-plan blessed. It is the intersection of what BOTH artifacts carry verbatim:
// repo_root, the wave's shared_hazard_paths, the wave number, and each chunk's id + normalized
// exclusive_paths + reads. base_sha is DELIBERATELY excluded - the orchestrator re-pins it every
// wave (s3.2 ancestry rule), so it legitimately drifts and is verified separately by ancestry.
// Paths are normalized, de-duplicated, and sorted so ordering never changes the hash.
function canonicalWaveHash(repoRoot, sharedHazardPaths, waveNum, chunks) {
  const normList = (list) => {
    const seen = new Set();
    const out = [];
    for (const raw of Array.isArray(list) ? list : []) {
      if (typeof raw !== 'string') continue;
      const n = normalizePath(raw);
      if (seen.has(n)) continue;
      seen.add(n);
      out.push(n);
    }
    return out.sort();
  };
  const normChunks = (Array.isArray(chunks) ? chunks : [])
    .map((c) => ({
      id: typeof (c && c.id) === 'string' ? c.id : '',
      exclusive_paths: normList(c && c.exclusive_paths),
      reads: normList(c && c.reads),
    }))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const canonical = JSON.stringify({
    v: SCHEMA_VERSION,
    repo_root: realPathOrResolve(repoRoot),
    shared_hazard_paths: normList(sharedHazardPaths),
    wave: Number.isInteger(waveNum) ? waveNum : null,
    chunks: normChunks,
  });
  return crypto.createHash('sha256').update(canonical).digest('hex');
}

const sidecarPathFor = (planPath) => `${planPath}.validated`;

// Written by --validate-plan on the exit-0 (fan_out) path: one hash per wave. Best-effort - a
// telemetry-class failure to write must never turn a passing plan into a failing one, but it is
// said loudly so a missing blessing is diagnosable.
function writeSidecar(planPath, plan, repoRoot) {
  const waves = {};
  for (const w of plan.waves) {
    waves[String(w.wave)] = canonicalWaveHash(
      repoRoot, plan.analysis_basis.shared_hazard_paths, w.wave, w.chunks,
    );
  }
  const body = { schema_version: SCHEMA_VERSION, waves };
  try {
    fs.writeFileSync(sidecarPathFor(planPath), `${JSON.stringify(body, null, 2)}\n`);
  } catch (err) {
    process.stderr.write(`verify-parallel-wave: WARNING - could not write sidecar ${sidecarPathFor(planPath)}: ${err && err.message}\n`);
  }
}

// Removed on the exit-1 (rule) path so a plan that FAILS validation cannot leave a stale
// blessing behind that a later wave_state could match.
function removeSidecar(planPath) {
  try { fs.rmSync(sidecarPathFor(planPath), { force: true }); } catch { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Mode: --validate-plan   (schema doc, s3 + s4)
// ---------------------------------------------------------------------------

// s2.4 - one command, two stages. Returns { ok, issue, runScript }.
function commandIssue(cmd, scripts) {
  if (!isNonEmptyStr(cmd)) return { ok: false, issue: 'is not a non-empty string' };
  for (const m of METACHARS) {
    if (cmd.includes(m)) {
      const shown = m === '\n' ? '\\n' : m;
      return { ok: false, issue: `contains the forbidden shell metacharacter "${shown}" (stage 1)` };
    }
  }
  const t = cmd.trim().split(/\s+/);
  if (PKG_RUNNERS.includes(t[0])) {
    if (t[1] !== 'run') return { ok: false, issue: `only the "run" subcommand is allowlisted for ${t[0]} (stage 2)` };
    if (!t[2]) return { ok: false, issue: `${t[0]} run names no script (stage 2)` };
    if (!scripts || !scripts.includes(t[2])) {
      return { ok: false, issue: `"${t[2]}" is not a key in the repo's package.json scripts (stage 2)` };
    }
    return { ok: true, runScript: t[2] };
  }
  if (t[0] === 'npx' && t[1] === 'tsc') return { ok: true };
  if (t[0] === 'node' && t[1] === '--check') return { ok: true };
  if (t[0] === 'bash' && t[1] && /^scripts\/[A-Za-z0-9._-]+-assumptions\/run-all\.sh$/.test(t[1])) return { ok: true };
  if (t[0] === 'make') {
    // s2.4: `make <target>` accepts ONLY a bare target token - no leading dash (so `make -f
    // evil.mk` / `make -C other` cannot select a foreign makefile or directory), no path
    // separator, no flags. Trailing args beyond the target are still permitted.
    if (!t[1]) return { ok: false, issue: 'make names no target (stage 2)' };
    if (t[1].startsWith('-') || !/^[A-Za-z0-9._-]+$/.test(t[1])) {
      return { ok: false, issue: `make target ${JSON.stringify(t[1])} must be a bare target name, not a flag or path (stage 2)` };
    }
    return { ok: true };
  }
  return { ok: false, issue: 'argv prefix is not in the section 2.4 allowlist (stage 2)' };
}

// null => no usable package.json at repo_root: the npm|yarn|pnpm arm never matches and the
// typecheck floor does not apply (s2.4, last paragraph).
function readPackageScripts(repoRoot) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8');
  } catch {
    return null;
  }
  try {
    const j = JSON.parse(raw);
    if (isObj(j) && isObj(j.scripts)) return Object.keys(j.scripts);
    return [];
  } catch {
    return null;
  }
}

// s4 rule 1 - shape. Violations here are `malformed`.
function planShapeIssues(plan) {
  const v = [];
  if (!isObj(plan)) return ['[plan rule 1] the wave_plan is not a JSON object'];
  if (plan.schema_version !== SCHEMA_VERSION) {
    v.push(`[plan rule 1] schema_version must be "${SCHEMA_VERSION}", got ${JSON.stringify(plan.schema_version)}`);
  }
  if (!VERDICTS.has(plan.verdict)) v.push(`[plan rule 1] verdict must be FAN_OUT|SERIAL_CORRECT, got ${JSON.stringify(plan.verdict)}`);
  if (!CONFIDENCE.has(plan.confidence)) v.push(`[plan rule 1] confidence must be high|medium|low, got ${JSON.stringify(plan.confidence)}`);
  if (!isObj(plan.analysis_basis)) v.push('[plan rule 1] analysis_basis is missing or not an object');
  if (!isArr(plan.waves) || plan.waves.length === 0) v.push('[plan rule 1] waves is missing, not an array, or empty');
  if (!isArr(plan.hazards_found)) v.push('[plan rule 1] hazards_found is missing or not an array');
  if (!isArr(plan.serial_reasons) || plan.serial_reasons.some((s) => !isStr(s))) {
    v.push('[plan rule 1] serial_reasons is missing or not an array of strings');
  }

  if (isObj(plan.analysis_basis)) {
    const ab = plan.analysis_basis;
    if (!isNonEmptyStr(ab.repo_root) || !path.isAbsolute(ab.repo_root)) {
      v.push('[plan rule 1] analysis_basis.repo_root must be an absolute path string');
    }
    if (!isStr(ab.base_sha) || !SHA40_RE.test(ab.base_sha)) {
      v.push('[plan rule 1] analysis_basis.base_sha must be a 40-char lowercase hex sha');
    }
    if (!isArr(ab.shared_hazard_paths)) v.push('[plan rule 1] analysis_basis.shared_hazard_paths must be an array');
    if (ab.base_ref !== undefined && !isStr(ab.base_ref)) v.push('[plan rule 1] analysis_basis.base_ref must be a string when present');
    if (ab.plan_path !== undefined && !isStr(ab.plan_path)) v.push('[plan rule 1] analysis_basis.plan_path must be a string when present');
    if (ab.max_wave_width !== undefined && !isInt(ab.max_wave_width)) v.push('[plan rule 1] analysis_basis.max_wave_width must be an integer when present');
  }

  if (isArr(plan.hazards_found)) {
    plan.hazards_found.forEach((h, i) => {
      if (!isObj(h)) { v.push(`[plan rule 1] hazards_found[${i}] is not an object`); return; }
      if (!isArr(h.items)) v.push(`[plan rule 1] hazards_found[${i}].items must be an array`);
      if (!isArr(h.resources)) v.push(`[plan rule 1] hazards_found[${i}].resources must be an array`);
      for (const k of ['kind', 'disposition', 'evidence']) {
        if (!isStr(h[k])) v.push(`[plan rule 1] hazards_found[${i}].${k} must be a string`);
      }
    });
  }

  if (isArr(plan.waves)) {
    plan.waves.forEach((w, wi) => {
      if (!isObj(w)) { v.push(`[plan rule 1] waves[${wi}] is not an object`); return; }
      if (!isInt(w.wave) || w.wave < 1) v.push(`[plan rule 1] waves[${wi}].wave must be a 1-based integer`);
      if (!isArr(w.chunks) || w.chunks.length === 0) v.push(`[plan rule 1] waves[${wi}].chunks must be a non-empty array`);
      if (!isArr(w.post_integration_commands) || w.post_integration_commands.length === 0) {
        v.push(`[plan rule 1/11] waves[${wi}].post_integration_commands must be a non-empty array`);
      }
      if (isArr(w.chunks)) {
        w.chunks.forEach((c, ci) => {
          const at = `waves[${wi}].chunks[${ci}]`;
          if (!isObj(c)) { v.push(`[plan rule 1] ${at} is not an object`); return; }
          if (!isStr(c.id)) v.push(`[plan rule 1] ${at}.id must be a string`);
          if (!isArr(c.items) || c.items.length === 0) v.push(`[plan rule 1] ${at}.items must be a non-empty array`);
          else {
            c.items.forEach((it, ii) => {
              if (!isObj(it) || !isStr(it.id) || !isStr(it.text)) {
                v.push(`[plan rule 1] ${at}.items[${ii}] must be an object with string id and text`);
              }
            });
          }
          if (!isArr(c.exclusive_paths) || c.exclusive_paths.length === 0) {
            v.push(`[plan rule 1] ${at}.exclusive_paths must be a non-empty array`);
          }
          if (!isArr(c.reads)) v.push(`[plan rule 1] ${at}.reads must be an array`);
          if (!isNonEmptyStr(c.rationale)) v.push(`[plan rule 1] ${at}.rationale must be a non-empty string`);
          if (!isArr(c.independent_of)) v.push(`[plan rule 1] ${at}.independent_of must be an array`);
          else {
            c.independent_of.forEach((io, ii) => {
              if (!isObj(io) || !isStr(io.chunk_id) || !isStr(io.reason)) {
                v.push(`[plan rule 1] ${at}.independent_of[${ii}] must be an object with string chunk_id and reason`);
              }
            });
          }
          if (!CONFIDENCE.has(c.write_set_confidence)) {
            v.push(`[plan rule 1] ${at}.write_set_confidence must be high|medium|low`);
          }
          // Advisory keys - shape-checked only (s3.4, delta 5).
          if (c.exclusive_resources !== undefined && (!isArr(c.exclusive_resources) || c.exclusive_resources.some((r) => !isStr(r)))) {
            v.push(`[plan rule 1] ${at}.exclusive_resources must be an array of strings when present`);
          }
          if (c.depends_on_chunk_ids !== undefined && (!isArr(c.depends_on_chunk_ids) || c.depends_on_chunk_ids.some((r) => !isStr(r)))) {
            v.push(`[plan rule 1] ${at}.depends_on_chunk_ids must be an array of strings when present`);
          }
        });
      }
    });
  }
  return v;
}

function modeValidatePlan(args) {
  const { planPath, repoRoot, baseSha } = args;
  if (!planPath) usage('--validate-plan needs a wave_plan.json path');
  if (!repoRoot) usage('--validate-plan needs --repo-root <path>');
  if (!baseSha) usage('--validate-plan needs --base-sha <sha>');

  ctx.repo_root = repoRoot;

  // Environment first: an unusable repo is exit 2, never a rule verdict.
  if (!isGitRepo(repoRoot)) {
    process.stderr.write(`verify-parallel-wave: --repo-root ${repoRoot} is not a git repository\n`);
    finish(2, 'io_error');
  }
  if (!SHA40_RE.test(baseSha)) {
    process.stderr.write(`verify-parallel-wave: --base-sha must be a 40-char lowercase hex sha, got "${baseSha}"\n`);
    finish(2, 'io_error');
  }
  if (!gitRun(repoRoot, ['rev-parse', '--verify', '--quiet', `${baseSha}^{commit}`]).ok) {
    process.stderr.write(`verify-parallel-wave: --base-sha ${baseSha} does not resolve to a commit in ${repoRoot}\n`);
    finish(2, 'io_error');
  }

  const read = readJson(planPath);
  if (!read.ok) {
    process.stderr.write(`verify-parallel-wave: ${read.reason}\n`);
    finish(2, 'io_error'); // s4: unreadable or unparseable input -> exit 2
  }
  const plan = read.value;
  if (isObj(plan)) {
    if (VERDICTS.has(plan.verdict)) ctx.verdict = plan.verdict;
    if (isArr(plan.waves) && isObj(plan.waves[0]) && isInt(plan.waves[0].wave)) ctx.wave = plan.waves[0].wave;
  }

  const malformed = planShapeIssues(plan); // rule 1
  // Shape must hold before any rule that indexes into the structure.
  if (malformed.length > 0) {
    report(malformed);
    removeSidecar(planPath);
    finish(1, 'rule_violation');
  }

  const lowConfidence = [];
  const serialCorrect = [];
  const ab = plan.analysis_basis;

  // rule 2 - analysis_basis.repo_root equals --repo-root
  if (!samePath(ab.repo_root, repoRoot)) {
    malformed.push(`[plan rule 2] analysis_basis.repo_root ${JSON.stringify(ab.repo_root)} != --repo-root ${JSON.stringify(repoRoot)}`);
  }

  // rule 3 - base_sha ancestry (s3.2). The machine-checkable predicate is ancestry, which
  // subsumes wave-1 equality: at wave 1 the orchestrator passes the very sha the plan was
  // analyzed at, so identity holds by construction and an ancestor check succeeds on it.
  if (!isAncestor(repoRoot, ab.base_sha, baseSha)) {
    malformed.push(`[plan rule 3] analysis_basis.base_sha ${ab.base_sha} is not an ancestor of --base-sha ${baseSha} (different history)`);
  }

  // rule 6 (shared_hazard_paths half) - prefixes allowed, existence-unbounded (s3.2)
  const hazard = validatePathList(ab.shared_hazard_paths, 'analysis_basis.shared_hazard_paths', true);
  for (const i of hazard.issues) malformed.push(`[plan rule 6] ${i}`);

  const seenIds = new Set();
  const scripts = readPackageScripts(repoRoot);

  plan.waves.forEach((w, wi) => {
    const waveLabel = `wave ${w.wave}`;

    // rule 5 - width
    if (w.chunks.length > WAVE_WIDTH_MAX) {
      malformed.push(`[plan rule 5] ${waveLabel} has ${w.chunks.length} chunks, WAVE_WIDTH_MAX is ${WAVE_WIDTH_MAX}`);
    }

    const declared = []; // per-chunk normalized write sets, index-aligned with w.chunks
    const reads = [];

    w.chunks.forEach((c) => {
      // rule 4 - id regex + plan-wide uniqueness
      if (!CHUNK_ID_RE.test(c.id)) {
        malformed.push(`[plan rule 4] ${waveLabel} chunk id ${JSON.stringify(c.id)} does not match ${CHUNK_ID_RE}`);
      }
      if (seenIds.has(c.id)) malformed.push(`[plan rule 4] chunk id ${JSON.stringify(c.id)} is used more than once in the plan`);
      seenIds.add(c.id);

      // rule 6 - path syntax; reads[] may NOT carry a subtree prefix (s2.2)
      const ex = validatePathList(c.exclusive_paths, `${waveLabel} chunk ${c.id} exclusive_paths`, true);
      const rd = validatePathList(c.reads, `${waveLabel} chunk ${c.id} reads`, false);
      for (const i of ex.issues) malformed.push(`[plan rule 6] ${i}`);
      for (const i of rd.issues) malformed.push(`[plan rule 6] ${i}`);
      declared.push(ex.entries);
      reads.push(rd.entries);

      // rule 7 - subtree prefixes only over directories ABSENT at the passed sha
      for (const e of ex.entries) {
        if (!e.endsWith('/')) continue;
        const dir = e.slice(0, -1);
        const exists = dirExistsAtSha(repoRoot, baseSha, dir);
        if (exists === null) {
          process.stderr.write(`verify-parallel-wave: git ls-tree failed for ${dir} at ${baseSha}\n`);
          finish(2, 'io_error');
        }
        if (exists) {
          malformed.push(`[plan rule 7] ${waveLabel} chunk ${c.id}: subtree prefix ${JSON.stringify(e)} covers a directory that already exists at ${baseSha} - enumerate the files instead`);
        }
      }

      // rule 10 - writes disjoint from shared_hazard_paths
      for (const [a, b] of overlappingPairs(ex.entries, hazard.entries)) {
        malformed.push(`[plan rule 10] ${waveLabel} chunk ${c.id}: declared write ${JSON.stringify(a)} overlaps shared hazard path ${JSON.stringify(b)}`);
      }
    });

    // rule 8 - declared write-sets pairwise disjoint within the wave
    for (let i = 0; i < w.chunks.length; i += 1) {
      for (let j = i + 1; j < w.chunks.length; j += 1) {
        for (const [a, b] of overlappingPairs(declared[i], declared[j])) {
          malformed.push(`[plan rule 8] ${waveLabel} chunks ${w.chunks[i].id} and ${w.chunks[j].id} both claim ${JSON.stringify(a)} / ${JSON.stringify(b)}`);
        }
      }
    }

    // rule 9 - writes(A) disjoint from reads(B) for every ORDERED sibling pair
    for (let i = 0; i < w.chunks.length; i += 1) {
      for (let j = 0; j < w.chunks.length; j += 1) {
        if (i === j) continue; // self-reads are fine (s2.3)
        for (const [a, b] of overlappingPairs(declared[i], reads[j])) {
          malformed.push(`[plan rule 9] ${waveLabel} chunk ${w.chunks[i].id} writes ${JSON.stringify(a)} which sibling ${w.chunks[j].id} reads as ${JSON.stringify(b)}`);
        }
      }
    }

    // rule 11 - post_integration_commands allowlist + typecheck floor
    const invoked = [];
    w.post_integration_commands.forEach((cmd, ci) => {
      const res = commandIssue(cmd, scripts);
      if (!res.ok) {
        malformed.push(`[plan rule 11] ${waveLabel} post_integration_commands[${ci}] ${JSON.stringify(cmd)} ${res.issue}`);
      } else if (res.runScript) {
        invoked.push(res.runScript);
      }
    });
    if (scripts && scripts.some((s) => TYPECHECK_SCRIPTS.includes(s))) {
      const floorMet = invoked.some((s) => TYPECHECK_SCRIPTS.includes(s));
      if (!floorMet) {
        malformed.push(`[plan rule 11] ${waveLabel} declares no typecheck-class command; package.json declares ${JSON.stringify(scripts.filter((s) => TYPECHECK_SCRIPTS.includes(s)))} and the barrier must run at least one`);
      }
    }

    // rule 12 - a multi-chunk wave must be a HIGH-confidence claim, sibling by sibling
    if (w.chunks.length > 1) {
      if (plan.confidence !== 'high') {
        lowConfidence.push(`[plan rule 12] ${waveLabel} is multi-chunk but top-level confidence is ${JSON.stringify(plan.confidence)}`);
      }
      const ids = w.chunks.map((c) => c.id);
      w.chunks.forEach((c) => {
        if (c.write_set_confidence !== 'high') {
          lowConfidence.push(`[plan rule 12] ${waveLabel} chunk ${c.id} write_set_confidence is ${JSON.stringify(c.write_set_confidence)}`);
        }
        const named = new Set(c.independent_of.map((io) => io.chunk_id));
        for (const sib of ids) {
          if (sib === c.id) continue;
          if (!named.has(sib)) {
            lowConfidence.push(`[plan rule 12] ${waveLabel} chunk ${c.id} carries no independent_of entry naming sibling ${sib}`);
          }
        }
      });
    }

    // rule 13 (structural half) - SERIAL_CORRECT waves are single-chunk
    if (plan.verdict === 'SERIAL_CORRECT' && w.chunks.length !== 1) {
      malformed.push(`[plan rule 13] verdict is SERIAL_CORRECT but ${waveLabel} has ${w.chunks.length} chunks`);
    }
    if (wi > 0 && isInt(plan.waves[wi - 1].wave) && w.wave <= plan.waves[wi - 1].wave) {
      malformed.push(`[plan rule 1] waves[${wi}].wave (${w.wave}) is not greater than the preceding wave (${plan.waves[wi - 1].wave})`);
    }
  });

  // rule 13 - the SERIAL_CORRECT signal itself
  if (plan.verdict === 'SERIAL_CORRECT') {
    if (plan.serial_reasons.length === 0) {
      malformed.push('[plan rule 13] verdict is SERIAL_CORRECT but serial_reasons is empty');
    } else {
      serialCorrect.push(`[plan rule 13] verdict is SERIAL_CORRECT: ${plan.serial_reasons.join('; ')} - run serially, no validated plan is needed`);
    }
  }

  const all = [...malformed, ...lowConfidence, ...serialCorrect];
  if (all.length > 0) {
    report(all);
    removeSidecar(planPath); // a plan that fails validation must not leave a stale blessing
    if (malformed.length > 0) finish(1, 'rule_violation');
    if (lowConfidence.length > 0) finish(1, 'low_confidence');
    finish(1, 'serial_correct');
  }

  // s4a (C2): the plan is blessed - write the plan<->state binding sidecar so a later
  // --wave-state can prove its topology matches this validated plan.
  writeSidecar(planPath, plan, repoRoot);
  process.stdout.write(`verify-parallel-wave: wave_plan OK - ${plan.waves.length} wave(s), ${plan.waves.reduce((n, w) => n + w.chunks.length, 0)} chunk(s) at ${baseSha}\n`);
  finish(0, 'fan_out');
}

// ---------------------------------------------------------------------------
// Mode: --wave-state   (schema doc, s5 + s6)
// ---------------------------------------------------------------------------

// s5 shape. A state file that is not structurally a wave_state cannot have rules 1-11
// evaluated against it at all, so it is an INPUT error (exit 2) - the same class as
// unreadable or unparseable. This is also what makes merge-wave.sh's "corrupt state file =>
// refuse loudly before any merge" hold through its inline re-verification.
function stateShapeIssues(st) {
  const v = [];
  if (!isObj(st)) return ['the wave_state is not a JSON object'];
  if (!isNonEmptyStr(st.repo_root) || !path.isAbsolute(st.repo_root)) v.push('repo_root must be an absolute path string');
  if (!isStr(st.base_sha) || !SHA40_RE.test(st.base_sha)) v.push('base_sha must be a 40-char lowercase hex sha');
  if (!isInt(st.wave) || st.wave < 1) v.push('wave must be a 1-based integer');
  // v1.1 (C2): the state names the validated wave_plan it was derived from, and echoes that
  // plan's shared_hazard_paths so the barrier can re-run the hazard-intersection rule.
  if (!isNonEmptyStr(st.wave_plan_path) || !path.isAbsolute(st.wave_plan_path)) v.push('wave_plan_path must be an absolute path string');
  if (!isArr(st.shared_hazard_paths)) v.push('shared_hazard_paths must be an array');
  if (!(st.impl_plan_path === null || (isNonEmptyStr(st.impl_plan_path) && path.isAbsolute(st.impl_plan_path)))) {
    v.push('impl_plan_path must be null or an absolute path string');
  }
  if (!isArr(st.merged_chunks)) v.push('merged_chunks must be an array');
  else {
    st.merged_chunks.forEach((m, i) => {
      if (!isObj(m) || !isStr(m.id) || !isStr(m.merge_sha) || !SHA40_RE.test(m.merge_sha)) {
        v.push(`merged_chunks[${i}] must be an object with a string id and a 40-hex merge_sha`);
      }
    });
  }
  if (!isArr(st.gate_list) || st.gate_list.some((g) => !isStr(g))) v.push('gate_list must be an array of strings');
  if (!isArr(st.chunks) || st.chunks.length === 0) v.push('chunks must be a non-empty array');
  else {
    st.chunks.forEach((c, i) => {
      if (!isObj(c)) { v.push(`chunks[${i}] is not an object`); return; }
      if (!isStr(c.id)) v.push(`chunks[${i}].id must be a string`);
      if (!isNonEmptyStr(c.branch)) v.push(`chunks[${i}].branch must be a non-empty string`);
      if (!isNonEmptyStr(c.worktree) || !path.isAbsolute(c.worktree)) v.push(`chunks[${i}].worktree must be an absolute path string`);
      if (!isArr(c.exclusive_paths) || c.exclusive_paths.length === 0) v.push(`chunks[${i}].exclusive_paths must be a non-empty array`);
      if (!isArr(c.reads)) v.push(`chunks[${i}].reads must be an array`);
    });
  }
  return v;
}

function modeWaveState(args) {
  const { statePath } = args;
  if (!statePath) usage('--wave-state needs a wave-state.json path');

  const read = readJson(statePath);
  if (!read.ok) {
    process.stderr.write(`verify-parallel-wave: ${read.reason}\n`);
    finish(2, 'io_error'); // s6: unreadable or unparseable input -> exit 2
  }
  const st = read.value;
  if (isObj(st)) {
    if (isStr(st.repo_root)) ctx.repo_root = st.repo_root;
    if (isInt(st.wave)) ctx.wave = st.wave;
  }

  const shape = stateShapeIssues(st);
  if (shape.length > 0) {
    report(shape.map((s) => `[wave-state shape] ${s}`));
    finish(2, 'io_error'); // a non-wave_state input cannot have rules evaluated: input error
  }

  const repo = st.repo_root;
  if (!isGitRepo(repo)) {
    process.stderr.write(`verify-parallel-wave: repo_root ${repo} is not a git repository\n`);
    finish(2, 'io_error'); // s6 rule 1 class: path-missing input
  }

  const dirty = []; // rules 3, 10, 11 -> reason dirty_repo_root
  const malformed = []; // every other rule -> reason rule_violation

  // s6 rule 12 half (C2): re-validate the echoed shared_hazard_paths syntax before it is used
  // by the hazard-intersection re-run below (prefixes allowed, existence-unbounded).
  const hazard = validatePathList(st.shared_hazard_paths, 'shared_hazard_paths', true);
  for (const i of hazard.issues) malformed.push(`[wave-state] ${i}`);

  // s6a (C2): bind this state to the wave_plan --validate-plan blessed. The sidecar is an
  // INDEPENDENT artifact only that pass could have produced; an absent or mismatching one means
  // the state's topology was never gated (the plan-only rules would otherwise vanish). Its
  // hash covers exactly the shared content, so a matching sidecar transitively re-applies the
  // plan-gate rules to the runtime state. Absent/mismatch => rule violation (fail-closed).
  const sidecarPath = sidecarPathFor(st.wave_plan_path);
  const sidecarRead = readJson(sidecarPath);
  if (!sidecarRead.ok) {
    malformed.push(`[wave-state rule 12] no validated-plan sidecar at ${sidecarPath} - this state was never blessed by --validate-plan (${sidecarRead.reason})`);
  } else {
    const sc = sidecarRead.value;
    const recorded = isObj(sc) && isObj(sc.waves) ? sc.waves[String(st.wave)] : undefined;
    const expected = canonicalWaveHash(repo, st.shared_hazard_paths, st.wave, st.chunks);
    if (recorded !== expected) {
      malformed.push(`[wave-state rule 12] sidecar ${sidecarPath} does not bless wave ${st.wave} of this state (recorded ${JSON.stringify(recorded)} != computed ${expected}) - state topology drifted from the validated plan`);
    }
  }

  const declared = [];
  const reads = [];
  const touchedSets = [];

  for (const c of st.chunks) {
    const label = `chunk ${c.id}`;

    if (!CHUNK_ID_RE.test(c.id)) malformed.push(`[wave-state] ${label}: id does not match ${CHUNK_ID_RE}`);

    const ex = validatePathList(c.exclusive_paths, `${label} exclusive_paths`, true);
    const rd = validatePathList(c.reads, `${label} reads`, false);
    for (const i of ex.issues) malformed.push(`[wave-state] ${i}`);
    for (const i of rd.issues) malformed.push(`[wave-state] ${i}`);
    declared.push(ex.entries);
    reads.push(rd.entries);

    // rule 1 - the worktree exists and is a git worktree. Missing -> exit 2.
    if (!fs.existsSync(c.worktree) || !gitRun(c.worktree, ['rev-parse', '--is-inside-work-tree']).ok) {
      process.stderr.write(`verify-parallel-wave: ${label}: worktree ${c.worktree} is missing or is not a git worktree\n`);
      finish(2, 'io_error');
    }

    const head = revParse(c.worktree, 'HEAD');
    if (!head) {
      process.stderr.write(`verify-parallel-wave: ${label}: worktree ${c.worktree} has no resolvable HEAD\n`);
      finish(2, 'io_error');
    }

    // rule 13 (C3): the branch NAME merge-wave will merge must resolve, FROM repo_root, to
    // exactly this verified worktree HEAD. Otherwise merge-wave (which merges the branch by
    // name) could integrate a wrong or advanced ref that the barrier's touched-path checks
    // never inspected. Unresolvable or mismatched => violation.
    const branchSha = revParse(repo, c.branch);
    if (branchSha === null) {
      malformed.push(`[wave-state rule 13] ${label}: branch ${JSON.stringify(c.branch)} does not resolve from repo_root ${repo} - merge-wave would merge an unverifiable ref`);
    } else if (branchSha !== head) {
      malformed.push(`[wave-state rule 13] ${label}: branch ${JSON.stringify(c.branch)} resolves to ${branchSha} but the verified worktree HEAD is ${head} - merge-wave would merge a ref the barrier never checked`);
    }

    // rule 14 (C2 defense-in-depth): a subtree prefix is admissible ONLY over a directory
    // absent at base_sha - re-run here, not just at --validate-plan, so a hand-forged state
    // cannot smuggle a blank-cheque prefix over an existing dir past the barrier.
    for (const e of ex.entries) {
      if (!e.endsWith('/')) continue;
      const dir = e.slice(0, -1);
      const exists = dirExistsAtSha(repo, st.base_sha, dir);
      if (exists === null) {
        process.stderr.write(`verify-parallel-wave: ${label}: git ls-tree failed for ${dir} at ${st.base_sha}\n`);
        finish(2, 'io_error');
      }
      if (exists) {
        malformed.push(`[wave-state rule 14] ${label}: subtree prefix ${JSON.stringify(e)} covers a directory that already exists at ${st.base_sha} - enumerate the files instead`);
      }
    }

    // rule 15 (C2 defense-in-depth): declared writes disjoint from shared_hazard_paths.
    for (const [a, b] of overlappingPairs(ex.entries, hazard.entries)) {
      malformed.push(`[wave-state rule 15] ${label}: declared write ${JSON.stringify(a)} overlaps shared hazard path ${JSON.stringify(b)}`);
    }

    // rule 2 - base_sha is an ancestor of the worktree HEAD
    if (!isAncestor(c.worktree, st.base_sha, 'HEAD')) {
      malformed.push(`[wave-state rule 2] ${label}: base_sha ${st.base_sha} is not an ancestor of the worktree HEAD ${head} - this worktree is on a different history`);
      touchedSets.push([]);
      continue;
    }

    // rule 3 - CLEAN including untracked
    const wtStatus = statusPaths(c.worktree, true);
    if (wtStatus === null) {
      process.stderr.write(`verify-parallel-wave: ${label}: git status failed in ${c.worktree}\n`);
      finish(2, 'io_error');
    }
    if (wtStatus.length > 0) {
      dirty.push(`[wave-state rule 3] ${label}: chunk left uncommitted work in ${c.worktree}: ${wtStatus.slice(0, 12).join(', ')}${wtStatus.length > 12 ? ` (+${wtStatus.length - 12} more)` : ''}`);
    }

    // rule 4 - at least one commit beyond base_sha
    const count = gitRun(c.worktree, ['rev-list', '--count', `${st.base_sha}..HEAD`]);
    if (!count.ok) {
      process.stderr.write(`verify-parallel-wave: ${label}: git rev-list failed in ${c.worktree}\n`);
      finish(2, 'io_error');
    }
    if (Number(count.out.trim()) < 1) {
      malformed.push(`[wave-state rule 4] ${label}: no commit beyond base_sha ${st.base_sha} - the chunk produced nothing to merge`);
    }

    // rule 5 - touched, with renames counting BOTH sides
    const diff = gitRun(c.worktree, ['diff', '--name-only', '--no-renames', '-z', `${st.base_sha}..HEAD`]);
    if (!diff.ok) {
      process.stderr.write(`verify-parallel-wave: ${label}: git diff failed in ${c.worktree}\n`);
      finish(2, 'io_error');
    }
    const touched = splitZ(diff.out).map(normalizePath);
    touchedSets.push(touched);

    // rule 6 - touched is a subset of this chunk's own exclusive_paths
    for (const p of touched) {
      if (!ex.entries.some((e) => matches(e, p))) {
        malformed.push(`[wave-state rule 6] ${label}: touched ${JSON.stringify(p)} is outside its declared exclusive_paths`);
      }
    }
  }

  // rule 7 - declared sets pairwise disjoint
  for (let i = 0; i < st.chunks.length; i += 1) {
    for (let j = i + 1; j < st.chunks.length; j += 1) {
      for (const [a, b] of overlappingPairs(declared[i], declared[j])) {
        malformed.push(`[wave-state rule 7] chunks ${st.chunks[i].id} and ${st.chunks[j].id} both declare ${JSON.stringify(a)} / ${JSON.stringify(b)}`);
      }
    }
  }

  // rule 8 - ACTUAL touched sets pairwise disjoint
  for (let i = 0; i < st.chunks.length; i += 1) {
    for (let j = i + 1; j < st.chunks.length; j += 1) {
      const shared = touchedSets[i].filter((p) => touchedSets[j].includes(p));
      for (const p of shared) {
        malformed.push(`[wave-state rule 8] chunks ${st.chunks[i].id} and ${st.chunks[j].id} both touched ${JSON.stringify(p)}`);
      }
    }
  }

  // rule 9 - touched(A) disjoint from reads(B), every ORDERED sibling pair
  for (let i = 0; i < st.chunks.length; i += 1) {
    for (let j = 0; j < st.chunks.length; j += 1) {
      if (i === j) continue;
      for (const p of touchedSets[i]) {
        for (const r of reads[j]) {
          if (matches(r, p)) {
            malformed.push(`[wave-state rule 9] chunk ${st.chunks[i].id} touched ${JSON.stringify(p)} which sibling ${st.chunks[j].id} declares in reads`);
          }
        }
      }
    }
  }

  // rule 10 - repo_root HEAD is base_sha or one of the RECORDED merge commits
  const repoHead = revParse(repo, 'HEAD');
  if (!repoHead) {
    process.stderr.write(`verify-parallel-wave: repo_root ${repo} has no resolvable HEAD\n`);
    finish(2, 'io_error');
  }
  const allowedHeads = [st.base_sha, ...st.merged_chunks.map((m) => m.merge_sha)];
  if (!allowedHeads.includes(repoHead)) {
    dirty.push(`[wave-state rule 10] repo_root HEAD ${repoHead} is neither base_sha nor a recorded merge_sha (${allowedHeads.join(', ')}) - the integration checkout moved outside the wave`);
  }

  // rule 16 (C4): merged_chunks integrity. Each entry must name a UNIQUE chunk that belongs to
  // THIS wave, and its merge_sha must be a real commit AND an ancestor of repo_root HEAD. A
  // shape-only check let a forged/duplicated/dangling entry widen rule 10's allow-list.
  const chunkIds = new Set(st.chunks.map((c) => c.id));
  const seenMerged = new Set();
  for (const m of st.merged_chunks) {
    if (seenMerged.has(m.id)) {
      malformed.push(`[wave-state rule 16] merged_chunks id ${JSON.stringify(m.id)} appears more than once`);
    }
    seenMerged.add(m.id);
    if (!chunkIds.has(m.id)) {
      malformed.push(`[wave-state rule 16] merged_chunks id ${JSON.stringify(m.id)} is not a chunk in this wave`);
    }
    if (!gitRun(repo, ['cat-file', '-e', `${m.merge_sha}^{commit}`]).ok) {
      malformed.push(`[wave-state rule 16] merged_chunks merge_sha ${m.merge_sha} is not a commit in repo_root ${repo}`);
    } else if (!isAncestor(repo, m.merge_sha, 'HEAD')) {
      malformed.push(`[wave-state rule 16] merged_chunks merge_sha ${m.merge_sha} for ${JSON.stringify(m.id)} is not an ancestor of repo_root HEAD ${repoHead}`);
    }
  }

  // rule 11 - repo_root tracked-clean, except impl_plan_path when it is UNDER repo_root
  const rootStatus = statusPaths(repo, false);
  if (rootStatus === null) {
    process.stderr.write(`verify-parallel-wave: git status failed in ${repo}\n`);
    finish(2, 'io_error');
  }
  const exempt = st.impl_plan_path ? relativeUnder(repo, st.impl_plan_path) : null;
  const offending = rootStatus.filter((p) => exempt === null || normalizePath(p) !== exempt);
  if (offending.length > 0) {
    dirty.push(`[wave-state rule 11] repo_root ${repo} is tracked-dirty: ${offending.slice(0, 12).join(', ')}${offending.length > 12 ? ` (+${offending.length - 12} more)` : ''}${exempt === null && st.impl_plan_path ? ' (impl_plan_path is outside repo_root - no exemption)' : ''}`);
  }

  const all = [...malformed, ...dirty];
  if (all.length > 0) {
    report(all);
    // A boundary breach is the more specific signal; cleanliness alone is dirty_repo_root.
    finish(1, malformed.length > 0 ? 'rule_violation' : 'dirty_repo_root');
  }

  process.stdout.write(`verify-parallel-wave: wave ${st.wave} state OK - ${st.chunks.length} chunk(s), ${st.merged_chunks.length} already merged\n`);
  finish(0, 'fan_out');
}

// ---------------------------------------------------------------------------
// Mode: --log-decision   (schema doc, s7.2)
// ---------------------------------------------------------------------------

function modeLogDecision(args) {
  const { decisionRaw, reasonRaw, repoRoot } = args;
  if (decisionRaw === null) usage('--log-decision needs <serial|fan_out>');
  if (reasonRaw === null) usage('--log-decision needs --reason <token>');
  if (!repoRoot) usage('--log-decision needs --repo-root <path>');

  ctx.repo_root = repoRoot;
  // s7.2: on rejection `decision` is the passed value when that argument was ITSELF valid.
  if (DECISIONS.has(decisionRaw)) ctx.decision = decisionRaw;

  if (!DECISIONS.has(decisionRaw)) {
    process.stderr.write(`verify-parallel-wave: --log-decision must be serial|fan_out, got ${JSON.stringify(decisionRaw)}\n`);
    finish(2, 'usage_error');
  }
  if (!REASONS.has(reasonRaw)) {
    process.stderr.write(`verify-parallel-wave: unknown --reason token ${JSON.stringify(reasonRaw)}; the closed set is: ${[...REASONS].join(' | ')}\n`);
    finish(2, 'usage_error'); // a typo'd reason would otherwise become a silent new category
  }

  process.stdout.write(`verify-parallel-wave: logged ${decisionRaw} (${reasonRaw}) for ${repoRoot}\n`);
  finish(0, reasonRaw);
}

// ---------------------------------------------------------------------------
// Mode: --emit-event   (schema doc, s7 + s8 - the ONE event serializer, C-dup fix)
// ---------------------------------------------------------------------------

// A pure serializer used by merge-wave.sh so the 480-byte fixed-key event line is built in
// exactly ONE place (buildEventLine), never hand-rolled in bash. merge-wave's events are
// operations ON a wave-state, so tool_mode is fixed to `wave-state`; the event's own `exit`
// and `reason` are the merge outcome the caller passes. The invocation itself always exits 0
// on a successful append - its process exit is not the event's exit.
function modeEmitEvent(args) {
  const { exitRaw, reasonRaw, repoRoot, waveRaw } = args;
  ctx.tool_mode = 'wave-state';
  ctx.decision = null;
  ctx.verdict = null;
  ctx.repo_root = typeof repoRoot === 'string' ? repoRoot : '';
  ctx.wave = typeof waveRaw === 'string' && /^\d+$/.test(waveRaw) ? Number(waveRaw) : null;
  const exitCode = typeof exitRaw === 'string' && /^-?\d+$/.test(exitRaw) ? Number(exitRaw) : 2;
  // writeEvent maps a reason outside the closed set to the fail-closed `malformed` fallback.
  writeEvent(exitCode, typeof reasonRaw === 'string' ? reasonRaw : 'malformed');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const a = {
    mode: null, planPath: null, statePath: null, repoRoot: null, baseSha: null,
    decisionRaw: null, reasonRaw: null, exitRaw: null, waveRaw: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    switch (flag) {
      case '--validate-plan':
        if (a.mode) { ctx.tool_mode = a.mode; usage('only one mode may be named'); }
        a.mode = 'validate-plan'; a.planPath = value ?? null; i += 1; break;
      case '--wave-state':
        if (a.mode) { ctx.tool_mode = a.mode; usage('only one mode may be named'); }
        a.mode = 'wave-state'; a.statePath = value ?? null; i += 1; break;
      case '--log-decision':
        if (a.mode) { ctx.tool_mode = a.mode; usage('only one mode may be named'); }
        a.mode = 'log-decision'; a.decisionRaw = value ?? null; i += 1; break;
      case '--emit-event':
        if (a.mode) { ctx.tool_mode = a.mode; usage('only one mode may be named'); }
        a.mode = 'emit-event'; break; // consumes no value; fields come from --exit/--reason/--repo-root/--wave
      case '--repo-root': a.repoRoot = value ?? null; i += 1; break;
      case '--base-sha': a.baseSha = value ?? null; i += 1; break;
      case '--reason': a.reasonRaw = value ?? null; i += 1; break;
      case '--exit': a.exitRaw = value ?? null; i += 1; break;
      case '--wave': a.waveRaw = value ?? null; i += 1; break;
      case '-h': case '--help': usage(null); break;
      default:
        // ctx.tool_mode may already be set - an unknown flag is still that mode's event.
        if (a.mode) ctx.tool_mode = a.mode;
        usage(`unknown argument ${JSON.stringify(flag)}`);
    }
  }
  if (!a.mode) usage('no mode named');
  ctx.tool_mode = a.mode;
  return a;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.mode === 'validate-plan') modeValidatePlan(args);
  else if (args.mode === 'wave-state') modeWaveState(args);
  else if (args.mode === 'emit-event') modeEmitEvent(args);
  else modeLogDecision(args);
}

try {
  main();
} catch (err) {
  process.stderr.write(`verify-parallel-wave: unexpected error: ${(err && err.stack) || err}\n`);
  finish(2, 'io_error');
}
