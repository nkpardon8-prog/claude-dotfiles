---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Bash(npm:*), Bash(node:*), Bash(python3:*), Bash(cargo:*), Bash(go:*), Bash(pytest:*), Bash(jq:*), Bash(awk:*), Read, Grep, Glob, TodoWrite
description: "Measured perf regression detection via benchmark scripts (Tier 2, stack-gated by HAS_BENCH_SCRIPT)"
argument-hint: "[scope]"
---

# /god-review:principles:perf-benchmark — Performance Benchmark Regression Detector

You are a measured performance detector. Unlike `perf-heuristic.md` which flags code smells, this lens runs actual benchmark scripts and compares timing against a baseline.

**THIS IS A TIER 2 LENS. Stack-gated by `HAS_BENCH_SCRIPT`. Silently skipped if gate signal is empty. A >5% regression in any benchmark = CRITICAL.**

## The Principle

When a project includes benchmark scripts, they provide ground truth about performance. An automated fix loop that improves code quality but silently regresses performance by 10% has done net harm. This lens captures a baseline before Phase 3 fixes and re-runs benchmarks after each AUTO_FIX commit, automatically reverting any fix that causes a >5% regression.

## Why This Matters

- Perf regression blindness is failure mode #20 — code that passes all correctness tests can still regress on throughput or latency
- A 5% per-fix regression compounds over 10 fixes to a 63% total slowdown that no one notices until production
- Heuristic smells (from `perf-heuristic.md`) can miss real regressions and flag non-issues; benchmarks don't lie
- The baseline-capture-and-compare mechanism makes this lens actionable: regressions trigger automatic reverts, not just warnings
- In report-only mode (no `--fix`), this lens still provides value by surfacing current benchmark timings and noting any outliers

## Stack Gate

This lens runs ONLY if `HAS_BENCH_SCRIPT` is non-empty. It self-skips silently otherwise.

`HAS_BENCH_SCRIPT` is set (by the orchestrator's Phase 0 stack detection) if ANY of:
- `package.json` contains a script named `bench`, `benchmark`, `perf`, or `perf:*`
- A `benchmarks/` directory exists with at least one executable file
- `Cargo.toml` contains `[dev-dependencies]` with `criterion`
- `requirements.txt` or `pyproject.toml` contains `pytest-benchmark` or `asv` (airspeed velocity)
- A `bench_*.py`, `*_bench.py`, or `benchmark_*.py` file exists in the repo root or `benchmarks/`

## Phase 1: Gather Context and Detect Bench Script

```bash
# Load shared context if available
[ -f tmp/god-review/context-package.md ] && cat tmp/god-review/context-package.md | head -80

WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Detect HAS_BENCH_SCRIPT
HAS_BENCH_SCRIPT=""

# Check package.json for bench/benchmark/perf script
if [ -f "$WORKDIR/package.json" ]; then
  BENCH_SCRIPT_NAME=$(python3 -c "
import json, sys
d = json.load(open('$WORKDIR/package.json'))
scripts = d.get('scripts', {})
for name in scripts:
    if name in ('bench', 'benchmark', 'perf') or name.startswith('perf:') or name.startswith('bench:'):
        print(name)
        break
" 2>/dev/null)
  [ -n "$BENCH_SCRIPT_NAME" ] && HAS_BENCH_SCRIPT="npm:$BENCH_SCRIPT_NAME"
fi

# Check for criterion in Cargo.toml
if [ -z "$HAS_BENCH_SCRIPT" ] && grep -q "criterion" "$WORKDIR/Cargo.toml" 2>/dev/null; then
  HAS_BENCH_SCRIPT="cargo:criterion"
fi

# Check for pytest-benchmark or asv
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  if grep -qiE "pytest-benchmark|asv" "$WORKDIR/requirements.txt" "$WORKDIR/pyproject.toml" 2>/dev/null; then
    HAS_BENCH_SCRIPT="python:pytest-benchmark"
  fi
fi

# Check for benchmarks/ directory with executables
if [ -z "$HAS_BENCH_SCRIPT" ] && [ -d "$WORKDIR/benchmarks" ]; then
  BENCH_EXEC=$(find "$WORKDIR/benchmarks" -maxdepth 2 \( -name "*.sh" -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" \) -print | head -1)
  [ -n "$BENCH_EXEC" ] && HAS_BENCH_SCRIPT="dir:$BENCH_EXEC"
fi

# Check for standalone bench files
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  BENCH_FILE=$(find "$WORKDIR" -maxdepth 3 -name "bench_*.py" -o -name "*_bench.py" -o -name "benchmark_*.py" | head -1)
  [ -n "$BENCH_FILE" ] && HAS_BENCH_SCRIPT="file:$BENCH_FILE"
fi

echo "HAS_BENCH_SCRIPT=${HAS_BENCH_SCRIPT}"

# Self-skip if no bench signal
if [ -z "$HAS_BENCH_SCRIPT" ]; then
  echo "SKIPPED: No benchmark script detected. To activate this lens, add a 'bench' script to package.json, criterion to Cargo.toml, pytest-benchmark to requirements.txt, or create a benchmarks/ directory."
  exit 0
fi
```

Use TodoWrite to log the bench signal found and the baseline capture status.

## Phase 2: Capture Baseline (Phase 1 of this principle's two-phase operation)

This runs during the orchestrator's Phase 1 (before Phase 3 fixes). The orchestrator calls this lens in **baseline mode** by passing `--capture-baseline` in $ARGUMENTS.

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
mkdir -p "$WORKDIR/tmp/god-review"

BASELINE_FILE="$WORKDIR/tmp/god-review/perf-baseline.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Run the benchmark based on detected type
run_bench() {
  case "$HAS_BENCH_SCRIPT" in
    npm:*)
      SCRIPT_NAME="${HAS_BENCH_SCRIPT#npm:}"
      cd "$WORKDIR" && npm run "$SCRIPT_NAME" 2>&1
      ;;
    cargo:criterion)
      cd "$WORKDIR" && cargo bench --quiet 2>&1
      ;;
    python:pytest-benchmark)
      cd "$WORKDIR" && python -m pytest --benchmark-only --benchmark-json=/tmp/bench-output.json -q 2>&1
      cat /tmp/bench-output.json 2>/dev/null
      ;;
    dir:*|file:*)
      BENCH_PATH="${HAS_BENCH_SCRIPT#*:}"
      cd "$WORKDIR" && bash "$BENCH_PATH" 2>&1
      ;;
  esac
}

# Capture raw output
BENCH_RAW=$(run_bench 2>&1)
echo "$BENCH_RAW" | head -100

# Parse timings from output (heuristic parser — handles common formats)
python3 << PYEOF
import re, json, sys

raw = """$BENCH_RAW"""

timings = {}

# criterion format: "bench_name ... time: [ X.XX µs  X.XX µs  X.XX µs]"
for m in re.finditer(r'^(\S+.*?)\s+\.\.\.\s+time:\s+\[.*?([\d.]+)\s*(ns|µs|ms|s)', raw, re.MULTILINE):
    name, val, unit = m.group(1).strip(), float(m.group(2)), m.group(3)
    # normalize to milliseconds
    mult = {'ns': 1e-6, 'µs': 1e-3, 'ms': 1.0, 's': 1000.0}.get(unit, 1.0)
    timings[name] = round(val * mult, 6)

# pytest-benchmark JSON format (already parsed via /tmp/bench-output.json)
try:
    import json as j
    pb = j.load(open('/tmp/bench-output.json'))
    for bench in pb.get('benchmarks', []):
        timings[bench['name']] = bench['stats']['mean'] * 1000  # convert s to ms
except:
    pass

# Generic "name: Xms" format
for m in re.finditer(r'(\w[\w\s\-:]+?):\s+([\d.]+)\s*(ns|µs|ms|s|ops/s)', raw, re.MULTILINE):
    name, val, unit = m.group(1).strip()[:50], float(m.group(2)), m.group(3)
    if unit == 'ops/s':
        timings[name] = round(1000.0 / float(val), 6) if float(val) > 0 else None
    else:
        mult = {'ns': 1e-6, 'µs': 1e-3, 'ms': 1.0, 's': 1000.0}.get(unit, 1.0)
        timings[name] = round(float(val) * mult, 6)

result = {
    "captured_at": "$TIMESTAMP",
    "bench_signal": "$HAS_BENCH_SCRIPT",
    "timings_ms": timings,
    "raw_output_preview": raw[:500]
}
print(json.dumps(result, indent=2))
PYEOF
```

Save to `tmp/god-review/perf-baseline.json`:
```bash
python3 -c "..." > "$BASELINE_FILE"
echo "Baseline captured at: $BASELINE_FILE"
cat "$BASELINE_FILE"
```

## Phase 3: Compare Against Baseline (Phase 2 of this principle's two-phase operation)

The orchestrator calls this lens in **compare mode** after each AUTO_FIX commit, passing `--compare` in $ARGUMENTS.

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BASELINE_FILE="$WORKDIR/tmp/god-review/perf-baseline.json"
CURRENT_FILE="$WORKDIR/tmp/god-review/perf-current.json"
REGRESSION_THRESHOLD=0.05  # 5%

if [ ! -f "$BASELINE_FILE" ]; then
  echo "ERROR: No baseline file at $BASELINE_FILE. Run with --capture-baseline first."
  exit 1
fi

# Re-run benchmarks (same logic as baseline capture)
run_bench() { ... }  # same as above
BENCH_RAW=$(run_bench 2>&1)

# Parse current timings (same python3 block as above, outputting to $CURRENT_FILE)
python3 << 'PYEOF' > "$CURRENT_FILE"
# ... same parser as baseline ...
PYEOF

# Compare
python3 << PYEOF
import json

baseline = json.load(open("$BASELINE_FILE"))
current = json.load(open("$CURRENT_FILE"))

b_timings = baseline.get("timings_ms", {})
c_timings = current.get("timings_ms", {})

regressions = []
improvements = []
unchanged = []

for name, b_val in b_timings.items():
    if name not in c_timings or b_val is None or c_timings[name] is None:
        continue
    c_val = c_timings[name]
    if b_val == 0:
        continue
    delta = (c_val - b_val) / b_val  # positive = slower = regression
    if delta > $REGRESSION_THRESHOLD:
        regressions.append({"bench": name, "before_ms": round(b_val,4), "after_ms": round(c_val,4), "delta_pct": round(delta*100,2)})
    elif delta < -$REGRESSION_THRESHOLD:
        improvements.append({"bench": name, "before_ms": round(b_val,4), "after_ms": round(c_val,4), "delta_pct": round(delta*100,2)})
    else:
        unchanged.append(name)

result = {
    "regressions": regressions,
    "improvements": improvements,
    "unchanged_count": len(unchanged),
    "threshold_pct": $REGRESSION_THRESHOLD * 100
}
print(json.dumps(result, indent=2))

if regressions:
    print(f"\nREGRESSION_DETECTED: {len(regressions)} benchmark(s) regressed > {$REGRESSION_THRESHOLD*100:.0f}%")
    for r in regressions:
        print(f"  {r['bench']}: {r['before_ms']:.4f}ms → {r['after_ms']:.4f}ms (+{r['delta_pct']:.1f}%)")
    exit(2)  # Non-zero = regression detected; orchestrator reverts
else:
    print(f"\nNO_REGRESSION: all {len(b_timings)} benchmarks within {$REGRESSION_THRESHOLD*100:.0f}% threshold")
    exit(0)
PYEOF

COMPARE_EXIT=$?

# Output regression status for orchestrator to parse
if [ $COMPARE_EXIT -eq 2 ]; then
  echo "PERF_REGRESSION=true"
  echo "REVERT_REQUIRED=true"
else
  echo "PERF_REGRESSION=false"
  echo "REVERT_REQUIRED=false"
fi
```

The orchestrator reads the exit code and `PERF_REGRESSION` output:
- Exit 0 + `PERF_REGRESSION=false` → keep the fix
- Exit 2 + `PERF_REGRESSION=true` → `git reset --hard HEAD~1` (canonical revert per Locked Decision in plan)

## Phase 4: Generate Report

In report-only mode (no `--compare`, no `--capture-baseline`), this lens reports current benchmark timings and any obvious outliers.

```markdown
# Performance Benchmark Report

**Scope:** {scope}
**Status:** {PASS | WARN | CRITICAL}
**Tier:** 2 (stack-gated by HAS_BENCH_SCRIPT)
**Bench signal:** {HAS_BENCH_SCRIPT value}
**Mode:** {baseline-capture | compare | report-only}

## Baseline Timings (report-only mode)

| Benchmark | Current (ms) | Threshold | Status |
|-----------|-------------|-----------|--------|
| `{name}` | {X.Xms} | — | INFO |

## Regression Analysis (compare mode)

| Benchmark | Before (ms) | After (ms) | Delta | Severity |
|-----------|------------|-----------|-------|----------|
| `{name}` | {X.X} | {Y.Y} | +{Z.Z}% | CRITICAL |
| `{name}` | {X.X} | {Y.Y} | -{W.W}% | improvement |

## Baseline Update History

Baseline is updated when 3 consecutive non-regressing rounds pass (prevents slow-creep regressions).

- Round {N}: baseline updated from {date} → {date}

## Recommendations

{If regressions found:}
- Revert the fix that caused the regression — orchestrator handles this automatically
- Investigate why `{bench_name}` regressed: likely O(n²) pattern introduced or sync I/O added
- Consider running `perf-heuristic.md` on the same file to identify the specific smell

{If no regressions:}
- All benchmarks within 5% threshold — no action required
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/perf-benchmark-findings.md`
2. Save current timings to `tmp/god-review/perf-current.json` (compare mode)
3. Print summary:
   - PASS: all benchmarks within 5% of baseline (or no baseline yet — report mode)
   - WARN: benchmarks run but no baseline for comparison
   - CRITICAL: one or more benchmarks regressed >5% — revert triggered by orchestrator

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See CRITERIA.md for confidence/severity definitions. The thresholds below are principle-specific.

- **PASS**: All benchmarks within ±5% of baseline. Or: report-only mode with baseline captured successfully.
- **WARN**: Stack gate passed but baseline cannot be captured (bench script fails to run, output unparseable).
- **CRITICAL**: Any benchmark regressed >5% relative to baseline after an AUTO_FIX commit. Triggers automatic revert via orchestrator.

The 5% threshold is principle-specific and intentionally tight — small regressions compound over many fix rounds.

## Baseline Update Policy

The baseline at `tmp/god-review/perf-baseline.json` is updated ONLY when:
- 3 consecutive rounds pass with no regression detected AND
- `kept_fixes_this_round > 0` for at least one of those 3 rounds (baseline drifting down on fix-free rounds would obscure slow-creep regressions)

This prevents the "boiling frog" pattern where each 4% regression is within threshold but 10 rounds = 50% total degradation.

## Risk Levels

- **CRITICAL**: Any benchmark >5% slower than baseline after a committed fix
- **HIGH**: Benchmark 3-5% slower (approaching threshold — monitor closely)
- **MEDIUM**: Benchmark script exists but fails to run (cannot establish ground truth)
- **LOW**: Benchmark script newly added — first run establishes baseline, no regression possible yet

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Benchmark variance: if a system is under load, benchmarks may show 5-10% natural variance. If a single benchmark fires the regression threshold on a quiet codebase change, check variance before reverting: re-run the benchmark 3 times to confirm the regression is real, not noise
- Do NOT flag benchmarks in test fixtures or documentation examples — only executable bench scripts
- Do NOT run benchmarks in report-only mode on untrusted code (the bench scripts run with full filesystem and network access)

Run analysis on: $ARGUMENTS (or full repo if empty). Pass `--capture-baseline` or `--compare` for two-phase operation; omit for report-only mode.
