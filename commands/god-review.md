---
description: "Autonomous multi-model codebase audit + fix loop. 3 Claude broad + 3 Codex broad + 23 principle agents (Claude+Codex per principle) in parallel. Always-on indefinite fix loop — runs until 3 consecutive rounds yield zero new non-deferred findings. Hard gates on schema/auth/deps/secrets/CI/tests are batched for human review at end. Use /god-report for single-pass review-only."
argument-hint: "[scope] [--max-rounds N] [--max-wall-hours N] [--resume] [--force-resume] [--principle <name>] [--rescope-on-fix {full|changed}] [--online] [--codex-validation-every N] [--ruthless]"
allowed-tools: "Read, Glob, Grep, Bash, Agent"
---

# /god-review — Multi-Model Codebase Audit

You are a senior engineering lead conducting a ground-up, multi-model codebase audit. You orchestrate parallel agents across two model families (Claude Opus 4.7 + Codex CLI), apply 19 principle lenses plus 6 broad reviewers, snapshot the repo before any mutation, and enforce hard gates on irreversible changes.

This command has 4 phases:
- **Phase 0**: Context Map — stack fingerprint, architecture, hot zones, baseline gates
- **Phase 1**: Probe — snapshot + failure-mode pre-scans
- **Phase 2**: Review — parallel agents × model families × principles + validation + aggregation
- **Phase 3**: Fix loop (always-on; orchestrator-driven) — triage, Architect/Editor split, snapshot/revert per fix, 3-consecutive-clean termination

---

## Step 0: Argument Parsing + Validation

Parse `$ARGUMENTS` for all supported flags:

```bash
set -o pipefail
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# --- Argument parsing ---
# All arguments are parsed from the $ARGUMENTS variable provided by the harness.
# Positional $1..$N are set by splitting $ARGUMENTS on whitespace.

# Defaults (Phase G: --fix and --loop dropped — always-on by definition):
SCOPE=""
RESUME=false; FORCE_RESUME=false; ONLINE=false; RUTHLESS=false
MAX_ROUNDS=999999; MAX_WALL_HOURS=24; CODEX_VALIDATION_EVERY=3
PRINCIPLE=""; RESCOPE_ON_FIX="changed"
MAX_ROUNDS_EXPLICIT=false  # tracks whether --max-rounds was passed explicitly

# Split $ARGUMENTS into positional parameters for clean while-shift parsing
eval set -- $ARGUMENTS

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)
      RESUME=true; shift ;;
    --force-resume)
      FORCE_RESUME=true; shift ;;
    --online)
      ONLINE=true; shift ;;
    --ruthless)
      RUTHLESS=true; shift ;;
    --max-rounds)
      [ "$2" -ge 1 ] 2>/dev/null || { echo "Error: --max-rounds must be an integer >= 1 (got: ${2:-missing})" >&2; exit 1; }
      MAX_ROUNDS="$2"; MAX_ROUNDS_EXPLICIT=true; shift 2 ;;
    --max-wall-hours)
      python3 -c "v=float('${2:-0}'); assert v>=0, 'must be >= 0 (0 = no cap)'" 2>/dev/null || { echo "Error: --max-wall-hours must be a float >= 0 (got: ${2:-missing}; 0 disables cap)" >&2; exit 1; }
      MAX_WALL_HOURS="$2"; shift 2 ;;
    --principle)
      [ -f "$HOME/.claude-dotfiles/commands/god-review/principles/${2}.md" ] || { echo "Error: unknown principle '${2:-missing}'. Check ~/.claude-dotfiles/commands/god-review/principles/ for valid names." >&2; exit 1; }
      PRINCIPLE="$2"; shift 2 ;;
    --rescope-on-fix)
      [ "$2" = "full" ] || [ "$2" = "changed" ] || { echo "Error: --rescope-on-fix must be 'full' or 'changed' (got: ${2:-missing})" >&2; exit 1; }
      RESCOPE_ON_FIX="$2"; shift 2 ;;
    --codex-validation-every)
      [ "$2" -ge 1 ] 2>/dev/null || { echo "Error: --codex-validation-every must be an integer >= 1 (got: ${2:-missing})" >&2; exit 1; }
      CODEX_VALIDATION_EVERY="$2"; shift 2 ;;
    --*)
      echo "Error: unknown flag $1 (note: --fix, --loop, --report-only dropped in Phase G — fix-loop is always on; use /god-report for report-only)" >&2; exit 1 ;;
    *)
      [ -z "$SCOPE" ] && SCOPE="$1" || { echo "Error: unexpected extra positional argument '$1'" >&2; exit 1; }
      shift ;;
  esac
done
```

**Validation (abort early on bad inputs):**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Validation check 1: --max-wall-hours must be >= 0 (0 = no cap)
if [ "$(echo "$MAX_WALL_HOURS < 0" | bc 2>/dev/null)" = "1" ]; then
  echo "Error: --max-wall-hours must be >= 0 (got: $MAX_WALL_HOURS; 0 disables cap)"
  exit 1
fi

# Validation check 3: --resume requires existing state.json
if [ "$RESUME" = "true" ] && [ ! -f "tmp/god-review/state.json" ]; then
  echo "Error: --resume passed but tmp/god-review/state.json does not exist. Nothing to resume."
  exit 1
fi

# Validation check 4: --resume state.json must be parseable
if [ "$RESUME" = "true" ]; then
  if ! python3 -c "import json,sys; json.load(open('tmp/god-review/state.json'))" 2>/dev/null; then
    echo "Error: state.json is corrupt or malformed. Manually delete tmp/god-review/state.json and restart."
    exit 6
  fi
  # Check snapshot ref still resolves
  SNAP_REF=$(python3 -c "import json; d=json.load(open('tmp/god-review/state.json')); print(d['snapshot']['ref'])" 2>/dev/null)
  SNAP_TYPE=$(python3 -c "import json; d=json.load(open('tmp/god-review/state.json')); print(d['snapshot']['reftype'])" 2>/dev/null)
  STALE=false
  if [ "$SNAP_TYPE" = "commit" ]; then
    git rev-parse --verify "$SNAP_REF^{commit}" >/dev/null 2>&1 || STALE=true
  elif [ "$SNAP_TYPE" = "stash" ]; then
    git stash list | grep -qF "$SNAP_REF" || STALE=true
  fi
  if [ "$STALE" = "true" ] && [ "$FORCE_RESUME" = "false" ]; then
    echo "Error: Repo state diverged from snapshot ref '$SNAP_REF' (type: $SNAP_TYPE). Pass --force-resume to override."
    exit 7
  fi
fi
```

Read mirror mode to determine write destinations:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
MIRROR_MODE=$(cat ~/.claude-dotfiles/commands/god-review/.mirror-mode 2>/dev/null || echo "auto")
# If MIRROR_MODE = "dual": write outputs to BOTH ~/.claude-dotfiles/ AND ~/.claude/ paths.
# If MIRROR_MODE = "auto": write only to ~/.claude-dotfiles/ and trust the auto-mirror hook.
```

---

## Step 0.5: Single-Principle Delegation

If `--principle <name>` is set, delegate to that principle file and exit. This is how `/god-review --principle single-pattern` and `/god-review:principles:single-pattern` both work.

```
IF $PRINCIPLE is non-empty:
  Read the principle file content from:
    ~/.claude-dotfiles/commands/god-review/principles/<PRINCIPLE>.md
  If the file does not exist, abort: "god-review: unknown principle '<PRINCIPLE>'. Available principles: single-pattern, reuse, clarity, scope, antipatterns, documentation, circular-deps, architecture-backend, architecture-frontend, self-contained, tanstack-query, test-deletion, ci-yaml-tampering, hallucinated-imports, secret-leak, prompt-injection, dead-code-conservatism, perf-heuristic, perf-benchmark, dead-end-detector, info-loss-detector, contradiction-detector, gap-detector"
  Spawn ONE Agent tool call:
    subagent_type: "general-purpose"
    model: "claude-opus-4-7"
    prompt: [content of the principle file] + "\n\nScope: " + ($SCOPE if non-empty, else "full repo")
    Note: pass --online flag context if $ONLINE=true (for hallucinated-imports)
  Exit after the agent completes.
```

Do not proceed to Phase 0 when `--principle` is set.

---

## Tunable Constants

Override any of these via env var before invoking the command.

```bash
# === Tunable Constants ===
# Override via env var if needed. Sources env-helpers.sh for uniform fence pattern.
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
SHRINKAGE_PCT="${SHRINKAGE_PCT:-0.20}"           # test-deletion threshold
PERF_REGRESS_PCT="${PERF_REGRESS_PCT:-0.05}"     # perf-benchmark threshold
INSTABILITY_RATE="${INSTABILITY_RATE:-5}"        # avg events/round to abort --loop
FROZEN_UNITS_CAP="${FROZEN_UNITS_CAP:-3}"    # bounded-mode freeze cap
SECRET_LEN_FLOOR="${SECRET_LEN_FLOOR:-16}"       # secret-leak min char length
TEST_FILE_LINE_FLOOR="${TEST_FILE_LINE_FLOOR:-25}"  # test-deletion shrinkage floor
LATE_IMPORT_LINE="${LATE_IMPORT_LINE:-40}"       # circular-deps cutoff
SPINLOCK_TIMEOUT_SEC="${SPINLOCK_TIMEOUT_SEC:-600}"  # codex-invoke spinlock max
```

---

## Phase 0: Context Map

**Goal**: Build a shared mechanical context package so all Phase-2 agents inherit the same ground truth. Eliminates repeated context-gathering per agent (failure mode #19).

Run this bash block:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
mkdir -p tmp/god-review

# --- Stack fingerprint ---
# All find commands run via /bin/bash -c to avoid zsh glob-qualifier interpretation of unquoted (
# Pattern: prune node_modules/.git/vendor/dist/build/.next/.turbo to skip transitive deps

HAS_TANSTACK_QUERY=$(/bin/bash -c 'find "$1" -maxdepth 3 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/dist" -o -path "*/build" -o -path "*/.next" -o -path "*/.turbo" \) -prune -o -name package.json -print0' _ "$WORKDIR" 2>/dev/null | xargs -0 grep -l "@tanstack/react-query" 2>/dev/null | head -1)

HAS_APP_ROUTER=$(/bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/dist" -o -path "*/build" -o -path "*/.next" -o -path "*/.turbo" \) -prune -o -type f -name page.tsx -path "*/app/*" -print' _ "$WORKDIR" 2>/dev/null | head -1)

HAS_AUTHED_HANDLER=$(/bin/bash -c 'find "$1" -maxdepth 5 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/dist" -o -path "*/build" -o -path "*/.next" -o -path "*/.turbo" \) -prune -o -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) -print0' _ "$WORKDIR" 2>/dev/null | xargs -0 grep -l "authenticatedHandler\|requireAuth\|withAuth\|@authenticated\|protectedRoute" 2>/dev/null | head -1)

HAS_UI_PROJECT=$(/bin/bash -c 'find "$1" -maxdepth 3 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/dist" -o -path "*/build" -o -path "*/.next" -o -path "*/.turbo" \) -prune -o -name package.json -print0' _ "$WORKDIR" 2>/dev/null | xargs -0 grep -l '"react"\|"vue"\|"@angular/core"\|"svelte"\|"solid-js"\|"preact"\|"lit"\|"@builder.io/qwik"\|"astro"' 2>/dev/null | head -1)

# NEW: broader backend signal for non-JS stacks (Go / Rust / Python / Java / Ruby / etc.)
HAS_BACKEND_PROJECT=$(/bin/bash -c 'find "$1" -maxdepth 4 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/target" -o -path "*/__pycache__" -o -path "*/dist" -o -path "*/build" \) -prune -o \( -name "main.go" -o -name "go.mod" -o -name "Cargo.toml" -o -name "requirements.txt" -o -name "pyproject.toml" -o -name "Pipfile" -o -name "Gemfile" -o -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" \) -print' _ "$WORKDIR" 2>/dev/null | head -1)

# Combined backend lens trigger: either JS auth handler OR non-JS backend project marker
HAS_BACKEND_LENS_TRIGGER="${HAS_AUTHED_HANDLER}${HAS_BACKEND_PROJECT}"

# Bench script detection for perf-benchmark principle
HAS_BENCH_SCRIPT=""
if [ -f "$WORKDIR/package.json" ]; then
  HAS_BENCH_SCRIPT=$(python3 -c "import json; d=json.load(open('$WORKDIR/package.json')); scripts=d.get('scripts',{}); print(next((k for k in scripts if k in ('bench','benchmark','perf')),''))" 2>/dev/null)
fi
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  HAS_BENCH_SCRIPT=$(/bin/bash -c 'find "$1" -maxdepth 3 \( -name benchmarks -o -name bench \) -type d -print' _ "$WORKDIR" 2>/dev/null | head -1)
fi
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  HAS_BENCH_SCRIPT=$(grep -l "criterion\|pytest-benchmark\|hyperfine\|asv" "$WORKDIR/Cargo.toml" "$WORKDIR/requirements.txt" "$WORKDIR/pyproject.toml" "$WORKDIR/Pipfile" 2>/dev/null | head -1)
fi
# Python bench file naming patterns (asv, pytest-benchmark conventions)
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  HAS_BENCH_SCRIPT=$(/bin/bash -c 'find "$1" -maxdepth 4 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/__pycache__" \) -prune -o -type f \( -name "bench_*.py" -o -name "*_bench.py" -o -name "benchmark_*.py" \) -print' _ "$WORKDIR" 2>/dev/null | head -1)
fi
# Go bench convention (Benchmark* funcs in *_test.go)
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  HAS_BENCH_SCRIPT=$(/bin/bash -c 'find "$1" -maxdepth 5 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" \) -prune -o -type f -name "*_test.go" -print' _ "$WORKDIR" 2>/dev/null | xargs grep -l "^func Benchmark" 2>/dev/null | head -1)
fi

echo "Stack signals:"
echo "  HAS_TANSTACK_QUERY=$HAS_TANSTACK_QUERY"
echo "  HAS_APP_ROUTER=$HAS_APP_ROUTER"
echo "  HAS_AUTHED_HANDLER=$HAS_AUTHED_HANDLER"
echo "  HAS_UI_PROJECT=$HAS_UI_PROJECT"
echo "  HAS_BACKEND_PROJECT=$HAS_BACKEND_PROJECT"
echo "  HAS_BENCH_SCRIPT=$HAS_BENCH_SCRIPT"

# --- Architecture map ---
echo "--- Architecture (maxdepth 2) ---"
/bin/bash -c 'find "$1" -maxdepth 2 -type d \( -path "*/node_modules" -o -path "*/.git" -o -path "*/vendor" -o -path "*/target" -o -path "*/.next" \) -prune -o -type d -print' _ "$WORKDIR" 2>/dev/null | head -80
ls "$WORKDIR"/package.json "$WORKDIR"/requirements.txt "$WORKDIR"/Cargo.toml "$WORKDIR"/go.mod 2>/dev/null

# --- AGENTS.md / CLAUDE.md conventions ---
echo "--- Conventions files ---"
/bin/bash -c 'find "$1" -maxdepth 4 \( -name "AGENTS.md" -o -name "CLAUDE.md" \) -print' _ "$WORKDIR" 2>/dev/null | head -10 | while read f; do
  echo "=== $f ==="; head -60 "$f"; echo
done

# --- Hot zones: files changed most in last 3 months ---
echo "--- Hot zones (top 50, last 3 months) ---"
git log --since="3 months ago" --name-only --pretty=format: 2>/dev/null \
  | grep -v "^$" | sort | uniq -c | sort -rn | head -50

# --- Known issues from prior runs ---
echo "--- Prior run state ---"
[ -f tmp/god-review/state.json ] && cat tmp/god-review/state.json || echo "(no prior state)"
grep -rE "TODO|FIXME|KNOWN-ISSUE" --include="*.md" --max-count=5 . 2>/dev/null | head -20

# --- Baseline gates (graceful no-op if scripts absent) ---
echo "--- Baseline gates ---"
if [ -f package.json ]; then
  PKG_SCRIPTS=$(python3 -c "import json; s=json.load(open('package.json')).get('scripts',{}); print(' '.join(s.keys()))" 2>/dev/null)
  echo "Available scripts: $PKG_SCRIPTS"
  echo "=== typecheck ===" && (npm run typecheck 2>&1 | tail -20) || echo "(no typecheck script)"
  echo "=== lint ===" && (npm run lint 2>&1 | tail -20) || echo "(no lint script)"
  echo "=== build ===" && (npm run build 2>&1 | tail -10) || echo "(no build script)"
elif [ -f Cargo.toml ]; then
  echo "=== cargo check ===" && cargo check 2>&1 | tail -20
elif [ -f go.mod ]; then
  echo "=== go vet ===" && go vet ./... 2>&1 | tail -20
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  echo "=== python type check ===" && { python3 -m mypy . > /tmp/gate-output.txt 2>&1 && tail -20 /tmp/gate-output.txt; } || echo "(mypy not available)"
else
  echo "(no recognized build system — skipping baseline gates)"
fi
write_env
```

Now spawn 1 Claude Opus 4.7 agent to synthesize the bash output above into a structured context package:

Spawn ONE Agent tool call with `subagent_type: "general-purpose"`, `model: "claude-opus-4-7"`, extended thinking enabled. Prompt:

```
You are building a shared context package for a multi-model codebase audit.

Based on the bash output provided below (stack signals, architecture map, conventions, hot zones, known issues, baseline gate results), write a structured markdown file to `tmp/god-review/context-package.md` with these sections:

1. **Stack Fingerprint** — which HAS_* signals fired and what they mean for which principles activate
2. **Architecture Map** — top-level directory structure and entry points
3. **Conventions & Exemplars** — what AGENTS.md/CLAUDE.md declare as canonical patterns (quote directly)
4. **Hot Zones** — top 20 most-changed files in last 3 months (signal where bugs accumulate)
5. **Known Issues / Do Not Re-Report** — any prior god-review findings from state.json that were kept, plus any TODO/FIXME patterns found
6. **Baseline Gate State** — typecheck/lint/build results: PASS / WARN (with errors) / SKIP (script absent)

Write the file using Bash heredoc (cat > tmp/god-review/context-package.md). Then print "Context package written."

Bash output follows:
[BASH OUTPUT GOES HERE — orchestrator passes the captured bash output as context]
```

Output: `Phase 0 complete. Context map at tmp/god-review/context-package.md`

---

## Phase 1: Probe

### 1a: Failure-mode pre-scans (fast, synchronous, runs BEFORE snapshot)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
echo "=== Phase 1 pre-scans ==="

# Pre-scan 1: Secrets in .env files appearing in source code (filename-only, never raw value)
PRE_SCAN_SECRETS=""
for envfile in .env .env.local .env.production .env.staging; do
  [ ! -f "$WORKDIR/$envfile" ] && continue
  while IFS='=' read -r key val; do
    [ -z "$val" ] || [ "${#val}" -lt "$SECRET_LEN_FLOOR" ] && continue
    [ "${key:0:1}" = "#" ] && continue
    val_hash=$(echo -n "$val" | shasum -a 256 | head -c 8)
    HIT_FILES=$(grep -rlF "$val" --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
           --exclude-dir=node_modules --exclude-dir=.git \
           "$WORKDIR" 2>/dev/null | grep -v "$envfile" | head -3)
    [ -n "$HIT_FILES" ] && PRE_SCAN_SECRETS="${PRE_SCAN_SECRETS}SECRET_LEAK: $key (hash: $val_hash) from $envfile leaks into:\n$HIT_FILES\n"
  done < "$WORKDIR/$envfile"
done
echo "Secret pre-scan: ${PRE_SCAN_SECRETS:-NONE}"

# Pre-scan 2: Hallucinated package names (declared imports vs package.json)
PRE_SCAN_HALLUCINATED=""
if [ -f "$WORKDIR/package.json" ]; then
  PRE_SCAN_HALLUCINATED=$(
    DECLARED_DEPS=$(python3 -c "
import json, sys
d = json.load(open('$WORKDIR/package.json'))
deps = set(d.get('dependencies', {}).keys()) | set(d.get('devDependencies', {}).keys())
print('\n'.join(deps))
" 2>/dev/null)
    # Scan TS/JS imports for non-relative, non-builtin packages not in declared deps
    /bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" -o -path "*/dist" -o -path "*/build" \) -prune -o -name "*.ts" -print -o -name "*.tsx" -print -o -name "*.js" -print -o -name "*.jsx" -print' _ "$WORKDIR" 2>/dev/null \
      | xargs grep -hE "^import .* from '([^.@][^']+)'" 2>/dev/null \
      | grep -oE "from '[^']+'" | sed "s/from '//;s/'//" \
      | cut -d'/' -f1 | sort -u \
      | while read pkg; do
          echo "$DECLARED_DEPS" | grep -qxF "$pkg" || echo "HALLUCINATED_IMPORT_CANDIDATE: $pkg"
        done | head -20
  )
fi
echo "Hallucinated-imports pre-scan: ${PRE_SCAN_HALLUCINATED:-NONE}"

# Pre-scan 3: Prompt-injection seeds in comments and READMEs
PRE_SCAN_INJECTION=$(/bin/bash -c '
grep -rn --include="*.md" --include="*.txt" --include="*.ts" --include="*.js" --include="*.py" \
  -E "ignore previous instructions|you are now|disregard the above|system prompt|### [Ii]nstruction|\[SYSTEM\]" \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=god-review \
  "$1" 2>/dev/null | head -10
' _ "$WORKDIR")
echo "Prompt-injection pre-scan: ${PRE_SCAN_INJECTION:-NONE}"

PRE_SCAN_FLAG_COUNT=0
[ -n "$PRE_SCAN_SECRETS" ] && PRE_SCAN_FLAG_COUNT=$((PRE_SCAN_FLAG_COUNT+1))
[ -n "$PRE_SCAN_HALLUCINATED" ] && PRE_SCAN_FLAG_COUNT=$((PRE_SCAN_FLAG_COUNT+1))
[ -n "$PRE_SCAN_INJECTION" ] && PRE_SCAN_FLAG_COUNT=$((PRE_SCAN_FLAG_COUNT+1))
echo "Pre-scan complete. $PRE_SCAN_FLAG_COUNT flags raised."
```

### 1b: Snapshot (canonical block — atomic .tmp → mv)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
mkdir -p tmp/god-review

# Single canonical snapshot block — handles clean and dirty working trees.
# Creates a stash ref on dirty tree (non-destructive: stash create does NOT modify worktree).
# On clean tree, records current HEAD commit SHA as the revert point.
if [ -n "$(git status --porcelain)" ]; then
  REF=$(git stash create "god-review baseline $(date -u +%Y%m%dT%H%M%SZ)")
  REFTYPE="stash"
  # stash create on a dirty tree returns a stash object SHA — does NOT pop or apply
else
  REF=$(git rev-parse HEAD)
  REFTYPE="commit"
fi

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOOP_MODE=true   # Phase G: /god-review is always-on indefinite-loop by definition
MAX_WALL_HOURS_VAL=${MAX_WALL_HOURS:-24}

# Atomic write: write to .tmp then mv to prevent corruption on SIGKILL
cat > tmp/god-review/state.json.tmp << 'STATEOF'
{
  "snapshot": {"ref": "REFPLACEHOLDER", "reftype": "REFTYPEPLACEHOLDER"},
  "churn_ledger": {},
  "frozen_units": [],
  "false_positives": [],
  "round": 0,
  "consecutive_clean_rounds": 0,
  "architect_malformed_count": 0,
  "started_at_iso": "STARTEDPLACEHOLDER",
  "elapsed_hours": 0.0,
  "loop_mode": LOOPMODEPLACEHOLDER,
  "max_wall_hours": MAXWALLPLACEHOLDER,
  "finding_history_hashes": [],
  "kept_fixes": [],
  "reverted_fixes": [],
  "human_gate_emitted": [],
  "frozen_added_per_round": [],
  "architect_malformed_per_round": [],
  "auto_deferred": [],
  "round_finding_counts": []
}
STATEOF

# Substitute placeholders with actual values
sed -i.bak \
  -e "s|REFPLACEHOLDER|$REF|g" \
  -e "s|REFTYPEPLACEHOLDER|$REFTYPE|g" \
  -e "s|STARTEDPLACEHOLDER|$STARTED_AT|g" \
  -e "s|LOOPMODEPLACEHOLDER|$LOOP_MODE|g" \
  -e "s|MAXWALLPLACEHOLDER|$MAX_WALL_HOURS_VAL|g" \
  tmp/god-review/state.json.tmp
rm -f tmp/god-review/state.json.tmp.bak

mv tmp/god-review/state.json.tmp tmp/god-review/state.json

echo "Snapshot taken: REF=$REF REFTYPE=$REFTYPE"
echo "State written to tmp/god-review/state.json"
write_env
```

### 1c: Baseline perf capture (only if HAS_BENCH_SCRIPT)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# If HAS_BENCH_SCRIPT is non-empty, capture benchmark baseline for Phase 3 perf-regression detection.
# This runs ONCE at Phase 1; Phase 3 compares post-fix timings against this baseline.
if [ -n "$HAS_BENCH_SCRIPT" ]; then
  echo "Capturing perf baseline..."
  if [ -f package.json ]; then
    npm run bench 2>&1 > tmp/god-review/perf-baseline.json || \
    npm run benchmark 2>&1 > tmp/god-review/perf-baseline.json || \
    npm run perf 2>&1 > tmp/god-review/perf-baseline.json || true
  elif [ -f Cargo.toml ]; then
    cargo bench 2>&1 > tmp/god-review/perf-baseline.json || true
  elif grep -q "pytest-benchmark" requirements.txt pyproject.toml 2>/dev/null; then
    python3 -m pytest --benchmark-json=tmp/god-review/perf-baseline.json 2>&1 || true
  fi
  echo "Perf baseline captured at tmp/god-review/perf-baseline.json"
fi
```

Output: `Phase 1 complete. Snapshot: $REFTYPE=$REF. [N] pre-scan flags raised.`

---

## Phase 2: Review (the heart)

### 2a: Build active_principles list

Based on stack signals from Phase 0, determine which principles activate:

```
# Always-on (run regardless of stack):
ALWAYS_ON_PRINCIPLES = [
  "single-pattern",      # Tier 1, promoted
  "reuse",
  "clarity",
  "scope",
  "antipatterns",
  "documentation",
  "circular-deps",
  "dead-code-conservatism",
  "test-deletion",       # Tier 1, promoted
  "ci-yaml-tampering",   # Tier 1, promoted
  "hallucinated-imports",# Tier 1, promoted
  "secret-leak",         # Tier 1, promoted
  "prompt-injection",    # Tier 1, promoted
  "perf-heuristic",
  "dead-end-detector",
  "info-loss-detector",
  "contradiction-detector",
  "gap-detector",
]

# Stack-gated (included only if signal non-empty):
STACK_GATED_PRINCIPLES = {
  "architecture-backend":  HAS_BACKEND_LENS_TRIGGER,  # HAS_AUTHED_HANDLER OR HAS_BACKEND_PROJECT
  "architecture-frontend": HAS_APP_ROUTER,
  "self-contained":        HAS_UI_PROJECT,
  "tanstack-query":        HAS_TANSTACK_QUERY,
  "perf-benchmark":        HAS_BENCH_SCRIPT,
}

ACTIVE_PRINCIPLES = ALWAYS_ON_PRINCIPLES + [p for p,sig in STACK_GATED_PRINCIPLES if sig != ""]

# Note: stack-gated lenses still self-skip in Phase 1 of their own file if the signal is empty.
# The activation check here is the orchestrator-level gate.
```

### 2b: Check Codex availability

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null)}"
if [ -n "$CODEX_BIN" ]; then
  echo "Codex available at: $CODEX_BIN"
  CODEX_AVAILABLE=true
else
  echo "(Codex unavailable — running Claude-only. Install via: npm i -g @openai/codex)"
  CODEX_AVAILABLE=false
fi
write_env
```

### 2c: Spawn all review agents

**CRITICAL: All agents are launched in ONE or more assistant messages with mixed Agent + Bash tool calls. Up to ~20 tool calls per message. 3-4 round-trips worst case.**

The canonical schedule for full 19-principle × 2-family pipeline:
- **Message 1**: 10 Agent calls (3 broad-Claude + 7 principle-Claude) + 10 Bash calls (3 broad-Codex + 7 principle-Codex) = 20 in parallel
- **Message 2**: 10 Agent calls (next 10 principle-Claude) + 10 Bash calls (next 10 principle-Codex) = 20 in parallel
- **Message 3**: remaining 2 principle-Claude + remaining 2 principle-Codex = up to 4 in parallel
- **Message 4**: 2 batched validation calls (1 Claude + 1 Codex)

With Codex unavailable, drop all Codex Bash calls — Claude-only pipeline needs 2-3 round-trips.

Each finding is tagged at collection time with source:
- `claude-broad:<name>` for Layer A Claude broad reviewers
- `codex-broad:<name>` for Layer A Codex broad reviewers
- `claude-principle:<name>` for Layer B Claude principle agents
- `codex-principle:<name>` for Layer B Codex principle agents

**Layer A — 3 Claude broad reviewers** (always-on, full-codebase generalists):

For each of the three Claude broad reviewers, spawn an Agent tool call:
- `subagent_type: "general-purpose"`
- `model: "claude-opus-4-7"` with extended thinking enabled (high reasoning effort)
- Prompt loaded from `~/.claude-dotfiles/commands/god-review/broad-reviewers/<name>.md`
- Scope passed as `$SCOPE` (or full repo if empty)
- Context package path: `tmp/god-review/context-package.md`

Agents:
1. `~/.claude-dotfiles/commands/god-review/broad-reviewers/claude-deep-correctness.md` — bugs, logic errors, async/race, cross-layer integrity
2. `~/.claude-dotfiles/commands/god-review/broad-reviewers/claude-architecture-prod.md` — architecture, dead code, prod readiness, scalability
3. `~/.claude-dotfiles/commands/god-review/broad-reviewers/claude-security-resilience.md` — injection, auth, IDOR, data leaks, resilience

**After this batch returns, capture each agent's result text and persist it to
disk so Phase 2d can consolidate it.** For each broad-Claude reviewer, after
its Agent tool call returns, you (the orchestrator) MUST run a Bash block that
calls `write_agent_finding <agent_name> <result_text>`. The agent name uses
the format `claude-broad-<name>` (e.g. `claude-broad-deep-correctness`).
This writes to `$WORKDIR/tmp/god-review/findings/<agent_name>.txt`, which
Phase 2d reads via `cat findings/claude-*.txt > /tmp/claude-findings-consolidated.txt`.
Without this orchestrator-instruction step the consolidation reads an empty
directory (Phase E v2 catastrophic finding C4).

Apply the same `write_agent_finding` instruction after each Layer B
principle-Claude batch returns (use name format `claude-principle-<principle-name>`).

**Layer A — 4th Claude broad reviewer (conditional — `--ruthless` only):**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
if [ "$RUTHLESS" = "true" ]; then
  echo "RUTHLESS=true — orchestrator MUST spawn the 4th Claude broad reviewer below."
  cat "$HOME/.claude-dotfiles/commands/god-review/broad-reviewers/claude-ruthless-redteam.md" > /tmp/god-review-ruthless-prompt.txt
  echo "Ruthless prompt staged at /tmp/god-review-ruthless-prompt.txt"
fi
```

**Orchestrator instruction (executed in the same parallel batch as the 3 standard
broad-Claude reviewers when `RUTHLESS=true`):** spawn ONE additional Agent
tool call alongside the existing 3:
- `subagent_type: "general-purpose"`
- `model: "claude-opus-4-7"` (extended thinking, high reasoning effort)
- prompt: `$(cat /tmp/god-review-ruthless-prompt.txt)\n\nScope: $SCOPE\nContext package: $WORKDIR/tmp/god-review/context-package.md`

After this Agent returns, capture its result text and call:
```bash
write_agent_finding "claude-broad-ruthless" "$RUTHLESS_RESULT"
```
(where `$RUTHLESS_RESULT` is the captured text). All findings from this
reviewer get the source tag `claude-broad:ruthless` for downstream promotion
logic. Per Locked Decision #8, ruthless findings require Codex confirmation
for cross-model promotion.

**Layer A — 3 Codex broad reviewers** (only if $CODEX_AVAILABLE=true):

Invoke via Bash:
```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/codex-broad-cross-layer.txt \
  "$(cat ~/.claude-dotfiles/commands/god-review/broad-reviewers/codex-cross-layer.md)" \
  "$WORKDIR"

bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/codex-broad-prod-scalability.txt \
  "$(cat ~/.claude-dotfiles/commands/god-review/broad-reviewers/codex-prod-scalability.md)" \
  "$WORKDIR"

bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/codex-broad-security-safeguards.txt \
  "$(cat ~/.claude-dotfiles/commands/god-review/broad-reviewers/codex-security-safeguards.md)" \
  "$WORKDIR"

# Phase G: copy Codex outputs into findings/ for Phase 2d consolidation.
# (cat-glob at line ~660 reads findings/codex-*.txt + findings/claude-*.txt;
# without this step the Codex side is silently inert.)
mkdir -p "$WORKDIR/tmp/god-review/findings"
[ -f /tmp/codex-broad-cross-layer.txt ]        && cp /tmp/codex-broad-cross-layer.txt        "$WORKDIR/tmp/god-review/findings/codex-broad-cross-layer.txt"
[ -f /tmp/codex-broad-prod-scalability.txt ]   && cp /tmp/codex-broad-prod-scalability.txt   "$WORKDIR/tmp/god-review/findings/codex-broad-prod-scalability.txt"
[ -f /tmp/codex-broad-security-safeguards.txt ] && cp /tmp/codex-broad-security-safeguards.txt "$WORKDIR/tmp/god-review/findings/codex-broad-security-safeguards.txt"
```

**Layer B — Claude principle agents** (1 per active principle):

For each principle in ACTIVE_PRINCIPLES, spawn one Agent tool call:
- `subagent_type: "general-purpose"`
- `model: "claude-opus-4-7"` with extended thinking enabled
- Prompt loaded from `~/.claude-dotfiles/commands/god-review/principles/<principle-name>.md`
- Include path to context package: `tmp/god-review/context-package.md`
- Scope: `$SCOPE` if set, else full repo
- Pass `ONLINE=$ONLINE` to hallucinated-imports principle

**Principle file absolute paths (all 19):**
```
~/.claude-dotfiles/commands/god-review/principles/single-pattern.md
~/.claude-dotfiles/commands/god-review/principles/reuse.md
~/.claude-dotfiles/commands/god-review/principles/clarity.md
~/.claude-dotfiles/commands/god-review/principles/scope.md
~/.claude-dotfiles/commands/god-review/principles/antipatterns.md
~/.claude-dotfiles/commands/god-review/principles/documentation.md
~/.claude-dotfiles/commands/god-review/principles/circular-deps.md
~/.claude-dotfiles/commands/god-review/principles/dead-code-conservatism.md
~/.claude-dotfiles/commands/god-review/principles/test-deletion.md
~/.claude-dotfiles/commands/god-review/principles/ci-yaml-tampering.md
~/.claude-dotfiles/commands/god-review/principles/hallucinated-imports.md
~/.claude-dotfiles/commands/god-review/principles/secret-leak.md
~/.claude-dotfiles/commands/god-review/principles/prompt-injection.md
~/.claude-dotfiles/commands/god-review/principles/perf-heuristic.md
~/.claude-dotfiles/commands/god-review/principles/architecture-backend.md
~/.claude-dotfiles/commands/god-review/principles/architecture-frontend.md
~/.claude-dotfiles/commands/god-review/principles/self-contained.md
~/.claude-dotfiles/commands/god-review/principles/tanstack-query.md
~/.claude-dotfiles/commands/god-review/principles/perf-benchmark.md
~/.claude-dotfiles/commands/god-review/principles/dead-end-detector.md
~/.claude-dotfiles/commands/god-review/principles/info-loss-detector.md
~/.claude-dotfiles/commands/god-review/principles/contradiction-detector.md
~/.claude-dotfiles/commands/god-review/principles/gap-detector.md
```

**Layer B — Codex principle agents** (1 per active principle, only if $CODEX_AVAILABLE=true):

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# For each active principle, invoke Codex with the principle file content as the prompt:
bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/codex-principle-<NAME>.txt \
  "$(cat ~/.claude-dotfiles/commands/god-review/principles/<NAME>.md)\n\nScope: $SCOPE\nContext: see tmp/god-review/context-package.md" \
  "$WORKDIR"

# Phase G: copy each Codex principle output to findings/ for Phase 2d cat-consolidate.
# After ALL Codex principle calls return, run:
mkdir -p "$WORKDIR/tmp/god-review/findings"
for f in /tmp/codex-principle-*.txt; do
  [ -f "$f" ] || continue
  cp "$f" "$WORKDIR/tmp/god-review/findings/codex-principle-$(basename "$f" .txt | sed 's/^codex-principle-//').txt"
done
```

### 2d: Collect findings and run validation pass

After all agents complete, collect all findings. Tag each finding with its source.

**Step 2d validation — batched cross-family verification:**

Codex validation runs only on rounds where `round % CODEX_VALIDATION_EVERY == 0` (default every 3 rounds). On skipped rounds, tag all Claude-found findings as `(unverified-this-round)`.

**Claude-found findings → ONE Codex validation call** (only if $CODEX_AVAILABLE=true):
```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Build consolidated finding list from all Claude-sourced findings.
# Concatenate all per-agent claude-broad/claude-principle finding files into
# /tmp/claude-findings-consolidated.txt before the validation read below.
# This is the single canonical write site (Phase F).
mkdir -p "$WORKDIR/tmp/god-review/findings"
cat "$WORKDIR/tmp/god-review/findings/"claude-*.txt 2>/dev/null > /tmp/claude-findings-consolidated.txt || true
# Phase G: also consolidate Codex findings (used by the Claude-validates-Codex-findings pass below)
cat "$WORKDIR/tmp/god-review/findings/"codex-*.txt 2>/dev/null > /tmp/codex-findings-consolidated.txt || true
# Use --cd "$WORKDIR" (NOT -C) per codex-invoke.sh convention

CLAUDE_FINDINGS_PROMPT="You are validating a list of code-review findings produced by Claude Opus 4.7.
For each finding below, respond with: CONFIRMED / FALSE_POSITIVE / UNCERTAIN and a one-line reason.
Format: FINDING_ID: STATUS — reason

Findings to validate:
$(cat /tmp/claude-findings-consolidated.txt)

Codebase is at: $WORKDIR
Read the relevant files to verify each finding. Be skeptical — only CONFIRM if you can reproduce the issue in the code."

bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/codex-validation-output.txt \
  "$CLAUDE_FINDINGS_PROMPT" \
  "$WORKDIR"
```

If Codex unavailable: skip Codex validation pass; tag all Claude-found findings `(unverified)`. Do NOT spawn a second Claude validator on Claude-found findings — same-family validation is failure mode #6.

**Codex-found findings → ONE Claude validation Agent call:**

Spawn one Agent tool call with the consolidated Codex-found findings list. The agent reads the files and returns CONFIRMED / FALSE_POSITIVE / UNCERTAIN per finding.

**Apply verification post-processing:**
- `FALSE_POSITIVE` → drop from findings; track count in Meta-Review Notes; record entry in `state.json.false_positives` via `record_false_positive` helper (see below)
- `CONFIRMED` → eligible for confidence promotion (one level); tag `(verified)`
- `UNCERTAIN` → keep as-is; tag `(unverified)`

**Record FP entries in state.json (Phase F):** for each finding the validator returned
as `FALSE_POSITIVE`, call:

```bash
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# record_false_positive <finding_id> <file_path> <line_range> <category> <reason>
record_false_positive "$FINDING_ID" "$FILE_PATH" "$LINE_RANGE" "$CATEGORY" "$VALIDATOR_REASON"
```

This is the canonical FP write site. The `false_positives` array is read by future
rounds to suppress findings the validator already rejected (see Phase 3 triage).

### 2e: Aggregate findings (you, the orchestrator, ARE the aggregator)

**STEP 1 — Pre-promotion merge by hash:**

Hash each finding using: `sha256(file_path + line_range_normalized + category)`
- `line_range_normalized`: round start/end lines to nearest 5 (e.g., lines 42-47 → "40-50")
- Do NOT include `root_cause` in the hash — LLM prose varies per run
- Findings sharing the same hash → MERGE into one finding
- Merged finding's `source` field = union of all merged sources (e.g., `claude-broad:claude-deep-correctness + codex-principle:secret-leak`)
- Merging happens BEFORE any promotion logic

**STEP 2 — Single promotion pass (max 1 promotion per finding):**

Apply in order (stop after first promotion fires):
1. **Cross-model agreement** `(both)`: if merged source includes ANY Claude source + ANY Codex source → promote confidence by 1 level (`investigate→likely`, `likely→definite`). Tag `(both)`.
2. **Single-pattern / failure-class promotion**: if finding was reported by principle `single-pattern`, `secret-leak`, `prompt-injection`, `hallucinated-imports`, `test-deletion`, or `ci-yaml-tampering` → promote by 1 level. Tag `(tier1-promoted)`.
3. **CONFIRMED by validator**: if validator returned CONFIRMED → promote by 1 level. Tag `(verified)`.
Only ONE of these three fires per finding.

**STEP 3 — Category override routing:**

Regardless of confidence:
- Category `MISSING` → Gaps section
- Category `ASSUMPTION` → Assumptions section
- Category `CONTRADICTION` → Contradictions section

Otherwise use standard mapping (post-promotion confidence):
- `[definite]` → Critical
- `[likely]` → Important
- `[investigate]` → Minor

**STEP 4 — Write report:**

Write `tmp/god-review/report.md` atomically (`.tmp` → `mv`):

```
cat > tmp/god-review/report.md.tmp << 'REPORTEOF'
# god-review Report

**Generated**: <timestamp>
**Scope**: <SCOPE or "full repo">
**Rounds run**: <N>
**Stack**: <which HAS_* signals fired>
**Active principles**: <count> of 19

---

## Critical [must fix]
<[definite] non-special findings, sorted by severity>
Format per finding:
### [definite] CATEGORY: Short description
**Location**: `file.ts:line_start-line_end`
**Source**: `claude-principle:single-pattern + codex-broad:codex-security-safeguards` (both)
**Promotion**: cross-model agreement
**Evidence**:
```code snippet```
**Recommendation**: specific fix

---

## Gaps [missing entirely]
<MISSING category findings regardless of confidence>

---

## Important [should fix]
<[likely] non-special findings>

---

## Assumptions [verify these]
<ASSUMPTION category findings>

---

## Contradictions
<CONTRADICTION category findings>

---

## Minor [low priority]
<[investigate] non-special findings>

---

## Human Gate Required [never auto-applied]
<All HUMAN_GATE findings from Phase 3, with proposed diffs>
<Emitted ONCE per finding; subsequent rounds only update "still pending as of round N">

---

## Meta-Review Notes
- Total findings: N (Critical: X, Gaps: Y, Important: Z, Assumptions: A, Contradictions: B, Minor: C)
- False positives dropped: N
- Unverified findings (Codex unavailable or validation skipped): N
- Principles with zero findings: [list]
- Principles with most findings: [list]
REPORTEOF
mv tmp/god-review/report.md.tmp tmp/god-review/report.md
```

Output: `Phase 2 complete. [N] findings ([X] critical, [Y] important, [Z] minor). Report: tmp/god-review/report.md`

---

## Phase 3: Fix Loop (always-on; orchestrator-driven)

**Phase 3 is always-on for `/god-review`.** For report-only behavior, use
`/god-report` instead — it runs Phase 0–2 and exits without entering Phase 3.

This phase is **orchestrator-driven, not bash-driven** (per master-review.md
pattern at lines 1395-1430). Bash blocks below do mechanical work (state writes,
hash computation, snapshots). Agent tool calls do parallel review/fix work.
The loop control flow lives in **YOUR (the orchestrator's) reasoning** as
explicit prose — there is no outer `while [...]; do` bash construct wrapping
Agent invocations. Each round is a sequence of sub-steps you execute, then
you make the loop-back decision based on round results.

Read state from `tmp/god-review/state.json` at the start of every round.

### One-time round-state initialization (run ONCE, before round 1)

Before entering the round-loop, initialize state and export tunables. This
runs exactly once per `/god-review` invocation.

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"

# Export tunables that subprocess scripts (codex-invoke.sh) consume.
export SPINLOCK_TIMEOUT_SEC="${SPINLOCK_TIMEOUT_SEC:-600}"
export LATE_IMPORT_LINE="${LATE_IMPORT_LINE:-40}"

# Initialize loop counters (or restore from state.json on --resume)
if [ "$RESUME" = "true" ]; then
  ROUND=$(python3 -c "import json; print(json.load(open('$WORKDIR/tmp/god-review/state.json'))['round'])" 2>/dev/null || echo 1)
  CONSECUTIVE_CLEAN_ROUNDS=$(python3 -c "import json; print(json.load(open('$WORKDIR/tmp/god-review/state.json'))['consecutive_clean_rounds'])" 2>/dev/null || echo 0)
else
  ROUND=1
  CONSECUTIVE_CLEAN_ROUNDS=0
fi
FIXES_KEPT_THIS_ROUND=0
FROZEN_UNITS_COUNT=0
NET_NEW_FINDINGS_THIS_ROUND=0

# Initialize TOTAL_OPEN_FINDINGS from Phase 2 report (non-HUMAN_GATE findings)
TOTAL_OPEN_FINDINGS=$(python3 -c "
import json
try:
    report = open('$WORKDIR/tmp/god-review/report.md').read()
    in_human_gate = False
    count = 0
    for line in report.splitlines():
        if line.startswith('## Human Gate Required'):
            in_human_gate = True
        if not in_human_gate and line.startswith('### '):
            count += 1
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo 0)

write_env
echo "=== Phase 3 starting: TOTAL_OPEN_FINDINGS=$TOTAL_OPEN_FINDINGS, ROUND=$ROUND ==="
```

**Now enter the orchestrator-driven round loop.** What follows is a per-round
recipe. After each round completes, the round-end decision (sub-step 3g) tells
you (the orchestrator) whether to re-enter at 3a (next round), exit cleanly
(3 consecutive clean rounds), or exit with a backstop (wall-clock / instability /
`--max-rounds` ceiling). Execute these sub-steps in order each round.

---

### Round N — Sub-step 3a: Load and hash findings

Read the latest aggregated findings from `tmp/god-review/report.md`. Parse each
finding from the markdown sections (Critical, Important, Minor, Gaps,
Assumptions, Contradictions, Human Gate Required) into a list with these fields:
`{finding_id, file, line_start, line_end, category, severity, source,
root_cause, description, proposed_diff_sketch}`.

For each finding, compute a stable hash. Use the helpers in `lib/env-helpers.sh`:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# For each finding (you, the orchestrator, iterate over the parsed list and
# substitute concrete values from your parse — these vars are placeholders YOU
# fill in per-finding before each call):
#   FINDING_FILE="<finding's file from parse>"
#   FINDING_LINE_RANGE="<line_start>-<line_end>"
#   FINDING_CATEGORY="<finding's category>"
FINDING_LINE_NORMALIZED=$(python3 -c "
import sys
try:
  s,e = [int(x) for x in sys.argv[1].split('-')] if '-' in sys.argv[1] else (int(sys.argv[1]), int(sys.argv[1]))
  print(f'{(s//5)*5}-{((e+4)//5)*5}')
except Exception:
  print(sys.argv[1])
" "${FINDING_LINE_RANGE:-0-0}")
FINDING_HASH=$(compute_finding_hash "${FINDING_FILE:-unknown}" "$FINDING_LINE_NORMALIZED" "${FINDING_CATEGORY:-uncategorized}")
echo "Finding $FINDING_ID hash: $FINDING_HASH"
```

Build a per-finding dictionary keyed by `finding_id` with at least: `file`,
`line_range_normalized`, `category`, `hash`, plus the original parse fields.
Hold this in your reasoning context for sub-steps 3b–3g.

---

### Round N — Sub-step 3b: Triage findings into 4 buckets

For each finding from 3a, assign exactly ONE bucket based on these rules
(check in order; first match wins):

1. **`bucket_REPLAYED`** — `is_finding_replayed "$FINDING_HASH"` returns 0 (already
   tried-and-reverted in a prior round, hash in `finding_history_hashes`) OR
   `is_human_gate_already_emitted "$FINDING_HASH"` returns 0 (already in
   `human_gate_emitted` queue) OR `is_already_session_deferred "$FINDING_CATEGORY"`
   returns 0 (already in `tmp/god-review/known-deferred-session.txt`).
2. **`bucket_HUMAN_GATE`** — `is_hard_gate "$FINDING_FILE"` returns 0 (matches
   `lib/hard-gates.txt`), OR Architect output would be multi-file, OR
   category is `assumption` / `contradiction` requiring human judgment.
3. **`bucket_AUTO_DEFER`** — finding is `minor` severity AND not security-critical,
   OR validator marked it false_positive in Phase 2d, OR you (orchestrator)
   judge this requires deferral and have a substantive technical reason
   (≥30 chars, references a specific file path / identifier / quoted external
   name / issue ref — `record_auto_defer` will reject trivial reasons).
4. **`bucket_AUTO_FIX`** — everything else: severity ≥ likely, non-hard-gate,
   not deferrable, not replayed.

Print the bucket counts: `Round $ROUND triage: REPLAYED=X, HUMAN_GATE=Y, AUTO_DEFER=Z, AUTO_FIX=W`.

---

### Round N — Sub-step 3c: Process bucket_HUMAN_GATE

For each finding in `bucket_HUMAN_GATE`, run this bash block (substitute
per-finding values for the env vars at the top):

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Per-finding env vars YOU substitute before each call:
#   FINDING_ID, FINDING_HASH, FINDING_FILE, FINDING_LINE_RANGE, FINDING_CATEGORY,
#   FINDING_SEVERITY, FINDING_DESCRIPTION, FINDING_PROPOSED_DIFF (the sketch from 3a)
if is_human_gate_already_emitted "$FINDING_HASH"; then
  echo "(still pending: $FINDING_ID — already in human_gate_emitted queue)"
else
  # Append to HUMAN_GATE_QUEUE section in report.md (atomic .tmp + mv).
  # The append happens via python3 to avoid heredoc-quoting issues.
  FINDING_ID="$FINDING_ID" FINDING_FILE="$FINDING_FILE" \
  FINDING_LINE_RANGE="$FINDING_LINE_RANGE" FINDING_DESC="$FINDING_DESCRIPTION" \
  FINDING_DIFF="$FINDING_PROPOSED_DIFF" python3 -c '
import os
report = "tmp/god-review/report.md"
with open(report) as f: txt = f.read()
marker = "## HUMAN_GATE_QUEUE"
entry = f"\n### {os.environ[\"FINDING_ID\"]}\n- **File:** {os.environ[\"FINDING_FILE\"]}:{os.environ[\"FINDING_LINE_RANGE\"]}\n- **Reason:** {os.environ[\"FINDING_DESC\"]}\n- **Proposed diff:**\n```\n{os.environ[\"FINDING_DIFF\"]}\n```\n"
if marker in txt:
    # Insert at end of HUMAN_GATE_QUEUE section
    txt = txt.replace(marker, marker + entry, 1) if entry not in txt else txt
else:
    txt += f"\n\n{marker}\n\n_Hard-gate findings batched for human review at end of run._\n{entry}"
with open(report+".tmp","w") as f: f.write(txt)
os.rename(report+".tmp", report)
'
  record_human_gate_emit "$FINDING_ID" "$FINDING_HASH" "$ROUND"
  echo "HUMAN_GATE (new): $FINDING_ID queued"
fi
```

These findings are first-emit "new this round" and DO count toward
`NEW_NEW_FINDINGS` in 3g. They never block the loop; they queue for end-batch.

---

### Round N — Sub-step 3d: Process bucket_AUTO_DEFER

For each finding in `bucket_AUTO_DEFER`, you (the orchestrator) supply a
substantive technical reason (≥30 chars, with a structural anchor — see
`record_auto_defer`'s validation in `lib/env-helpers.sh`). Run:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Per-finding: FINDING_ID, FINDING_CATEGORY, DEFER_REASON (your supplied reason)
if record_auto_defer "$FINDING_ID" "$FINDING_CATEGORY" "$DEFER_REASON"; then
  echo "Deferred: $FINDING_ID"
else
  # Helper rejected (trivial reason, no structural anchor, or too short).
  # Demote to HUMAN_GATE: re-run sub-step 3c logic for this finding with
  # description annotated "(auto-defer rejected: <DEFER_REASON>)".
  echo "DEFER_REJECTED: $FINDING_ID — promoting to HUMAN_GATE"
fi
```

Accepted deferrals do NOT count toward `NEW_NEW_FINDINGS`. Rejected deferrals
fall through to HUMAN_GATE and then DO count (handled by 3c logic when you
re-run for the demoted finding).

---

### Round N — Sub-step 3e: Process bucket_AUTO_FIX (sequential per-finding)

For each finding in `bucket_AUTO_FIX`, execute the per-finding pipeline below.
**Process findings one at a time, sequentially** — no parallel auto-fix. Each
finding's pipeline is its own bash fence. After each finding completes, move
to the next.

**Per-finding pipeline (you, the orchestrator, iterate this for each
AUTO_FIX finding):**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Per-finding env vars YOU substitute:
#   FINDING_ID, FINDING_HASH, FINDING_FILE, FINDING_LINE_RANGE,
#   FINDING_CATEGORY, FINDING_DESCRIPTION, FINDING_ROOT_CAUSE

# (i) Pre-fix snapshot
if [ -n "$(git status --porcelain)" ]; then
  PRE_FIX_REF=$(git stash create "god-review pre-fix $(date -u +%Y%m%dT%H%M%SZ)")
  PRE_FIX_REFTYPE="stash"
else
  PRE_FIX_REF=$(git rev-parse HEAD)
  PRE_FIX_REFTYPE="commit"
fi
echo "Pre-fix snapshot: $PRE_FIX_REFTYPE $PRE_FIX_REF"
```

**(ii) Spawn ONE Architect Agent tool call.** You (the orchestrator) issue
this Agent call with `subagent_type: "general-purpose"`, `model: "claude-opus-4-7"`,
extended thinking enabled.

**Important — disk-based output capture:** The Architect MUST write its JSON
output to a file path you provide (NOT return it as inline text). This avoids
the apostrophe-corruption bug from inline-paste patterns (Phase G2 fix).

Compute the output path before spawning:
```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
ARCH_OUTPUT_FILE="$WORKDIR/tmp/god-review/architect-output-${FINDING_ID}.json"
mkdir -p "$WORKDIR/tmp/god-review"
rm -f "$ARCH_OUTPUT_FILE"
write_env
```

Then spawn the Agent with prompt:
```
You are the Architect in a god-review fix loop. Describe ONE precise fix for
this finding:

- Finding ID: $FINDING_ID
- File: $FINDING_FILE
- Lines: $FINDING_LINE_RANGE
- Category: $FINDING_CATEGORY
- Description: $FINDING_DESCRIPTION
- Root cause: $FINDING_ROOT_CAUSE

IMPACT AUDIT (required — include in rationale): list every caller / consumer /
test / config-reference of the changed code. What could break?

Write your output as valid JSON to this exact path:
$ARCH_OUTPUT_FILE

JSON shape:
{
  "file": "<relative path>",
  "line_start": <int>,
  "line_end": <int>,
  "before": "<exact current content at those lines, verbatim>",
  "after": "<replacement content>",
  "rationale": "<one sentence + impact summary>"
}

If the fix requires touching multiple files OR is a hard-gate path, write
{"error": "requires HUMAN_GATE", "reason": "<why>"} to that path instead.

Confirm the write completed before returning. Do NOT include the JSON in
your response text — only the path-write counts.
```

The Agent's response text is ignored; the orchestrator reads the file the
Architect wrote. This is robust against any character in `before`/`after`/
`rationale` (apostrophes, newlines, backslashes — all fine inside a JSON file).

**(iii) Validate the file the Architect wrote:**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
ARCH_OUTPUT_FILE="$WORKDIR/tmp/god-review/architect-output-${FINDING_ID}.json"

if [ ! -f "$ARCH_OUTPUT_FILE" ]; then
  echo "Architect did not write $ARCH_OUTPUT_FILE — demoting $FINDING_ID to HUMAN_GATE"
  record_architect_malformed
  # Continue to next AUTO_FIX finding.
  exit 0
fi

# Check for "requires HUMAN_GATE" error response
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'error' in d else 1)" "$ARCH_OUTPUT_FILE" 2>/dev/null; then
  echo "Architect declined: HUMAN_GATE — re-run sub-step 3c for $FINDING_ID"
  # Re-process this finding via 3c bucket_HUMAN_GATE logic; record_finding_hash
  # is NOT called (this is a structural decline, not a tried-and-reverted fix).
  exit 0
fi

# Validate required fields (read from disk, no env-var passthrough — ARCH_OUTPUT_FILE is canonical)
VALID=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    required = ['file', 'line_start', 'line_end', 'before', 'after', 'rationale']
    for field in required:
        if field not in d or d[field] == '' or d[field] is None:
            print(f\"INVALID: field '{field}' missing or empty\"); sys.exit(1)
    if not isinstance(d['line_start'], int) or not isinstance(d['line_end'], int):
        print('INVALID: line_start and line_end must be integers'); sys.exit(1)
    print('VALID')
except json.JSONDecodeError as e:
    print(f'INVALID: malformed JSON — {e}'); sys.exit(1)
" "$ARCH_OUTPUT_FILE")
if [ "$VALID" != "VALID" ]; then
  echo "Architect output malformed: $VALID"
  record_architect_malformed
  echo "Demoting $FINDING_ID to HUMAN_GATE (Architect output malformed)"
  exit 0
fi

# Extract ARCH_FILE + RATIONALE from disk (used for injection guard + commit message)
ARCH_FILE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('file',''))" "$ARCH_OUTPUT_FILE" 2>/dev/null)
RATIONALE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('rationale','fix'))" "$ARCH_OUTPUT_FILE" 2>/dev/null)
write_env

# Injection guard via python3 (NOT bash $'\n'/$'\r' — those are literal
# backslash-n on macOS bash 3.2.57; per Phase G plan).
INJECTION_OK=$(ARCH_FILE="$ARCH_FILE" WORKDIR="$WORKDIR" python3 -c '
import os, sys
f = os.environ.get("ARCH_FILE","")
forbidden = ["\n","\r","\\","$","`","(",")","<",">",";","|","&"]
if not f or any(c in f for c in forbidden):
    print("REJECT"); sys.exit(0)
abs_path = os.path.realpath(os.path.join(os.environ["WORKDIR"], f))
if not abs_path.startswith(os.path.realpath(os.environ["WORKDIR"]) + os.sep):
    print("ESCAPE"); sys.exit(0)
print("OK")
')
case "$INJECTION_OK" in
  OK) ;;
  *) echo "Injection guard rejected ($INJECTION_OK): $ARCH_FILE — demoting $FINDING_ID to HUMAN_GATE"; exit 0 ;;
esac

# Defense-in-depth hard-gate check
if is_hard_gate "$ARCH_FILE"; then
  echo "HUMAN_GATE: $ARCH_FILE matches hard-gate pattern (defense-in-depth) — re-run 3c for $FINDING_ID"
  exit 0
fi

echo "Architect output validated for $FINDING_ID. Spawning Editor."
```

**(iv) Spawn ONE Editor Agent tool call.** Use `subagent_type: "general-purpose"`,
`model: "claude-opus-4-7"`, low reasoning effort. Prompt is the contents of
`lib/editor-agent.md` followed by:

```
The Architect's instructions are in this JSON file. Read it via the Read tool
and apply the change exactly:

$ARCH_OUTPUT_FILE
```

(The orchestrator substitutes `$ARCH_OUTPUT_FILE` literally — it's the disk
path from sub-step 3e(iii).) The Editor returns one line:
`APPLIED: <file>:<line_start>-<line_end>` or `EDITOR_ABORT: <reason>`.

If the Editor returns `EDITOR_ABORT`:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Targeted revert
if [ "$PRE_FIX_REFTYPE" = "stash" ]; then
  git stash apply "$PRE_FIX_REF" 2>/dev/null || true
else
  git checkout -- "$ARCH_FILE" 2>/dev/null || true
fi
# Record reverted_fixes + replay-guard hash (REVERT path → record_finding_hash)
FINDING_ID="$FINDING_ID" REVERT_REASON="EDITOR_ABORT" WORKDIR="$WORKDIR" python3 -c '
import json, os
sj = os.environ["WORKDIR"] + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
d.setdefault("reverted_fixes", []).append({"finding_id": os.environ["FINDING_ID"], "reason": os.environ["REVERT_REASON"]})
tmp = sj + ".tmp"
with open(tmp,"w") as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
'
record_finding_hash "$FINDING_HASH"
echo "Reverted $FINDING_ID (EDITOR_ABORT). Hash recorded for replay-skip."
# Continue to next AUTO_FIX finding.
```

**(v) If Editor returned APPLIED, run baseline gates:**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
GATES_PASS=true; GATE_FAIL_REASON=""
if [ -f package.json ]; then
  npm run typecheck > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="typecheck"; }
  npm run lint > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}lint"; }
  npm run build > /tmp/gate-output.txt 2>&1 || true   # build optional
  npm run test -- --passWithNoTests > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}test"; }
elif [ -f Cargo.toml ]; then
  cargo check > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="cargo-check"; }
  cargo test > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}cargo-test"; }
elif [ -f go.mod ]; then
  go vet ./... > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="go-vet"; }
  go test ./... > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}go-test"; }
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  python3 -m mypy . > /tmp/gate-output.txt 2>&1 || true   # mypy non-fatal
  python3 -m pytest > /tmp/gate-output.txt 2>&1 || { GATES_PASS=false; GATE_FAIL_REASON="pytest"; }
fi
echo "Gates: $GATES_PASS${GATE_FAIL_REASON:+ (failed: $GATE_FAIL_REASON)}"

# Regression detectors
REGRESSION=false; REGRESSION_REASON=""
# (a) Test-deletion / shrinkage
if echo "$ARCH_FILE" | grep -qE '\.(test|spec)\.(ts|tsx|js|jsx|py|go|rb)$|_test\.(go|py)$|^test_.*\.py$'; then
  REGRESSION=true; REGRESSION_REASON="edit touched a test file (should be HUMAN_GATE)"
fi
TEST_DELETED=$(git diff --diff-filter=D --name-only 2>/dev/null | grep -E '\.(test|spec)\.(ts|tsx|js|jsx|py|go|rb)$' | head -3)
if [ -n "$TEST_DELETED" ]; then
  REGRESSION=true; REGRESSION_REASON="test deleted: $TEST_DELETED"
fi
# (b) CI YAML modification
CI_MODIFIED=$(git diff --name-only 2>/dev/null | grep -E '\.github/workflows/.*\.yml|\.gitlab-ci\.yml|Jenkinsfile|\.husky/' | head -3)
[ -n "$CI_MODIFIED" ] && { REGRESSION=true; REGRESSION_REASON="CI modified: $CI_MODIFIED"; }
# (c) Churn freeze (file edited 2+ times this session)
EDITED_FILE="$ARCH_FILE" python3 << 'PYEOF'
import json, os
sj = os.environ.get("WORKDIR",".") + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
edited = os.environ.get("EDITED_FILE","")
churn = d.setdefault("churn_ledger", {})
churn[edited] = churn.get(edited, 0) + 1
if churn[edited] >= 2 and edited not in d.get("frozen_units", []):
    d.setdefault("frozen_units", []).append(edited)
    open("/tmp/god-review-freeze-signal","w").write(f"FREEZE:{edited}")
tmp = sj + ".tmp"
open(tmp,"w").write(json.dumps(d, indent=2))
os.rename(tmp, sj)
PYEOF
if [ -f /tmp/god-review-freeze-signal ]; then
  REGRESSION=true; REGRESSION_REASON="churn freeze: $(cat /tmp/god-review-freeze-signal)"
  rm -f /tmp/god-review-freeze-signal
  record_frozen
fi

if [ "$GATES_PASS" = "false" ] || [ "$REGRESSION" = "true" ]; then
  # REVERT path
  git checkout -- "$ARCH_FILE" 2>/dev/null || true
  REVERT_REASON="${REGRESSION_REASON:-gate failure: $GATE_FAIL_REASON}"
  FINDING_ID="$FINDING_ID" REVERT_REASON="$REVERT_REASON" WORKDIR="$WORKDIR" python3 -c '
import json, os
sj = os.environ["WORKDIR"] + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
d.setdefault("reverted_fixes", []).append({"finding_id": os.environ["FINDING_ID"], "reason": os.environ["REVERT_REASON"]})
tmp = sj + ".tmp"
with open(tmp,"w") as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
'
  record_finding_hash "$FINDING_HASH"   # REVERT path → record for replay-skip
  echo "Reverted $FINDING_ID — $REVERT_REASON. Hash recorded."
  # Continue to next AUTO_FIX finding.
fi
```

**(vi) If gates passed AND no regression, optionally run perf benchmark
(only if HAS_BENCH_SCRIPT non-empty):**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
PERF_REGRESSED="NONE"
if [ -n "$HAS_BENCH_SCRIPT" ] && [ -f "tmp/god-review/perf-baseline.json" ]; then
  if [ -f package.json ]; then
    npm run bench > tmp/god-review/perf-current.json 2>&1 || \
    npm run benchmark > tmp/god-review/perf-current.json 2>&1 || true
  elif [ -f Cargo.toml ]; then
    cargo bench > tmp/god-review/perf-current.json 2>&1 || true
  fi
  PERF_REGRESSED=$(PERF_REGRESS_PCT="$PERF_REGRESS_PCT" python3 -c "
import json, re, os
b = open('tmp/god-review/perf-baseline.json').read()
c = open('tmp/god-review/perf-current.json').read()
t = float(os.environ.get('PERF_REGRESS_PCT', '0.05'))
def ext(s): return {m.group(1): float(m.group(2)) for m in re.finditer(r'(\w[\w\-]+).*?(\d+\.?\d*)\s*ms', s)}
bt, ct = ext(b), ext(c)
regs = [f'{n}: +{(ct[n]-bt[n])/bt[n]:.1%}' for n in bt if n in ct and bt[n]>0 and (ct[n]-bt[n])/bt[n] > t]
print('\n'.join(regs) if regs else 'NONE')
" 2>/dev/null || echo "NONE")
fi
if [ "$PERF_REGRESSED" != "NONE" ]; then
  git checkout -- "$ARCH_FILE" 2>/dev/null || true
  REVERT_REASON="perf regression: $PERF_REGRESSED"
  FINDING_ID="$FINDING_ID" REVERT_REASON="$REVERT_REASON" WORKDIR="$WORKDIR" python3 -c '
import json, os
sj = os.environ["WORKDIR"] + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
d.setdefault("reverted_fixes", []).append({"finding_id": os.environ["FINDING_ID"], "reason": os.environ["REVERT_REASON"]})
tmp = sj + ".tmp"
with open(tmp,"w") as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
'
  record_finding_hash "$FINDING_HASH"   # REVERT path
  echo "Reverted $FINDING_ID — $REVERT_REASON. Hash recorded."
  # Continue to next AUTO_FIX finding.
fi
```

**(vii) If gates and perf both pass, COMMIT (NEVER --no-verify):**

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
git add -A
if git commit -m "god-review: $FINDING_ID — ${RATIONALE:-fix}"; then
  echo "Kept: $FINDING_ID committed as $(git rev-parse HEAD)"
  # KEEP path: record kept_fixes ONLY. Do NOT call record_finding_hash on keep —
  # successful fixes must be re-attemptable on later regression (Phase G design).
  FINDING_ID="$FINDING_ID" WORKDIR="$WORKDIR" python3 -c '
import json, os
sj = os.environ["WORKDIR"] + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
d.setdefault("kept_fixes", []).append(os.environ["FINDING_ID"])
tmp = sj + ".tmp"
with open(tmp,"w") as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
'
  FIXES_KEPT_THIS_ROUND=$((FIXES_KEPT_THIS_ROUND+1))
  write_env
else
  # Pre-commit hook rejected the fix
  REVERT_REASON="pre-commit hook rejected: $(git status --porcelain | head -3 | tr '\n' ';')"
  git checkout -- "$ARCH_FILE" 2>/dev/null || true
  FINDING_ID="$FINDING_ID" REVERT_REASON="$REVERT_REASON" WORKDIR="$WORKDIR" python3 -c '
import json, os
sj = os.environ["WORKDIR"] + "/tmp/god-review/state.json"
with open(sj) as f: d = json.load(f)
d.setdefault("reverted_fixes", []).append({"finding_id": os.environ["FINDING_ID"], "reason": os.environ["REVERT_REASON"]})
tmp = sj + ".tmp"
with open(tmp,"w") as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
'
  record_finding_hash "$FINDING_HASH"   # REVERT path (pre-commit reject)
  echo "Reverted $FINDING_ID — pre-commit hook rejected. Hash recorded."
fi
```

After all `bucket_AUTO_FIX` findings are processed (or after the loop iteration
hits the next finding), advance to sub-step 3f.

---

### Round N — Sub-step 3f: Verifier sub-pass

After all per-finding pipelines in 3e complete, spawn 4 verifier agents in
parallel (subset of Phase 2's full suite — for speed). Use ONE message with
4 Agent tool calls:

- **Verifier 1**: `claude-opus-4-7`, `subagent_type: general-purpose`, prompt
  = "Re-review this diff and surrounding code. List any NEW issues. Do NOT
  re-flag findings already in `state.json.human_gate_emitted` or in
  `tmp/god-review/known-deferred-session.txt`. Diff:
  `$(git diff $PRE_FIX_BASE_REF..HEAD)`. Prior findings list: ..."
- **Verifier 2**: same shape but model `claude-opus-4-7` with different focus
  prompt (correctness vs. architecture).
- **Verifier 3**: Codex via `bash $WORKDIR/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh`
  (only if `$CODEX_AVAILABLE=true`).
- **Verifier 4**: another Codex agent, different prompt focus.

After the parallel batch returns, capture each verifier's result text.

**Apply Phase F's per-agent finding write step:** for each verifier, call
`write_agent_finding "verifier-<n>" "$verifier_result"` (orchestrator
substitutes the captured text).

Parse all verifier outputs into a unified findings list. Compute hash for each
new finding using `compute_finding_hash`. Filter:

```
VERIFIER_NEW = [f for f in verifier_findings
                  if not is_human_gate_already_emitted(hash(f))
                  and not is_already_session_deferred(category(f))
                  and not is_finding_replayed(hash(f))]
```

This filter is critical — without it, hard-gate items repeatedly inflate the
new-finding count and the loop never terminates (Phase G plan B3/B7 fix).

---

### Round N — Sub-step 3g: Termination decision (orchestrator-prose)

Compute the round's NEW-finding count:

```
NEW_NEW_FINDINGS = |VERIFIER_NEW|                     (from 3f, post-filter)
                 + (count of first-emit HUMAN_GATE items from 3c this round)
                 - (any auto-defers from 3d that were rejected and demoted to
                    HUMAN_GATE — already counted in the 3c first-emit count)
```

Run mechanical bash to record the round count and check backstops:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# YOU substitute these from the orchestrator's tally:
NEW_NEW_FINDINGS=${NEW_NEW_FINDINGS:-0}
DEFERRED_THIS_ROUND=${DEFERRED_THIS_ROUND:-0}
GATED_THIS_ROUND=${GATED_THIS_ROUND:-0}

# Update state.json with this round's counts
record_round_counts "$NEW_NEW_FINDINGS" "$TOTAL_OPEN_FINDINGS" "$DEFERRED_THIS_ROUND" "$GATED_THIS_ROUND"

# Termination backstops (mechanical):
ELAPSED_HOURS=$(python3 -c "
from datetime import datetime, timezone
import json
d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
start = datetime.fromisoformat(d['started_at_iso'].replace('Z','+00:00'))
print(round((datetime.now(timezone.utc)-start).total_seconds()/3600, 2))
" 2>/dev/null || echo 0)

# Wall-clock cap (0 = disabled)
if [ "${MAX_WALL_HOURS:-24}" != "0" ] && python3 -c "import sys; sys.exit(0 if float('${ELAPSED_HOURS:-0}') >= float('${MAX_WALL_HOURS:-24}') else 1)" 2>/dev/null; then
  echo "Wall-clock cap reached ($ELAPSED_HOURS h >= $MAX_WALL_HOURS h)" >&2
  exit 5
fi

# Instability detector (avg per-round events over last 3 rounds > INSTABILITY_RATE)
AVG_INSTABILITY=$(python3 -c "
import json
try:
    d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
    fa = d.get('frozen_added_per_round', [])
    am = d.get('architect_malformed_per_round', [])
    combined = [f+m for f,m in zip(fa[-3:], am[-3:])]
    print(sum(combined)/len(combined) if combined else 0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)
if python3 -c "import sys; sys.exit(0 if float('${AVG_INSTABILITY:-0}') > ${INSTABILITY_RATE:-5} else 1)" 2>/dev/null; then
  echo "Instability rate too high (avg $AVG_INSTABILITY events/round over last 3 rounds)" >&2
  exit 4
fi

# --max-rounds explicit ceiling (only honored if user passed it)
if [ "$MAX_ROUNDS_EXPLICIT" = "true" ] && [ "$ROUND" -ge "${MAX_ROUNDS:-9999}" ]; then
  echo "--max-rounds ceiling reached ($MAX_ROUNDS rounds)" >&2
  exit 2
fi

# Persist round + clean-counter to state.json
python3 -c "
import json
sj = '$WORKDIR/tmp/god-review/state.json'
with open(sj) as f: d = json.load(f)
d['round'] = $ROUND
d['consecutive_clean_rounds'] = $CONSECUTIVE_CLEAN_ROUNDS
d['elapsed_hours'] = float('${ELAPSED_HOURS:-0}')
import os
tmp = sj + '.tmp'
with open(tmp,'w') as f: json.dump(d, f, indent=2)
os.rename(tmp, sj)
"
write_env
```

**Now you (the orchestrator) make the loop-back decision based on
`NEW_NEW_FINDINGS`:**

- **If `NEW_NEW_FINDINGS > 0`:**
  - Set `CONSECUTIVE_CLEAN_ROUNDS=0`.
  - Increment `ROUND`.
  - **Decide whether to re-run full Phase 2 OR re-enter Phase 3 directly:**
    - If `VERIFIER_NEW` (3f) found bugs in DIFFERENT areas than this round's
      fixes touched, re-enter at Phase 2 with re-scoped agents — they'll
      re-discover what changed.
    - If `NEW_NEW_FINDINGS` came entirely from `bucket_HUMAN_GATE` first-emits
      (no actionable new bugs, just new hard-gate items queued), skip the
      full Phase 2 re-run — re-enter Phase 3 sub-step 3a directly. This avoids
      respawning 52 agents per round when nothing actionable changed.
  - Update SCOPE for the next round: if `RESCOPE_ON_FIX=changed` and
    `FIXES_KEPT_THIS_ROUND > 0`, set `SCOPE` to the changed-files list.

- **If `NEW_NEW_FINDINGS == 0`:**
  - Increment `CONSECUTIVE_CLEAN_ROUNDS`.
  - **If `CONSECUTIVE_CLEAN_ROUNDS >= 3`:** exit the loop, proceed to sub-step
    3h (Phase 4 final report). Output: "Naturally clean × 3 — converged after
    $ROUND rounds."
  - **Else:** increment `ROUND`. The HUMAN_GATE_QUEUE may still be non-empty —
    that's intentional, those are punted-to-human-by-design. Re-enter Phase 3
    sub-step 3a directly (skip full Phase 2 re-run since nothing changed).

---

### Round N — Sub-step 3h: Phase 4 Final Report (runs ONCE after loop exit)

After the loop terminates (via 3 consecutive clean rounds or backstop), write
the final combined report:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
ELAPSED_HOURS=$(python3 -c "
from datetime import datetime, timezone
import json
d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
start = datetime.fromisoformat(d['started_at_iso'].replace('Z','+00:00'))
print(round((datetime.now(timezone.utc)-start).total_seconds()/3600, 2))
" 2>/dev/null || echo 0)

python3 << PYEOF
import json
from datetime import datetime, timezone

sj = "$WORKDIR/tmp/god-review/state.json"
with open(sj) as f:
    d = json.load(f)

elapsed = float("${ELAPSED_HOURS:-0}")
kept = len(d.get("kept_fixes", []))
reverted = len(d.get("reverted_fixes", []))
deferred = len(d.get("auto_deferred", []))
gated = len(d.get("human_gate_emitted", []))
rounds = d.get("round", 0)

out = []
out.append("# /god-review Final Report\n")
out.append(f"**Rounds run:** {rounds}")
out.append(f"**Wall time:** {elapsed} h")
out.append(f"**Kept fixes:** {kept}")
out.append(f"**Reverted fixes:** {reverted}")
out.append(f"**Auto-deferred:** {deferred} (see tmp/god-review/known-deferred-session.txt)")
out.append(f"**HUMAN_GATE_QUEUE:** {gated} (see HUMAN_GATE_QUEUE section in report.md)")
out.append("")
out.append("## Kept Fixes")
for fid in d.get("kept_fixes", []):
    out.append(f"- {fid}")
out.append("")
out.append("## Reverted Fixes")
for entry in d.get("reverted_fixes", []):
    out.append(f"- {entry.get('finding_id')}: {entry.get('reason')}")
out.append("")
out.append("## Auto-Deferred (with reasons)")
for entry in d.get("auto_deferred", []):
    out.append(f"- {entry.get('finding_id')} ({entry.get('category')}, round {entry.get('round')}): {entry.get('reason')}")
out.append("")
out.append("## HUMAN_GATE_QUEUE (apply manually after review)")
out.append("See the HUMAN_GATE_QUEUE section appended to tmp/god-review/report.md for proposed diffs.")
out.append("")
out.append("## Round-by-round counts")
for rc in d.get("round_finding_counts", []):
    out.append(f"- Round {rc['round']}: new={rc['new']}, total={rc['total']}, deferred={rc['deferred_this_round']}, gated={rc['gated_this_round']}")

final = "\n".join(out) + "\n"
with open("$WORKDIR/tmp/god-review/final-summary.md", "w") as f:
    f.write(final)
print(final)
PYEOF

# Promote session deferrals to committed lib/known-deferred.txt only at end of run.
SESSION_KD="$WORKDIR/tmp/god-review/known-deferred-session.txt"
COMMITTED_KD="$HOME/.claude-dotfiles/commands/god-review/lib/known-deferred.txt"
if [ -f "$SESSION_KD" ] && [ -s "$SESSION_KD" ]; then
  echo "Promoting $(wc -l < "$SESSION_KD") session deferrals to $COMMITTED_KD"
  cat "$SESSION_KD" >> "$COMMITTED_KD"
  echo "(committed file updated; auto-sync hook will commit + push)"
fi

echo "Phase 3 + Phase 4 complete. Final summary at $WORKDIR/tmp/god-review/final-summary.md"
```

---
---

## Final Summary Output

After Phase 3 sub-step 3h writes the final summary file, print this to stdout:

```
god-review complete.

Rounds run: <N>
Wall time: <H> h
Kept fixes: <N> (committed as individual god-review commits)
Reverted fixes: <N>
Auto-deferred: <N> (substantive reasons recorded in tmp/god-review/known-deferred-session.txt
  and promoted to lib/known-deferred.txt at end of run)
HUMAN_GATE_QUEUE: <N> (proposed diffs in report.md — apply manually)
Frozen units: <N> files

Final summary: tmp/god-review/final-summary.md
Full report: tmp/god-review/report.md (HUMAN_GATE_QUEUE section has diffs)

If you want to squash all god-review commits into one:
  git reset --soft HEAD~<N> && git commit -m 'god-review: apply fixes'

To resume from this state after interruption:
  /god-review --resume
```

---

## Reference: Canonical Revert Table

| Situation | Command | Why |
|---|---|---|
| Fix was committed (gate or perf regression failed after commit) | `git reset --hard HEAD~1` | Undoes only the most-recent god-review commit |
| Fix applied but NOT yet committed (gate failed mid-fix) | `git checkout -- "<file-from-architect>"` | Targeted: discards only the Architect's target file working-tree changes |
| Final bailout (whole pipeline abort) | If `$REFTYPE = "stash"`: `git stash apply $REF`; if `$REFTYPE = "commit"`: `git reset --hard $REF` | Bisect on stored ref-type from state.json |

Never use repo-wide `git checkout .` or `git restore .` — always use targeted per-file reverts except for the final-bailout scenario.

---

## Reference: Hard Gates (NEVER auto-applied — always batched to HUMAN_GATE_QUEUE)

The canonical hard-gate path-glob list lives in
[`lib/hard-gates.txt`](god-review/lib/hard-gates.txt). The orchestrator's
`is_hard_gate <path>` (in `lib/env-helpers.sh`) reads it at runtime — that
function is the **single runtime authority**. Categories covered:

- Schema migration files
- Auth/authentication code files
- Dependency manifests (`package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`, etc.)
- Environment / secret files (`.env*`, `*secrets*`, `*credentials*`)
- CI/CD YAML (`.github/workflows/**`, `.gitlab-ci.yml`, `Jenkinsfile*`, etc.)
- Test files (`*.test.*`, `*.spec.*`, `tests/**`, `__tests__/**`, etc.)
- Build/runtime config (`next.config.*`, `Dockerfile`, etc.)
- Dead-code quarantine moves (any `_deprecated/` path operation)

Plus orchestrator-only additions enforced in code (not in `hard-gates.txt`):
- Multi-file changes (any Architect output targeting more than 1 file)

**DO NOT** inline the pattern list here or anywhere else — it drifts. Edit
`lib/hard-gates.txt` and run `bash lib/env-helpers.sh --test-globs` to verify.

---

## Reference: CRITERIA.md

All confidence taxonomy, section mapping, category enum, risk levels, PASS/WARN/FAIL definitions, and the promotion priority order are defined in:

`~/.claude-dotfiles/commands/god-review/CRITERIA.md`

This is the single source of truth. Do not redefine severity here.
