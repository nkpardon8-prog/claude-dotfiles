# Wave-plan schemas (FROZEN, v1.1)

`schema_version: "parallelizer.v1.1"`

**This file is the SOLE schema authority** for the write-wave machinery. Four artifacts are
frozen here:

| Artifact | Written by | Read by |
| --- | --- | --- |
| `wave_plan` | the PARALLELIZER subagent (`agents/parallelizer.md`) | `scripts/verify-parallel-wave.mjs --validate-plan`, the orchestrator (`commands/implement.md` wave mode) |
| `wave_plan` binding sidecar (`<wave_plan>.validated`) | `--validate-plan` (on pass) | `--wave-state` (s4a / s6a) |
| `wave_state` | the orchestrator, once per wave | `scripts/verify-parallel-wave.mjs --wave-state`, `scripts/merge-wave.sh` |
| `rework.log` event | `scripts/verify-parallel-wave.mjs` (every invocation), `scripts/merge-wave.sh` (via the checker's `--emit-event` serializer) | `scripts/parallel-stats.py` |

Nothing else may restate these shapes. `agents/parallelizer.md` and the checker both cite this
file; when they disagree with it, this file wins and they are the bug.

Frozen means: no field may be added, removed, renamed, or have its meaning changed without a
`schema_version` bump and a matching update to the checker, its assumption suite, and the agent
definition in the same commit.

## v1.1 changes (codex-review C2/C3/C4/C9 + adversarial)

Bumped `parallelizer.v1` -> `parallelizer.v1.1`. Summary (full detail in the cited sections):

1. **`wave_state` gains two REQUIRED fields** (s5): `wave_plan_path` (absolute path to the
   `wave_plan` that `--validate-plan` blessed) and `shared_hazard_paths` (the wave's hazard list,
   echoed from that plan). They power the binding sidecar and the re-run of the hazard rule.
2. **Plan<->state binding sidecar** (s4a / s6a, fixes C2): `--validate-plan` writes
   `<wave_plan>.validated` on pass; `--wave-state` requires a sidecar whose recorded per-wave hash
   equals the hash recomputed from the state. Absent or mismatched => violation.
3. **`--wave-state` re-runs two plan-only rules** as defense-in-depth (s6 rules 14-15, fixes C2):
   subtree-prefix-only-over-absent-dirs, and writes disjoint from `shared_hazard_paths`.
4. **`--wave-state` binds branch to verified HEAD** (s6 rule 13, fixes C3): each chunk's `branch`
   must resolve, from `repo_root`, to exactly the verified worktree HEAD.
5. **`--wave-state` proves `merged_chunks` integrity** (s6 rule 16, fixes C4): unique ids, each a
   member of `chunks[]`, each `merge_sha` a real commit AND an ancestor of `repo_root` HEAD.
6. **`make <target>` allowlist tightened** (s2.4, fixes C9): only a bare target token, no flags or
   paths. A `.` path segment is now rejected (s2.2).
7. **De-aliased `reason` token set** (s7.2): `merge_conflict`, `merge_success`, `usage_error`,
   `io_error`, `rule_violation` split apart events v1 flattened into `malformed`/`fan_out`.
8. **One event serializer** (s7 / s8): merge-wave emits via the checker's `--emit-event` mode, and
   validates each branch (`check-ref-format --branch`, no leading dash) before merging.

---

## 1. Deltas vs the 2026-08-02 contract draft

Base: `tmp/briefs/parallelizer-research/parallelizer-contract-draft.md` (sections 3 and 5) in the
dentall repo. The deltas below are decisions (plan Divergences 7 and 8), not drift.

1. **`exclusive_files` -> `exclusive_paths`.** The field admits a bounded subtree prefix, so
   "files" was a lie. Same rename in the runtime state file.
2. **`reads[]` ADDED per chunk.** The draft only forbade write/write collisions, so a chunk could
   silently build against a file a sibling was rewriting. `reads` is BOUNDED: files whose CONTENT
   this chunk's correctness depends on AND that a sibling could plausibly modify. It is NOT a
   dependency dump - repo-wide config, docs, and conventions files do not belong in it. The
   checker enforces `writes of A` disjoint from `reads of every sibling B`.
3. **`barrier.pre_merge_command` DELETED.** The orchestrator owns invocation; letting the plan
   name the command that verifies the plan is a self-signed certificate. The rest of the draft's
   `barrier` object is dissolved with it:
   - `post_integration_commands` is promoted to a direct per-wave key (delta 4),
   - `integration_order` is the declared order of `waves[].chunks[]` (merge-wave.sh merges in
     array order and records progress in `merged_chunks[]`),
   - `overlap_check_required`, `success_condition`, and `failure_action` are unconditional
     orchestrator behavior, documented in `commands/implement.md`, not plan data.
4. **`post_integration_commands` is PER-WAVE, non-empty, allowlisted** (section 2.4). The draft
   let a plan emit an arbitrary shell string; here every command must survive a metacharacter
   rejection plus an argv-prefix allowlist, and a repo that declares a typecheck-class script must
   see at least one such command.
5. **`exclusive_resources` kept but ADVISORY - not machine-verified in v1.** Ports, dev servers,
   test tenants, and queues have no on-disk trace the checker can diff. It stays in the schema
   because it drives PARALLELIZER's own refusals and is human-readable evidence; the checker only
   validates its shape.
6. **`analysis_basis` REQUIRED and reshaped** to a minimum core of
   `{repo_root, base_sha, shared_hazard_paths[]}` (section 3.2). The draft's other keys survive as
   optional advisory context. `base_ref` alone was unusable: the checker needs the resolved,
   immutable SHA and the hazard list to evaluate anything.
7. **Chunk `id` regex `^[a-z0-9][a-z0-9-]{0,31}$` ADDED** (section 2.1). Ids become branch names
   and directory names; the draft left them free strings.
8. **`exclusive_paths` syntax rules ADDED** (section 2.2), including Divergence 7: a trailing-`/`
   subtree prefix is permitted ONLY for a directory that is ABSENT at that wave's `base_sha`. A
   prefix over an existing directory is a blank cheque over files nobody enumerated.
9. **Wave width capped at `WAVE_WIDTH_MAX = 4`, a constant** (section 2.5). The draft's
   `min(4, max_parallel_workers)` made the cap an input the caller could raise.
10. **The draft's section 6 cheap-model carve-out is DROPPED.** PARALLELIZER always runs at full
    capacity. Cost never buys a worse scheduling decision. (Recorded here because it is a delta
    against the same base document; it is enforced in `agents/parallelizer.md`, not by a schema.)
11. **`rework.log` event schema ADDED** (section 7) - a fixed-key, single-line JSONL event hard
    capped at 480 bytes, with a CLOSED reason-token set. The draft had no telemetry contract at
    all. The cap exists because `write(2)` atomicity for concurrent appenders is only proven below
    `PIPE_BUF`.

---

## 2. Shared definitions

These definitions are referenced by both schemas. Violating any of them is a `malformed` rejection.

### 2.1 Chunk id

```
^[a-z0-9][a-z0-9-]{0,31}$
```

Lowercase alphanumerics and hyphens, 1-32 chars, must not start with a hyphen. Chunk ids become
git branch names (`w<W>-<SID8>-<chunk-id>`) and worktree directory names, so anything outside this
set is a shell or filesystem hazard. Ids must be unique across the WHOLE plan, not just within a
wave.

### 2.2 Path syntax (`exclusive_paths`, `reads`, `shared_hazard_paths`)

Every entry is a repo-root-relative POSIX path. An entry is REJECTED if it:

- is absolute (leading `/`) or a Windows path (contains `\`),
- contains a `..` segment,
- contains a glob metacharacter (`*`, `?`, `[`, `]`),
- is empty, `.`, or `./` after normalization,
- contains an empty segment (`a//b`),
- contains a `.` segment (`src/./x` - normalization only strips a LEADING `./`, so a mid-path
  `.` would otherwise dodge the exact-string rule-9 comparison),
- duplicates another entry in the same list.

`./` prefixes are normalized away (`./a/b.ts` -> `a/b.ts`) before every comparison. A trailing `/`
marks a SUBTREE PREFIX; see 2.3 for what that admits.

`reads[]` entries MUST be exact file paths - a trailing-`/` prefix is REJECTED in `reads`. A
subtree read would let one chunk fence off a directory it merely consumes, which is the opposite
of the bounded definition in delta 2.

### 2.3 Path matching and overlap

For a declared entry `e` and an actual touched path `p`:

```
matches(e, p) = (e ends with "/") ? p startsWith e : p == e
```

Exact entries match by full string equality only - `src/a` never matches `src/ab`.

Two declared entries `a` and `b` OVERLAP when:

```
a == b
  OR (a ends with "/" AND b startsWith a)
  OR (b ends with "/" AND a startsWith b)
```

Two path SETS intersect when any entry of one overlaps any entry of the other. This is the
predicate behind every disjointness rule below.

**Subtree prefixes (Divergence 7):** a trailing-`/` entry is valid ONLY when that directory does
not exist at the wave's `base_sha` (`git -C <repo_root> ls-tree <base_sha> -- <dir>` is empty). A
prefix over a directory that already exists is REJECTED at `--validate-plan`. The rule is evaluated
at the PASSED sha, which is re-pinned every wave.

**Self-reads are fine:** a chunk's own `reads` may overlap its own `exclusive_paths`. Only
`writes(A) x reads(B)` for `A != B` is a violation. Reads may freely overlap each other.

### 2.4 `post_integration_commands` allowlist

Per-wave, non-empty. Each command is a single string, checked in two stages.

**Stage 1 - metacharacter rejection.** REJECT the command if it contains any of:

```
;   |   &   $   `   >   <   newline
```

No exceptions, no quoting escape hatch. The command is never passed to a shell interpreter's
parsing rules by this checker, so anything that only has meaning to a shell is out.

**Stage 2 - argv-prefix allowlist.** Tokenize on whitespace, then match the argv prefix against:

| Allowed prefix | Constraint |
| --- | --- |
| `npm run <script>` / `yarn run <script>` / `pnpm run <script>` | `<script>` must be a key present in the repo's `package.json` `scripts` object |
| `npx tsc` | - |
| `node --check` | - |
| `bash scripts/<x>-assumptions/run-all.sh` | `<x>` matches `[A-Za-z0-9._-]+`; path is repo-root-relative |
| `make <target>` | `<target>` is a BARE target token matching `^[A-Za-z0-9._-]+$` (no leading `-`, no path separator, no flags) - so `make -f evil.mk` / `make -C other` cannot select a foreign makefile or directory |

Trailing arguments beyond the matched prefix are allowed (they still passed stage 1).

**Typecheck floor.** When the repo's `package.json` declares a script named `typecheck`, `tsc`,
`lint`, `check`, or `test`, at least ONE command in the wave must invoke one of those scripts via
an `npm|yarn|pnpm run` form. A wave that integrates code and runs nothing that can fail is not a
barrier.

No `package.json` at `<repo_root>` means the `npm|yarn|pnpm run` arm never matches and the
typecheck floor does not apply; the `bash scripts/<x>-assumptions/run-all.sh` and `make` arms
remain available.

This allowlist constrains PARALLELIZER's OUTPUT. A command the orchestrator substitutes by hand
after a documented decision is out of band and is recorded in `wave_state.gate_list[]`, which is
NOT allowlist-checked (see 5.1).

### 2.5 Constants and enums

| Name | Value |
| --- | --- |
| `WAVE_WIDTH_MAX` | `4` (a constant, not an input) |
| `verdict` | `FAN_OUT` \| `SERIAL_CORRECT` |
| `confidence`, `write_set_confidence` | `high` \| `medium` \| `low` |
| checker exit codes | `0` pass, `1` rule violation, `2` usage or environment error |
| waves dir | `$PARALLEL_WAVES_DIR` or `~/.claude/parallel-waves` |
| wave-state path | `<waves dir>/<SAFE_SID>-w<W>.json` |
| event log path | `<waves dir>/rework.log` |

---

## 3. `wave_plan` schema

PARALLELIZER returns EXACTLY one JSON object of this shape - no prose, no Markdown fence.

### 3.1 Top level

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `schema_version` | string | yes | must equal `"parallelizer.v1"` |
| `verdict` | enum | yes | `FAN_OUT` \| `SERIAL_CORRECT` |
| `confidence` | enum | yes | `high` \| `medium` \| `low` |
| `analysis_basis` | object | yes | section 3.2 |
| `waves` | array | yes | non-empty; section 3.3 |
| `hazards_found` | array | yes | may be empty; section 3.5 |
| `serial_reasons` | array of string | yes | may be empty for `FAN_OUT`; MUST be non-empty for `SERIAL_CORRECT` |

Advisory keys carried over from the contract draft MAY be present and are shape-checked only:
`dependency_graph`, `unassigned_item_ids`. Unknown top-level keys are ignored (forward tolerance);
unknown keys inside a chunk are also ignored. Nothing about a chunk's PERMISSIONS is inferable
from an unknown key, so tolerating them cannot widen a write-set.

### 3.2 `analysis_basis`

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `repo_root` | absolute path string | yes | must EQUAL the `--repo-root` passed to the checker |
| `base_sha` | 40-char hex string | yes | ancestry rule below |
| `shared_hazard_paths` | array of path (2.2) | yes | may be empty; prefixes allowed, existence-unbounded |
| `base_ref`, `plan_path`, `pending_item_ids`, `in_flight_item_ids`, `repo_rules_read`, `dirty_paths`, `max_wave_width` | - | no | advisory, shape-checked only |

**`base_sha` ancestry rule.** At wave 1 the plan's `base_sha` must EQUAL the `--base-sha` passed
to the checker. On later-wave re-validation it must be an ANCESTOR of the passed sha
(`git merge-base --is-ancestor`), because the orchestrator re-pins `base_sha` at every wave and
earlier waves have already merged. Equality is also accepted at later waves (an ancestor check
succeeds on identity). A plan whose `base_sha` is NOT an ancestor is analyzing a different history
and is rejected.

**Hazard-path provenance.** The checker never sees the orchestrator's envelope, so it evaluates
the plan's own `shared_hazard_paths`. PARALLELIZER MUST echo the envelope's list verbatim and may
only ADD to it. That the echo happened is the orchestrator's responsibility and is NOT
machine-verified in v1.

### 3.3 `waves[]`

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `wave` | integer | yes | 1-based, sequential, unique across the plan |
| `chunks` | array | yes | length 1..`WAVE_WIDTH_MAX` |
| `post_integration_commands` | array of string | yes | non-empty; every entry satisfies 2.4 |

`depends_on_waves` MAY be present (advisory). Wave ordering is the array order; wave N runs only
after wave N-1 has merged and its barrier is green.

### 3.4 `waves[].chunks[]`

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `id` | string | yes | matches 2.1; unique plan-wide |
| `items` | array of `{id, text}` | yes | non-empty; `text` is the VERBATIM pending-item text |
| `exclusive_paths` | array of path (2.2) | yes | non-empty |
| `reads` | array of exact file path (2.2) | yes | may be empty; bounded per delta 2 |
| `rationale` | string | yes | why this chunk is one unit of work |
| `independent_of` | array of `{chunk_id, reason}` | yes | in a multi-chunk wave, one entry per sibling in the SAME wave; `[]` in a single-chunk wave |
| `write_set_confidence` | enum | yes | `high` \| `medium` \| `low` |

Advisory, shape-checked only: `exclusive_resources` (array of string - delta 5, not
machine-verified), `write_set_evidence`, `depends_on_chunk_ids`.

### 3.5 `hazards_found[]`

Array of `{items[], kind, resources[], disposition, evidence}`. Shape is checked; the `kind` and
`disposition` vocabularies are advisory free strings in v1 (the draft's `same_chunk` /
`different_wave` / `serial` remain the recommended dispositions). This array is evidence for a
human reader and for `serial_reasons`, not a checker input.

### 3.6 Abbreviated example

```json
{
  "schema_version": "parallelizer.v1",
  "verdict": "FAN_OUT",
  "confidence": "high",
  "analysis_basis": {
    "repo_root": "/Users/me/repo",
    "base_sha": "0123456789abcdef0123456789abcdef01234567",
    "shared_hazard_paths": ["package-lock.json", "prisma/schema.prisma"]
  },
  "waves": [
    {
      "wave": 1,
      "chunks": [
        {
          "id": "server-export-route",
          "items": [{ "id": "ITEM-1", "text": "Verbatim pending work item." }],
          "exclusive_paths": ["server/src/routes/export.ts", "server/src/routes/export.test.ts"],
          "reads": ["server/src/routes/index.ts"],
          "rationale": "Leaf route plus its colocated test; no output consumed by a sibling.",
          "independent_of": [
            { "chunk_id": "client-export-panel", "reason": "Disjoint files, no shared generator, no shared fixture." }
          ],
          "write_set_confidence": "high"
        },
        {
          "id": "client-export-panel",
          "items": [{ "id": "ITEM-2", "text": "Second verbatim pending work item." }],
          "exclusive_paths": ["client/src/panels/export/"],
          "reads": [],
          "rationale": "New panel directory, absent at base_sha, so the subtree prefix is admissible.",
          "independent_of": [
            { "chunk_id": "server-export-route", "reason": "Disjoint files; consumes no output of the sibling in this wave." }
          ],
          "write_set_confidence": "high"
        }
      ],
      "post_integration_commands": ["npm run typecheck", "npm run test"]
    }
  ],
  "hazards_found": [],
  "serial_reasons": []
}
```

---

## 4. `wave_plan` validation rules (`--validate-plan`)

`node scripts/verify-parallel-wave.mjs --validate-plan <wave_plan.json> --repo-root <p> --base-sha <sha>`

Run per wave, at that wave's re-pinned `base_sha`. Rules, all evaluated at the PASSED sha:

1. Shape: every required key present with the declared type; enums in range; `schema_version` is
   `parallelizer.v1.1`. Violation -> exit 1, reason `rule_violation`.
2. `analysis_basis.repo_root` equals `--repo-root`.
3. `analysis_basis.base_sha` satisfies the ancestry rule (3.2).
4. Chunk ids match 2.1 and are unique plan-wide.
5. Wave width <= `WAVE_WIDTH_MAX`.
6. Path syntax (2.2) for every `exclusive_paths`, `reads`, and `shared_hazard_paths` entry.
7. Subtree prefixes only for directories absent at `base_sha` (2.3).
8. Declared write-sets pairwise DISJOINT within a wave (2.3 overlap predicate).
9. `writes(A)` disjoint from `reads(B)` for every ordered sibling pair `A != B` in the same wave.
10. `writes(any chunk)` disjoint from `analysis_basis.shared_hazard_paths`.
11. `post_integration_commands` non-empty; every command passes 2.4 stage 1, stage 2, and the wave
    satisfies the typecheck floor.
12. In a multi-chunk wave: `write_set_confidence` is `high` for every chunk, top-level
    `confidence` is `high`, and every chunk carries an `independent_of` entry naming each sibling.
    Violation -> exit 1, reason `low_confidence`.
13. `verdict == "SERIAL_CORRECT"` -> every wave has exactly one chunk and `serial_reasons` is
    non-empty; the checker exits 1 with reason `serial_correct` (the orchestrator runs serial and
    does not need a validated plan).

A rule violation (rules 1-11) -> exit 1, reason `rule_violation`. Rule 12 -> `low_confidence`;
rule 13 -> `serial_correct`. Exit 0 -> reason `fan_out`. An unreadable or unparseable input file,
a non-git `--repo-root`, an unresolvable `--base-sha`, or a git failure -> exit 2, reason
`io_error`.

---

## 4a. `wave_plan` binding sidecar (the C2 fix)

On the exit-0 (`fan_out`) path, `--validate-plan` writes a sidecar next to the plan at
`<wave_plan_path>.validated`. On the exit-1 (rule) path it REMOVES any stale sidecar, so a plan
that fails validation cannot leave a blessing behind. Shape:

```json
{ "schema_version": "parallelizer.v1.1", "waves": { "1": "<sha256hex>", "2": "<sha256hex>" } }
```

Each per-wave value is the sha256 of the CANONICAL content shared verbatim by the plan and the
runtime `wave_state`: `repo_root` (symlink-resolved), the wave's `shared_hazard_paths`, the wave
number, and each chunk's `{id, exclusive_paths, reads}` - every path list normalized (2.2),
de-duplicated, and sorted, and the chunks sorted by id. `base_sha` is DELIBERATELY excluded: the
orchestrator re-pins it every wave (3.2), so it drifts legitimately and is verified separately by
ancestry. The sidecar is the INDEPENDENT artifact only a passing `--validate-plan` could produce;
`--wave-state` recomputes the same hash and requires a match (s6 rule 12). The write is best-effort
telemetry - a failure to write is loud but never turns a passing plan into a failing one.

---

## 5. `wave_state` schema

Written by the orchestrator to `<waves dir>/<SAFE_SID>-w<W>.json` BEFORE the chunk implementers
are spawned. It is the runtime mirror of one wave: what the plan promised, plus where the work
actually lives. `merge-wave.sh` mutates only `merged_chunks[]`, via node read-modify-write to a
`.tmp` file then `mv -f` (never a partial JSON on crash).

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `repo_root` | absolute path string | yes | the integration checkout |
| `base_sha` | 40-char hex string | yes | this wave's re-pinned base; every worktree starts here |
| `wave` | integer | yes | 1-based; matches the `w<W>` in the filename |
| `wave_plan_path` | absolute path string | yes | **v1.1** - the `wave_plan` that `--validate-plan` blessed; `<this>.validated` is the binding sidecar (4a, s6 rule 12) |
| `shared_hazard_paths` | array of path (2.2) | yes | **v1.1** - echoed verbatim from that plan's `analysis_basis.shared_hazard_paths`; feeds the binding hash and the s6 rule 15 re-run |
| `impl_plan_path` | absolute path string or `null` | yes | dirty-tree exemption applies ONLY when this resolves UNDER `repo_root`; outside or `null` -> no exemption |
| `merged_chunks` | array of `{id, merge_sha}` | yes | `[]` before the first merge; append-only, in merge order; `merge_sha` is the resulting MERGE COMMIT, not the branch tip |
| `gate_list` | array of string | yes | the Step-3.5-discovered gate commands, recorded verbatim so the barrier re-runs EXACTLY that list; NOT allowlist-checked (5.1) |
| `chunks` | array | yes | one entry per chunk in this wave; section 5.2 |

### 5.1 `gate_list` is not allowlisted

The 2.4 allowlist constrains what a MODEL may emit. `gate_list` is discovered by the orchestrator
from the target repo at Step 3.5 and may legitimately contain forms the allowlist excludes. It is
human-recorded, in band for the barrier, and out of band for the allowlist. When `repo_root` is not
the orchestrator's cwd, the gates are re-discovered under `repo_root` and the delta is recorded.

### 5.2 `wave_state.chunks[]`

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `id` | string | yes | matches 2.1; equals the plan chunk id |
| `branch` | string | yes | `w<W>-<SID8>-<chunk-id>` |
| `worktree` | absolute path string | yes | `~/.claude/wave-worktrees/<SID8>/w<W>-<chunk-id>` (fallback location per the plan's Assumption Gates) |
| `exclusive_paths` | array of path (2.2) | yes | copied verbatim from the validated plan |
| `reads` | array of exact file path (2.2) | yes | copied verbatim from the validated plan |

### 5.3 Example

```json
{
  "repo_root": "/Users/me/repo",
  "base_sha": "0123456789abcdef0123456789abcdef01234567",
  "wave": 1,
  "wave_plan_path": "/Users/me/.claude/parallel-waves/a1b2c3d4-w1.plan.json",
  "shared_hazard_paths": ["package-lock.json", "prisma/schema.prisma"],
  "impl_plan_path": "/Users/me/repo/tmp/ready-plans/2026-08-02-example.md",
  "merged_chunks": [],
  "gate_list": ["npm run typecheck", "bash scripts/example-assumptions/run-all.sh"],
  "chunks": [
    {
      "id": "server-export-route",
      "branch": "w1-a1b2c3d4-server-export-route",
      "worktree": "/Users/me/.claude/wave-worktrees/a1b2c3d4/w1-server-export-route",
      "exclusive_paths": ["server/src/routes/export.ts", "server/src/routes/export.test.ts"],
      "reads": ["server/src/routes/index.ts"]
    }
  ]
}
```

---

## 6. `wave_state` validation rules (`--wave-state`)

`node scripts/verify-parallel-wave.mjs --wave-state <wave-state.json>`

Run at the barrier, before any merge, and again inline by `merge-wave.sh`. Before the per-chunk
loop, the state is BOUND to the blessed plan (4a, the C2 fix):

- **rule 12 (binding sidecar).** Read `<wave_plan_path>.validated`. Recompute the canonical
  per-wave hash (4a) from THIS state's `repo_root`, `shared_hazard_paths`, `wave`, and `chunks`.
  The sidecar must exist and record a matching hash for `wave`. Absent or mismatch -> violation
  (the state's topology was never gated, or drifted after blessing).

Per chunk:

1. The `worktree` path exists and is a git worktree. Missing -> exit 2.
2. `base_sha` is an ANCESTOR of the worktree HEAD.
3. The worktree is CLEAN - `git status --porcelain` INCLUDING untracked files must be empty. An
   untracked file is unfinished work that the merge would silently drop.
4. The worktree has at least ONE commit beyond `base_sha`.
5. `touched = git -C <worktree> diff --name-only --no-renames -z <base_sha>..HEAD`. Renames count
   BOTH sides (that is what `--no-renames` buys).
13. **(C3) branch binds to verified HEAD.** `branch` must resolve, from `repo_root`, to exactly
    the verified worktree HEAD. Unresolvable or mismatched -> violation. Without this, `merge-wave`
    (which merges the branch by NAME) could integrate a wrong/advanced ref the barrier never
    inspected.
14. **(C2 defense-in-depth) subtree prefix.** Any trailing-`/` `exclusive_paths` entry is
    admissible ONLY over a directory ABSENT at `base_sha` (2.3), re-checked here, not only at
    `--validate-plan`.
15. **(C2 defense-in-depth) hazard disjointness.** Declared `exclusive_paths` disjoint from
    `shared_hazard_paths` (the rule 10 of `--validate-plan`, re-run against the runtime state).

Then across chunks:

6. Each chunk's `touched` is a subset of its own `exclusive_paths` (2.3 `matches`).
7. Declared `exclusive_paths` sets pairwise disjoint.
8. Actual `touched` sets pairwise disjoint.
9. `touched(A)` disjoint from `reads(B)` for every ordered sibling pair `A != B`.
10. `repo_root` HEAD is in `{base_sha} union merged_chunks[].merge_sha` (verbatim sha comparison -
    merge commits, not branch tips). This is what makes an interrupted merge RESUMABLE rather than
    a refusal.
16. **(C4) `merged_chunks` integrity.** Each entry's `id` is UNIQUE, is a member of `chunks[]`, and
    its `merge_sha` is a real commit (`git cat-file -e <sha>^{commit}`) AND an ancestor of
    `repo_root` HEAD. A shape-only check let a forged/duplicated/dangling entry widen rule 10's
    allow-list.
11. `repo_root` is tracked-clean (`git status --porcelain --untracked-files=no`), except for
    `impl_plan_path` when it resolves under `repo_root`.

A cleanliness or HEAD-position violation (rules 3, 10, 11) -> exit 1, reason `dirty_repo_root`.
Any other rule violation (rules 2, 4, 6-9, 12-16) -> exit 1, reason `rule_violation`. Exit 0 ->
reason `fan_out`. An unreadable, unparseable, or path-missing input, or a git failure -> exit 2,
reason `io_error`.

On failure the wave HALTS: preserve every worktree and branch, merge nothing, start no next wave,
reconcile serially, then re-verify.

### 6a. `merge-wave.sh` branch pre-check (Fix 6)

Before merging, `merge-wave.sh` validates each `branch` with `git check-ref-format --branch` and
rejects a leading `-`, so an unvalidated ref cannot be read as a git option by `git merge`. rule 13
(above, run inline) is the primary catcher; this is the callsite backstop. Either way a bad branch
merges NOTHING.

---

## 7. `rework.log` event schema

One event per invocation of `verify-parallel-wave.mjs` (the `validate-plan`, `wave-state`, and
`log-decision` modes, BOTH exit paths) and per outcome of `merge-wave.sh`. Appended with a single
`fs.appendFileSync` to `<waves dir>/rework.log`.

**One serializer (s8, the event-format dedup fix).** The event line is built in exactly ONE place
- `buildEventLine()` in the checker. `merge-wave.sh` does NOT hand-roll the line; it emits through
the checker's `--emit-event --exit <n> --reason <token> --repo-root <p> --wave <n>` mode, which
sets `tool_mode: wave-state` (a merge is an operation ON a wave-state) and appends via the same
serializer. This mode emits ONLY the passed event and does not write a second event for its own
invocation.

### 7.1 Format

Single-line JSONL. **Hard cap: 480 bytes for the complete line INCLUDING its terminating
newline.** Concurrent-appender atomicity is only proven below `PIPE_BUF`; a longer line can
interleave and corrupt the log that the whole measurement story rests on.

Fixed key set, emitted in this order:

| Key | Type | Notes |
| --- | --- | --- |
| `ts` | ISO-8601 UTC string | e.g. `2026-08-02T18:04:11Z` |
| `tool_mode` | `validate-plan` \| `wave-state` \| `log-decision` | closed set |
| `decision` | `serial` \| `fan_out` \| `null` | the `--log-decision` argument; `null` in the other two modes |
| `verdict` | `FAN_OUT` \| `SERIAL_CORRECT` \| `null` | the verdict READ from the wave_plan under `--validate-plan`; `null` elsewhere and when unparseable |
| `exit` | integer | the process exit code (0 \| 1 \| 2) |
| `repo_root` | string | absolute path; the only unbounded field |
| `wave` | integer or `null` | the wave number when known |
| `reason` | closed token (7.2) | never `null` |

`truncated` is added as a NINTH key, `true`, only when the overflow rule fires. Its absence means
the line is complete.

**Overflow rule (deterministic).** Every field except `repo_root` is bounded by construction.
If the encoded line plus its newline exceeds 480 bytes:

1. Replace `repo_root` with its LAST 80 characters (the leaf is what distinguishes repos) and set
   `truncated: true`; re-encode.
2. If it still exceeds 480 bytes, set `repo_root` to `""`, keep `truncated: true`, and re-encode.

A reader treats `truncated: true` as "repo_root is not a reliable join key for this event".
`parallel-stats.py` drops events whose `repo_root` is under a fixtures directory.

### 7.2 Closed reason-token set

```
lt2_chunks | no_review | dirty_repo_root | merge_in_progress | pct_unknown |
pct_over_60 | stale_wave | dotfiles_unpaused | serial_correct | low_confidence | fan_out |
rule_violation | usage_error | io_error | merge_success | merge_conflict | malformed
```

**v1.1** de-aliased the five tokens on the second row from what v1 flattened into
`malformed`/`fan_out`: a merge conflict, a merge success, a usage error, an environment/io error,
and a real rule violation are now distinct, so analytics can tell a bad plan from a conflict from a
merged wave. `malformed` is RETAINED as the fail-closed fallback `writeEvent` uses when a token
outside this set somehow reaches it.

An unknown `--log-decision --reason` token is REJECTED: the checker exits 2 with `reason:
"usage_error"` and still writes ONE event, with `decision` set to the passed decision when that
argument was itself valid, `null` otherwise. Rejecting unknown tokens is what keeps the denominator
honest - a typo'd reason would otherwise become a silent new category.

Token meanings (the orchestrator's serial-gate conditions come first; these are the
`--log-decision` reasons):

| Token | Emitted when |
| --- | --- |
| `lt2_chunks` | fewer than 2 pending chunks |
| `no_review` | `NO_REVIEW = true` (mission path) |
| `dirty_repo_root` | tracked-dirty `repo_root`, or a barrier cleanliness/HEAD violation (rules 3, 10, 11) |
| `merge_in_progress` | a merge or rebase is in progress at `repo_root` |
| `pct_unknown` | the context-percentage broker value is empty or unresolvable |
| `pct_over_60` | context usage above 60% |
| `stale_wave` | a wave-state for the same `repo_root` still has worktrees on disk |
| `dotfiles_unpaused` | `repo_root` is `~/.claude-dotfiles` without the sync-pause marker |
| `serial_correct` | PARALLELIZER returned `SERIAL_CORRECT` |
| `low_confidence` | a multi-chunk wave lacked `high` confidence |
| `fan_out` | the fan-out proceeded, or a checker mode PASSED (`--validate-plan` / `--wave-state` exit 0) |
| `rule_violation` | a `wave_plan` or `wave_state` failed schema/rule validation (exit 1) |
| `usage_error` | a CLI/argument usage error, incl. an unknown `--reason` token (exit 2) |
| `io_error` | unreadable/unparseable input, a non-git repo, or a git/environment failure (exit 2) |
| `merge_success` | `merge-wave.sh` integrated the wave (exit 0) |
| `merge_conflict` | `merge-wave.sh` hit a conflict/refusal and merged nothing further (exit 1) |
| `malformed` | fail-closed fallback for a token outside this set reaching `writeEvent` |

### 7.3 Examples

```
{"ts":"2026-08-02T18:04:11Z","tool_mode":"log-decision","decision":"serial","verdict":null,"exit":0,"repo_root":"/Users/me/repo","wave":null,"reason":"pct_over_60"}
{"ts":"2026-08-02T18:09:02Z","tool_mode":"validate-plan","decision":null,"verdict":"FAN_OUT","exit":0,"repo_root":"/Users/me/repo","wave":1,"reason":"fan_out"}
{"ts":"2026-08-02T18:31:44Z","tool_mode":"wave-state","decision":null,"verdict":null,"exit":1,"repo_root":"/Users/me/repo","wave":1,"reason":"rule_violation"}
{"ts":"2026-08-02T18:33:10Z","tool_mode":"wave-state","decision":null,"verdict":null,"exit":0,"repo_root":"/Users/me/repo","wave":1,"reason":"merge_success"}
```

---

## 8. Change control

- A change to any frozen shape bumps `schema_version` and updates, in ONE commit:
  `docs/wave-plan-schema.md`, `scripts/verify-parallel-wave.mjs`,
  `scripts/verify-parallel-wave-assumptions/`, and `agents/parallelizer.md`.
- The checker rejects a `schema_version` it does not implement rather than best-effort parsing it.
  A silently accepted older shape is exactly the failure this freeze exists to prevent.
- Adding a `reason` token is a schema change: the closed set is the measurement contract.
- **2026-08-03 - `parallelizer.v1` -> `parallelizer.v1.1`** (codex-review C2/C3/C4/C9 + adversarial):
  added `wave_state.wave_plan_path` + `shared_hazard_paths`, the `<wave_plan>.validated` binding
  sidecar (4a/6a), `wave_state` rules 12-16, the tightened `make`/path rules (2.2/2.4), the
  de-aliased `reason` tokens (7.2), and the single `--emit-event` serializer (7/8). `parallelizer.md`
  is the one remaining v1 citation to reconcile when the agent definition is next revised; the
  checker rejects a plain `parallelizer.v1` document, so no v1 plan is silently accepted.
