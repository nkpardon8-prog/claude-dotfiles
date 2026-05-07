---
description: "From-scratch multi-model codebase audit. 3 Claude broad + 3 Codex broad + 19 principle agents (Claude+Codex per principle) in parallel. Report-only by default; --fix enables snapshot/revert/regression-detected fix loop; --loop runs until naturally clean. Hard gates on schema/auth/deps/secrets/CI/tests."
argument-hint: "[scope] [--fix] [--max-rounds N] [--loop] [--max-wall-hours N] [--resume] [--force-resume] [--principle <name>] [--rescope-on-fix {full|changed}] [--online] [--codex-validation-every N] [--ruthless]"
allowed-tools: "Read, Glob, Grep, Bash, Agent"
---

# /god-review — Multi-Model Codebase Audit

You are a senior engineering lead conducting a ground-up, multi-model codebase audit. You orchestrate parallel agents across two model families (Claude Opus 4.7 + Codex CLI), apply 19 principle lenses plus 6 broad reviewers, snapshot the repo before any mutation, and enforce hard gates on irreversible changes.

This command has 4 phases:
- **Phase 0**: Context Map — stack fingerprint, architecture, hot zones, baseline gates
- **Phase 1**: Probe — snapshot + failure-mode pre-scans
- **Phase 2**: Review — parallel agents × model families × principles + validation + aggregation
- **Phase 3**: Fix (opt-in via `--fix`) — triage, Architect/Editor split, snapshot/revert loop

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
  HAS_BENCH_SCRIPT=$(python3 -c "import json; d=json.load(open('$WORKDIR/package.json')); scripts=d.get('scripts',{}); print(next((k for k in scripts if k in ('bench','benchmark','perf')),'')" 2>/dev/null)
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
LOOP_MODE=${LOOP:-false}
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
  echo "Spawning ruthless redteam reviewer (--ruthless flag set)..."
  RUTHLESS_PROMPT="$(cat $HOME/.claude-dotfiles/commands/god-review/broad-reviewers/claude-ruthless-redteam.md)"
  # Spawn 4th Claude broad reviewer alongside the existing 3.
  # Agent tool call: subagent_type "general-purpose", model "claude-opus-4-7", extended thinking enabled.
  # Prompt: $RUTHLESS_PROMPT + scope + context-package path.
  # Tag all findings with source: claude-broad:ruthless for downstream promotion logic.
  # Invocation pattern (same as the 3 standard broad-Claude reviewers above):
  #   subagent_type: "general-purpose"
  #   model: "claude-opus-4-7" (extended thinking, high reasoning effort)
  #   prompt: $RUTHLESS_PROMPT + "\n\nScope: $SCOPE\nContext package: $WORKDIR/tmp/god-review/context-package.md"
  #   Collect output, tag each finding line with: source=claude-broad:ruthless
  # Note: findings from this reviewer require Codex confirmation for cross-model promotion (Locked Decision #8).
fi
```

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
```

### 2d: Collect findings and run validation pass

After all agents complete, collect all findings. Tag each finding with its source.

**Step 2d validation — batched cross-family verification:**

In `--loop` mode, Codex validation runs only on rounds where `round % CODEX_VALIDATION_EVERY == 0`. On skipped rounds, tag all Claude-found findings as `(unverified-this-round)`.

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

### Per-round loop structure

Initialize round state and enter the real shell loop:

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"

# Phase F: export tunables that codex-invoke.sh consumes (must be exported, not just set,
# since codex-invoke.sh runs as a subprocess via `bash`).
export SPINLOCK_TIMEOUT_SEC="${SPINLOCK_TIMEOUT_SEC:-600}"
export LATE_IMPORT_LINE="${LATE_IMPORT_LINE:-40}"

# Initialize loop counters
ROUND=1
FIXES_KEPT_THIS_ROUND=0
CONSECUTIVE_CLEAN_ROUNDS=0
FROZEN_UNITS_COUNT=0
NET_NEW_FINDINGS_THIS_ROUND=0

# Initialize TOTAL_OPEN_FINDINGS from Phase 2 report (count non-HUMAN_GATE findings)
TOTAL_OPEN_FINDINGS=$(python3 -c "
import json, re
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

echo "=== Phase 3 Fix Loop starting: TOTAL_OPEN_FINDINGS=$TOTAL_OPEN_FINDINGS MAX_ROUNDS=$MAX_ROUNDS LOOP=$LOOP ==="

while [ "$LOOP" = "true" ] || [ "$ROUND" -le "${MAX_ROUNDS:-5}" ]; do
  echo "=== Round $ROUND ==="
  FIXES_KEPT_THIS_ROUND=0
  NET_NEW_FINDINGS_THIS_ROUND=0

# For each round (1 through MAX_ROUNDS in bounded mode, or indefinite if --loop):

# Step 3a: Triage findings into two buckets



# Step 3b: HUMAN_GATE diff emission

# For each new HUMAN_GATE finding (first time seen this session):

FINDING_HASH="<sha256 of this finding>"
# Check if already emitted
if ! python3 -c "import json; d=json.load(open('tmp/god-review/state.json')); print('yes' if '$FINDING_HASH' in [f.get('hash') for f in d.get('human_gate_emitted',[])] else 'no')" | grep -q yes; then
  # Append to Human Gate section of report.md
  # Include: finding description, proposed diff, reason it requires human review
  echo "HUMAN_GATE (new): $FINDING_ID emitted to report"
else
  # Update "still pending as of round N" marker in report.md
  echo "HUMAN_GATE (still pending): $FINDING_ID"
fi

# Step 3c: Per-AUTO_FIX processing (sequential — one at a time)

# For each AUTO_FIX finding:

# Phase F replay guard: skip findings that have already been tried and reverted in
# prior rounds. Hash inputs match the post-keep/revert recording at the bottom of
# this block (compute_finding_hash + is_finding_replayed live in lib/env-helpers.sh).
FINDING_LINE_NORMALIZED=$(python3 -c "
import sys
try:
  s,e = [int(x) for x in sys.argv[1].split('-')] if '-' in sys.argv[1] else (int(sys.argv[1]), int(sys.argv[1]))
  print(f'{(s//5)*5}-{((e+4)//5)*5}')
except Exception:
  print(sys.argv[1])
" "${FINDING_LINE_RANGE:-0-0}" 2>/dev/null)
FINDING_HASH=$(compute_finding_hash "${FINDING_FILE:-unknown}" "$FINDING_LINE_NORMALIZED" "${FINDING_CATEGORY:-uncategorized}")
if is_finding_replayed "$FINDING_HASH"; then
  echo "Skipping $FINDING_ID — same hash already in finding_history_hashes (already tried + reverted)"
  continue
fi

# Canonical snapshot block (mirrors Phase 1b) — handles clean and dirty working trees.
# After the previous fix was committed, working tree is typically clean (REF = HEAD commit).
# If worktree is unexpectedly dirty, stash-create to capture it non-destructively.
if [ -n "$(git status --porcelain)" ]; then
  PRE_FIX_REF=$(git stash create "god-review pre-fix $(date -u +%Y%m%dT%H%M%SZ)")
  PRE_FIX_REFTYPE="stash"
else
  PRE_FIX_REF=$(git rev-parse HEAD)
  PRE_FIX_REFTYPE="commit"
fi
echo "Pre-fix snapshot: $PRE_FIX_REFTYPE $PRE_FIX_REF"


# Spawn one Agent tool call:

# ```
# You are the Architect in a godreview fix loop. Describe ONE precise fix for the finding below.

# Finding: <description>
# File: <file>
# Lines: <line_start>-<line_end>

# IMPACT AUDIT (required — include in rationale):

# Output ONLY valid JSON (no markdown wrapping, no explanation outside the JSON):
# {
# "file": "relative/path/to/file.ext",
# "line_start": <integer>,
# "line_end": <integer>,
# "before": "exact current content at those lines",
# "after": "replacement content",
# "rationale": "one sentence describing the fix plus impact assessment"
# }

# Constraints:
# ```


# Orchestrator validates Architect output BEFORE spawning Editor
ARCH_OUTPUT="<architect agent output>"

# Check for error response
if echo "$ARCH_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
  echo "Architect reported cannot-fix: skip finding, mark HUMAN_GATE"
  continue
fi

# Validate all required fields present and non-empty (env-var pattern per Locked Decision #17)
VALID=$(ARCH_OUTPUT="$ARCH_OUTPUT" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['ARCH_OUTPUT'])
    required = ['file', 'line_start', 'line_end', 'before', 'after', 'rationale']
    for field in required:
        if field not in d or d[field] == '' or d[field] is None:
            print(f\"INVALID: field '{field}' missing or empty\"); sys.exit(1)
    if not isinstance(d['line_start'], int) or not isinstance(d['line_end'], int):
        print('INVALID: line_start and line_end must be integers'); sys.exit(1)
    print('VALID')
except json.JSONDecodeError as e:
    print(f'INVALID: malformed JSON — {e}'); sys.exit(1)
")

if [ "$VALID" != "VALID" ]; then
  echo "Architect output malformed: $VALID"
  # Increment architect_malformed_count in state.json (atomic)
  python3 -c "
import json
with open('tmp/god-review/state.json') as f: d=json.load(f)
d['architect_malformed_count'] = d.get('architect_malformed_count', 0) + 1
import tempfile, os
tmp = 'tmp/god-review/state.json.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp, 'tmp/god-review/state.json')
"
  # Mark finding as HUMAN_GATE with reason "Architect output malformed"
  continue
fi

# Extract and validate ARCH_FILE (injection guard — site 1: pre-Editor spawn)
ARCH_FILE=$(ARCH_OUTPUT="$ARCH_OUTPUT" python3 -c "import json,os; print(json.loads(os.environ['ARCH_OUTPUT']).get('file',''))" 2>/dev/null)
case "$ARCH_FILE" in
  *[\;\&\|\`\$\(\)\<\>\\]* | *$'\n'* | *$'\r'* | '')
    echo "FINDING_REJECTED: filename invalid: $ARCH_FILE"
    continue ;;
esac
ABS=$(python3 -c "import os.path,sys; print(os.path.realpath(sys.argv[1]))" "$WORKDIR/$ARCH_FILE" 2>/dev/null)
case "$ABS" in
  "$WORKDIR"/*) ;;
  *) echo "PATH_ESCAPE: $ARCH_FILE resolves outside WORKDIR"; continue ;;
esac

# Hard-gate check (A9) — BEFORE Editor spawn; is_hard_gate sourced from env-helpers.sh
if is_hard_gate "$ARCH_FILE"; then
  echo "HUMAN_GATE: $ARCH_FILE matches hard-gate pattern — skipping Editor spawn"
  continue
fi


# If `$CODEX_AVAILABLE=true`: spawn Codex as editor via bash:
bash ~/.claude-dotfiles/commands/god-review/lib/codex-invoke.sh \
  /tmp/editor-output.txt \
  "$(cat ~/.claude-dotfiles/commands/god-review/lib/editor-agent.md)\n\nApply this change:\n$ARCH_OUTPUT" \
  "$WORKDIR"

# If Codex unavailable: spawn a second Claude Agent tool call (different instance, same model):

# 5. Re-run gates:

GATES_PASS=true
GATE_FAIL_REASON=""
if [ -f package.json ]; then
  echo "=== typecheck ==="
  if ! npm run typecheck > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="typecheck"
  fi
  tail -20 /tmp/gate-output.txt
  echo "=== lint ==="
  if ! npm run lint > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}lint"
  fi
  tail -20 /tmp/gate-output.txt
  # Build is optional — some projects don't have a build script
  npm run build > /tmp/gate-output.txt 2>&1 || true
  tail -10 /tmp/gate-output.txt
  # Tests — run if script exists
  echo "=== tests ==="
  if ! npm run test -- --passWithNoTests > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}test"
  fi
  tail -20 /tmp/gate-output.txt
elif [ -f Cargo.toml ]; then
  echo "=== cargo check ==="
  if ! cargo check > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="cargo-check"
  fi
  tail -20 /tmp/gate-output.txt
  echo "=== cargo test ==="
  if ! cargo test > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}cargo-test"
  fi
  tail -20 /tmp/gate-output.txt
elif [ -f go.mod ]; then
  echo "=== go vet ==="
  if ! go vet ./... > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="go-vet"
  fi
  tail -20 /tmp/gate-output.txt
  echo "=== go test ==="
  if ! go test ./... > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="${GATE_FAIL_REASON:+$GATE_FAIL_REASON,}go-test"
  fi
  tail -20 /tmp/gate-output.txt
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  echo "=== mypy ==="
  python3 -m mypy . > /tmp/gate-output.txt 2>&1 || true  # mypy non-fatal
  tail -20 /tmp/gate-output.txt
  echo "=== pytest ==="
  if ! python3 -m pytest > /tmp/gate-output.txt 2>&1; then
    GATES_PASS=false
    GATE_FAIL_REASON="pytest"
  fi
  tail -20 /tmp/gate-output.txt
fi
echo "Gates: $GATES_PASS${GATE_FAIL_REASON:+ (failed: $GATE_FAIL_REASON)}"

# 6. Regression detectors (run BEFORE deciding keep/revert):

REGRESSION_DETECTED=false
REGRESSION_REASON=""

# Detector 1: Test deletion
# Check if any test files were deleted or significantly shrunk
EDITED_FILE="$ARCH_FILE"  # from Architect output
if echo "$EDITED_FILE" | grep -qE "\.(test|spec)\.(ts|tsx|js|jsx|py|go|rb)$|_test\.(go|py)$|^test_.*\.py$"; then
  # The edit touched a test file — this is a HUMAN_GATE violation
  REGRESSION_DETECTED=true
  REGRESSION_REASON="test file modification — should be HUMAN_GATE"
fi
# Check for test file deletion via git diff
TEST_DELETED=$(git diff --diff-filter=D --name-only 2>/dev/null | grep -E "\.(test|spec)\.(ts|tsx|js|jsx|py|go|rb)$|_test\.(go|py)$|^test_.*\.py$" | head -3)
if [ -n "$TEST_DELETED" ]; then
  REGRESSION_DETECTED=true
  REGRESSION_REASON="test file deleted: $TEST_DELETED"
fi
# Check for test file significant shrinkage (>SHRINKAGE_PCT lines removed, floor files >= TEST_FILE_LINE_FLOOR lines)
if git diff --numstat 2>/dev/null | awk -v shrink="$SHRINKAGE_PCT" -v floor="$TEST_FILE_LINE_FLOOR" '{if ($2+$1 > 0 && $2/($2+$1) > shrink && ($2+$1) >= floor) print $3}' | grep -qE "\.(test|spec)\.(ts|tsx|js|jsx|py|go)$"; then
  REGRESSION_DETECTED=true
  REGRESSION_REASON="test file significantly shrunk (>${SHRINKAGE_PCT} line reduction)"
fi

# Detector 2: CI YAML tampering
CI_MODIFIED=$(git diff --name-only 2>/dev/null | grep -E "\.github/workflows/.*\.yml$|\.gitlab-ci\.yml$|\.circleci/config\.yml$|azure-pipelines.*\.yml$|bitbucket-pipelines\.yml$|Jenkinsfile|\.pre-commit-config\.yaml$|\.husky/" | head -3)
if [ -n "$CI_MODIFIED" ]; then
  REGRESSION_DETECTED=true
  REGRESSION_REASON="CI YAML modification: $CI_MODIFIED"
fi

# Detector 3: Churn check — freeze files edited 2+ times this session
python3 << 'PYEOF'
import json, os, sys

with open('tmp/god-review/state.json') as f:
    d = json.load(f)

edited_file = os.environ.get('EDITED_FILE', '')
churn = d.get('churn_ledger', {})
churn[edited_file] = churn.get(edited_file, 0) + 1
d['churn_ledger'] = churn

if churn[edited_file] >= 2:
    if edited_file not in d.get('frozen_units', []):
        d.setdefault('frozen_units', []).append(edited_file)
        print(f"FREEZE: {edited_file} (edited {churn[edited_file]} times this session)")
        # Signal freeze to shell
        with open('/tmp/god-review-freeze-signal', 'w') as sf:
            sf.write(f"FREEZE:{edited_file}")

tmp = 'tmp/god-review/state.json.tmp'
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.rename(tmp, 'tmp/god-review/state.json')
PYEOF

if [ -f /tmp/god-review-freeze-signal ]; then
  REGRESSION_DETECTED=true
  REGRESSION_REASON="churn freeze: $(cat /tmp/god-review-freeze-signal)"
  rm -f /tmp/god-review-freeze-signal
fi

echo "Regression check: REGRESSION_DETECTED=$REGRESSION_DETECTED REASON=$REGRESSION_REASON"

# 7. Keep or revert (canonical revert table):

if [ "$GATES_PASS" = "true" ] && [ "$REGRESSION_DETECTED" = "false" ]; then
  # KEEP: commit the fix (no --no-verify per Locked Decision #6 — pre-commit hook must run)
  if git commit -m "god-review: $FINDING_ID"; then
    COMMITTED=true
    echo "Kept: $FINDING_ID committed as $(git rev-parse HEAD)"
  else
    COMMITTED=false
    REVERT_REASON="pre-commit hook rejected: $(git status --porcelain | head -3)"
    git checkout -- "$ARCH_FILE"
    FINDING_ID="$FINDING_ID" REVERT_REASON="$REVERT_REASON" WORKDIR="$WORKDIR" python3 -c "
import json, os
sj = os.environ['WORKDIR'] + '/tmp/god-review/state.json'
with open(sj) as f: d=json.load(f)
d.setdefault('reverted_fixes',[]).append({'finding_id': os.environ['FINDING_ID'], 'reason': os.environ['REVERT_REASON']})
tmp = sj + '.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp, sj)
"
    echo "Pre-commit hook rejected fix $FINDING_ID — reverted and recorded in reverted_fixes"
  fi

  # Perf-benchmark check (only if HAS_BENCH_SCRIPT)
  if [ -n "$HAS_BENCH_SCRIPT" ] && [ -f "tmp/god-review/perf-baseline.json" ]; then
    echo "Running perf comparison..."
    if [ -f package.json ]; then
      npm run bench 2>&1 > tmp/god-review/perf-current.json || \
      npm run benchmark 2>&1 > tmp/god-review/perf-current.json || true
    elif [ -f Cargo.toml ]; then
      cargo bench 2>&1 > tmp/god-review/perf-current.json || true
    fi
    # Compare timings (simplified: look for regressions > PERF_REGRESS_PCT)
    PERF_REGRESSED=$(PERF_REGRESS_PCT="$PERF_REGRESS_PCT" python3 -c "
import json, re, sys, os
baseline = open('tmp/god-review/perf-baseline.json').read()
current = open('tmp/god-review/perf-current.json').read()
perf_threshold = float(os.environ.get('PERF_REGRESS_PCT', '0.05'))
# Extract timing values (ms) from output — heuristic extraction
def extract_timings(text):
    return {m.group(1): float(m.group(2)) for m in re.finditer(r'(\w[\w\-]+).*?(\d+\.?\d*)\s*ms', text)}
b = extract_timings(baseline)
c = extract_timings(current)
regressions = []
for name in b:
    if name in c and b[name] > 0:
        delta = (c[name] - b[name]) / b[name]
        if delta > perf_threshold:
            regressions.append(f'{name}: +{delta:.1%} ({b[name]:.1f}ms -> {c[name]:.1f}ms)')
print('\n'.join(regressions) if regressions else 'NONE')
" 2>/dev/null || echo "NONE")

    if [ "$PERF_REGRESSED" != "NONE" ]; then
      echo "PERF REGRESSION detected: $PERF_REGRESSED — reverting"
      git reset --hard HEAD~1
      COMMITTED=false
      REVERT_REASON="perf regression: $PERF_REGRESSED"
      # Update audit trail (reverted_fixes in state.json)
      python3 -c "
import json, os
with open('tmp/god-review/state.json') as f: d=json.load(f)
d.setdefault('reverted_fixes',[]).append({'finding_id':'$FINDING_ID','reason':'$REVERT_REASON'})
tmp='tmp/god-review/state.json.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp,'tmp/god-review/state.json')
"
    else
      echo "Perf OK — no regression detected"
      # Update kept_fixes
      python3 -c "
import json, os
with open('tmp/god-review/state.json') as f: d=json.load(f)
d.setdefault('kept_fixes',[]).append('$FINDING_ID')
tmp='tmp/god-review/state.json.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp,'tmp/god-review/state.json')
"
      FIXES_KEPT_THIS_ROUND=$((FIXES_KEPT_THIS_ROUND+1))
    fi
  else
    # No perf benchmark — just update kept_fixes
    python3 -c "
import json, os
with open('tmp/god-review/state.json') as f: d=json.load(f)
d.setdefault('kept_fixes',[]).append('$FINDING_ID')
tmp='tmp/god-review/state.json.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp,'tmp/god-review/state.json')
"
    FIXES_KEPT_THIS_ROUND=$((FIXES_KEPT_THIS_ROUND+1))
  fi

else
  # REVERT: use canonical revert table
  if [ "$COMMITTED" = "true" ]; then
    # Fix was committed but regression detected after commit (perf-benchmark path above handles this)
    git reset --hard HEAD~1
    echo "Reverted committed fix: $FINDING_ID"
  else
    # Fix not yet committed — targeted revert of only the Architect's target file
    ARCH_FILE=$(echo "$ARCH_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('file',''))" 2>/dev/null)
    # Injection guard — site 2: revert path
    case "$ARCH_FILE" in
      *[\;\&\|\`\$\(\)\<\>\\]* | *$'\n'* | *$'\r'* | '')
        echo "FINDING_REJECTED: filename invalid for revert: $ARCH_FILE"; ;;
      *)
        ABS=$(python3 -c "import os.path,sys; print(os.path.realpath(sys.argv[1]))" "$WORKDIR/$ARCH_FILE" 2>/dev/null)
        case "$ABS" in
          "$WORKDIR"/*) git checkout -- "$ARCH_FILE" ;;
          *) echo "PATH_ESCAPE on revert: $ARCH_FILE resolves outside WORKDIR" ;;
        esac ;;
    esac
    echo "Targeted revert of: $ARCH_FILE (fix was not committed)"
  fi

  # Record in reverted_fixes
  REVERT_REASON="${REGRESSION_REASON:-gate failure}"
  python3 -c "
import json, os
with open('tmp/god-review/state.json') as f: d=json.load(f)
d.setdefault('reverted_fixes',[]).append({'finding_id':'$FINDING_ID','reason':'$REVERT_REASON'})
tmp='tmp/god-review/state.json.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp,'tmp/god-review/state.json')
"
  echo "Reverted: $FINDING_ID — reason: $REVERT_REASON"
fi

# Phase F: record finding hash for replay detection.
# Future rounds use is_finding_replayed to skip findings already tried-and-reverted.
# Hash inputs: file_path | line_range_normalized (rounded to nearest 5) | category.
FINDING_LINE_NORMALIZED=$(python3 -c "
import sys
try:
  s,e = [int(x) for x in sys.argv[1].split('-')] if '-' in sys.argv[1] else (int(sys.argv[1]), int(sys.argv[1]))
  print(f'{(s//5)*5}-{((e+4)//5)*5}')
except Exception:
  print(sys.argv[1])
" "${FINDING_LINE_RANGE:-0-0}" 2>/dev/null)
FINDING_HASH=$(compute_finding_hash "${FINDING_FILE:-unknown}" "$FINDING_LINE_NORMALIZED" "${FINDING_CATEGORY:-uncategorized}")
record_finding_hash "$FINDING_HASH"
echo "Recorded finding hash: $FINDING_HASH"

write_env

# Step 3d: Write round audit trail

cat > tmp/god-review/round-${ROUND}-findings.md.tmp << 'ROUNDEOF'
# god-review Round <N> Audit Trail

**Timestamp**: <ISO>
**Findings processed**: <total>
**AUTO_FIX attempted**: <N>
**HUMAN_GATE emitted**: <N>
**Fixes kept**: <N>
**Fixes reverted**: <N>

## Per-Finding Detail

### <FINDING_ID>
- **Source**: <claude-principle:X + codex-broad:Y>
- **Triage**: AUTO_FIX / HUMAN_GATE
- **Architect output**: <JSON or "N/A — HUMAN_GATE">
- **Editor applied**: YES / NO / ABORT (with reason)
- **Gates**: PASS / FAIL (with output)
- **Regression check**: PASS / FAIL (with reason)
- **Decision**: KEPT (commit <sha>) / REVERTED (<reason>) / HUMAN_GATE_EMITTED
ROUNDEOF
mv tmp/god-review/round-${ROUND}-findings.md.tmp tmp/god-review/round-${ROUND}-findings.md

# Step 3e: Termination check (real shell — executed at end of every round)


# Re-read frozen units count from state.json (updated by churn detector above)
FROZEN_UNITS_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
    print(len(d.get('frozen_units', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

if [ "$LOOP" = "true" ]; then
  # --- Indefinite mode termination checks ---

  # B12: Hard ceiling — if user explicitly passed --max-rounds, it caps --loop too
  if [ "$MAX_ROUNDS_EXPLICIT" = "true" ] && [ "$ROUND" -ge "${MAX_ROUNDS:-9999}" ] 2>/dev/null; then
    echo "Max rounds ceiling reached in --loop mode (--max-rounds $MAX_ROUNDS explicitly set)" >&2
    exit 2
  fi

  # Convergence: 3 consecutive clean rounds
  if [ "$NET_NEW_FINDINGS_THIS_ROUND" -eq 0 ] && [ "$FIXES_KEPT_THIS_ROUND" -eq 0 ]; then
    CONSECUTIVE_CLEAN_ROUNDS=$((CONSECUTIVE_CLEAN_ROUNDS + 1))
  else
    CONSECUTIVE_CLEAN_ROUNDS=0
  fi
  if [ "$CONSECUTIVE_CLEAN_ROUNDS" -ge 3 ]; then
    echo "Naturally clean x 3 — converged after $ROUND rounds"
    break
  fi

  # Rate-based instability abort (per-round rate, NOT cumulative)
  AVG_INSTABILITY=$(python3 -c "
import json
try:
    d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
    frozen_added = d.get('frozen_added_per_round', [])
    malformed = d.get('architect_malformed_per_round', [])
    combined = [f+m for f,m in zip(frozen_added[-3:], malformed[-3:])]
    print(sum(combined)/len(combined) if combined else 0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if python3 -c "import sys; sys.exit(0 if float('${AVG_INSTABILITY:-0}') > $INSTABILITY_RATE else 1)" 2>/dev/null; then
    echo "Instability rate too high (avg $AVG_INSTABILITY events/round over last 3 rounds)" >&2
    exit 4
  fi

  # Wall-clock backstop
  ELAPSED_HOURS=$(python3 -c "
from datetime import datetime, timezone
import json
d = json.load(open('$WORKDIR/tmp/god-review/state.json'))
start = datetime.fromisoformat(d['started_at_iso'].replace('Z','+00:00'))
now = datetime.now(timezone.utc)
print(round((now-start).total_seconds()/3600, 2))
" 2>/dev/null || echo 0)
  if python3 -c "import sys; sys.exit(0 if float('${ELAPSED_HOURS:-0}') >= float('${MAX_WALL_HOURS:-24}') else 1)" 2>/dev/null; then
    echo "Wall-clock cap reached ($ELAPSED_HOURS h >= $MAX_WALL_HOURS h)" >&2
    exit 5
  fi

else
  # --- Bounded mode termination checks ---

  if [ "$TOTAL_OPEN_FINDINGS" -lt 2 ]; then
    echo "Near-clean — fewer than 2 open findings remain"
    break
  fi
  if [ "$FROZEN_UNITS_COUNT" -gt "$FROZEN_UNITS_CAP" ]; then
    echo "Too many frozen units ($FROZEN_UNITS_COUNT > $FROZEN_UNITS_CAP) — escalate to human" >&2
    exit 3
  fi
  if [ "$FIXES_KEPT_THIS_ROUND" -eq 0 ]; then
    echo "No progress this round — fix loop cannot make further progress"
    break
  fi
  if [ "$ROUND" -ge "${MAX_ROUNDS:-5}" ]; then
    echo "Max rounds reached (cap: $MAX_ROUNDS)" >&2
    exit 2
  fi
fi

# Re-scope for next round
if [ "$FIXES_KEPT_THIS_ROUND" -eq 0 ]; then
  NEXT_SCAN_SCOPE="$SCOPE"
else
  if [ "$RESCOPE_ON_FIX" = "full" ]; then
    NEXT_SCAN_SCOPE="$SCOPE"
  else
    NEXT_SCAN_SCOPE="$(git diff HEAD~"$FIXES_KEPT_THIS_ROUND" --name-only 2>/dev/null | tr '\n' ' ')"
  fi
fi

# Atomic state.json update
ELAPSED_HOURS=${ELAPSED_HOURS:-0}
python3 -c "
import json, os
sj = '$WORKDIR/tmp/god-review/state.json'
with open(sj) as f: d=json.load(f)
d['round'] = $ROUND
d['consecutive_clean_rounds'] = $CONSECUTIVE_CLEAN_ROUNDS
d['elapsed_hours'] = float('${ELAPSED_HOURS:-0}')
tmp = sj + '.tmp'
with open(tmp,'w') as f: json.dump(d,f,indent=2)
os.rename(tmp, sj)
" 2>/dev/null

SCOPE="$NEXT_SCAN_SCOPE"
ROUND=$((ROUND + 1))
write_env  # persist round counter and updated scope via env-helpers.sh

done  # end of while loop (opened in Per-round loop structure block above)
echo "Phase 3 fix loop complete after $((ROUND - 1)) rounds."
```

**In `--loop` mode**, Codex validation runs only every `CODEX_VALIDATION_EVERY` rounds:

At the start of Phase 2 in each loop iteration, check:
```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
# Skip Codex validation on non-milestone rounds to reduce wall-clock cost
if [ "$LOOP" = "true" ] && [ $(( ROUND % CODEX_VALIDATION_EVERY )) -ne 0 ]; then
  SKIP_CODEX_VALIDATION=true
  echo "Skipping Codex validation this round ($ROUND % $CODEX_VALIDATION_EVERY != 0) — findings tagged (unverified-this-round)"
else
  SKIP_CODEX_VALIDATION=false
fi
```

---

## Final Summary Output

After all phases complete (Phase 2 exit or Phase 3 termination):

```
god-review complete.

Rounds run: <N>
Total findings: <N> (Critical: X, Gaps: Y, Important: Z, Assumptions: A, Contradictions: B, Minor: C)
Kept fixes: <N> (committed as individual god-review commits)
Reverted fixes: <N>
Frozen units: <N> files (require human attention)
Human-gate items: <N> (proposed diffs in report — apply manually)

Report: tmp/god-review/report.md
Round trails: tmp/god-review/round-N-findings.md

If you want to squash all god-review commits into one:
  git reset --soft HEAD~<N> && git commit -m 'god-review: apply fixes'

To resume from this state after interruption:
  /god-review --fix [--loop] --resume
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

## Reference: Hard Gates (NEVER auto-applied even with --fix)

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
