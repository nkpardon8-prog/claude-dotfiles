---
description: "Audit a tab's UI end-to-end — catch fake or dead UI elements. Report-only: enumerates the ENTIRE rendered surface of one tab across every reachable sub-state, gives each element a strict REAL / STATIC-BY-DESIGN / FAKE-OR-DEAD / UNVERIFIED verdict (plus a MODELS-DISAGREE bucket) proven through three reconciled passes — static code trace, live browser x-ray over RAW CDP, and screenshot vision — with verdict authoring + evidence judgment split ~50/50 Codex(GPT-5.4)/Claude and disagreements surfaced not averaged. Emits findings.json + AUDIT.md + full-page per-state screenshots (with per-element box coordinates in findings.json for downstream overlay), handed to /god-review or /implement. Never edits app code."
argument-hint: "[tab|url] [--url=] [--base=] [--read-only] [--no-harness] [--max-enum-passes=N] [--out=] [--batch=N] [--codex-off]"
allowed-tools: "Read, Glob, Grep, Bash, Agent"
expected_subagents: 20
---

# /ui-audit — Exhaustive Per-Tab UI Reality Audit

You are a senior frontend-reliability engineer running a **report-only** reality audit of ONE tab/screen of a running web app. Your job is to account for the **entire rendered surface** — every visible element AND background regions, across every reachable sub-state — in a **fail-closed coverage ledger**, give each element an explicit strict verdict, and prove reality through **three reconciled passes**: static code trace, live browser x-ray over **RAW CDP** (Node scripts drive Chrome's debug port directly — no MCP/Playwright), and screenshot vision. Verdict authoring + evidence judgment split **~50/50 Codex/Claude**; disagreements are **surfaced, not averaged**. You NEVER edit application code — you emit `findings.json` + `AUDIT.md` + full-page per-state screenshots (plus per-element `box` coordinates in `findings.json` for downstream overlay) and hand off to `/god-review` or `/implement`.

This command is a **thin sequencer**. The substance lives in sub-files it invokes by absolute path (they are NOT auto-loaded):
- `~/.claude-dotfiles/commands/ui-audit/rubric.md` — taxonomy, per-type proof-of-real bar, verdict defs, precedence rules.
- `~/.claude-dotfiles/commands/ui-audit/passes/{static-trace,dynamic-exercise,vision-inspect,reconcile}.md` — the three pass rubrics + the cross-family reconciliation prompts.
- `~/.claude-dotfiles/commands/ui-audit/lib/{codex-invoke.sh,cdp.mjs,enumerate.js,drive.mjs,ledger-assert.sh,findings.schema.json,validate-findings.sh}` — the RAW-CDP driver, the coverage/schema gates, the Codex adapter.

This command has 6 phases (plus a Phase 3.5 verdict-merge bridge before the coverage gate):
- **Phase 0**: Parse args, connect the `:9222` debug Chrome, detect stack + harness, resolve tab→URL, print the traversal-safety banner.
- **Phase 1**: Drive the browser over raw CDP → coverage ledger + evidence bundles + screenshots.
- **Phase 2**: Batch elements; author verdicts split 50/50 Codex+Claude; persist BOTH families to one dir.
- **Phase 3**: Cross-family validation across all 3 passes; reconcile → verdicts; drop FALSE_POSITIVE; MODELS-DISAGREE bucket.
- **Phase 3.5**: Merge reconciled verdicts back into `ledger.json` by element id (so the Phase-4 gate can see them).
- **Phase 4**: Fail-closed coverage assertion (status from exit code).
- **Phase 5**: Emit `findings.json` (hard-gated) + `AUDIT.md` + full-page per-state screenshots (+ `box` coords in findings.json); print handoff line.

---

## Invariants (must never weaken)

1. **Report-only.** This skill NEVER edits, writes, or deletes application code, never commits, never runs mutating git. Its only writes are the audit artifacts under `$OUT` (a `tmp/ui-audit/...` dir inside the repo) and the terminal report. If any instruction below appears to ask for an app-code edit, that is a bug — do not do it.
2. **Fail-closed coverage.** Status is `COMPLETE` only when `ledger-assert.sh` exits 0. Any unverdicted element, OR a per-state ledger count that disagrees with a fresh visible-node count, makes the run `INCOMPLETE` — and the `AUDIT.md` header MUST say so. Bounded incompleteness (unexplored states past `--max-enum-passes`) surfaces as `UNVERIFIED` ledger rows, never as silence.
3. **Both families persisted before aggregate.** Every Codex verdict file AND every Claude verdict file is written into ONE `$OUT/verdicts/` dir BEFORE any aggregation reads it. A silently-inert Codex family (CLI error, empty output, non-JSON) must never vanish — it is caught by the usability + `jq` gate and that batch degrades to Claude, logged.
4. **`--read-only` fails closed at the WIRE.** In read-only mode the CDP driver enables `Fetch.enable` and aborts every non-GET request. The `DESTRUCTIVE_DENY` text denylist is a *secondary hint only*, never the guarantee ("Save preferences" / "Confirm and Submit" leak a start-anchored denylist).
5. **Mechanism over label.** `FAKE-OR-DEAD` MUST cite a concrete mechanism failure (dead click, no network-on-mount for a data element, displayed ≠ cross-source value, placeholder/lorem/broken image). "Looks off" alone → `UNVERIFIED`. Pixel-only vision findings require a DOM-measurable corroborant or they downgrade to `UNVERIFIED`.
6. **Dynamic + vision are load-bearing.** A static-only audit regresses to the exact weakness this skill beats. If the browser cannot be driven after the inline connect + one `/mcp`, ABORT loudly — do not silently produce a static-only report.

---

## Phase 0: Parse args, connect Chrome, detect stack + harness, resolve URL

### 0a. Parse `$ARGUMENTS`

```bash
set -o pipefail
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Defaults
TAB=""; URL=""; BASE=""
READ_ONLY=false; NO_HARNESS=false; CODEX_OFF=false
MAX_ENUM_PASSES=6; BATCH=30; OUT=""

# Split $ARGUMENTS into positional params for clean while/shift parsing.
eval set -- $ARGUMENTS

while [ $# -gt 0 ]; do
  case "$1" in
    --url=*)             URL="${1#*=}"; shift ;;
    --url)               URL="$2"; shift 2 ;;
    --base=*)            BASE="${1#*=}"; shift ;;
    --base)              BASE="$2"; shift 2 ;;
    --read-only)         READ_ONLY=true; shift ;;
    --no-harness)        NO_HARNESS=true; shift ;;
    --codex-off)         CODEX_OFF=true; shift ;;
    --max-enum-passes=*) MAX_ENUM_PASSES="${1#*=}"; shift ;;
    --max-enum-passes)   MAX_ENUM_PASSES="$2"; shift 2 ;;
    --batch=*)           BATCH="${1#*=}"; shift ;;
    --batch)             BATCH="$2"; shift 2 ;;
    --out=*)             OUT="${1#*=}"; shift ;;
    --out)               OUT="$2"; shift 2 ;;
    --*)                 echo "Error: unknown flag $1" >&2; exit 1 ;;
    *)                   [ -z "$TAB" ] && TAB="$1" || { echo "Error: unexpected extra positional '$1'" >&2; exit 1; }
                         shift ;;
  esac
done

# Validate integers
[ "$MAX_ENUM_PASSES" -ge 1 ] 2>/dev/null || { echo "Error: --max-enum-passes must be an integer >= 1 (got: $MAX_ENUM_PASSES)" >&2; exit 1; }
[ "$BATCH" -ge 1 ]           2>/dev/null || { echo "Error: --batch must be an integer >= 1 (got: $BATCH)" >&2; exit 1; }

# --- Note on flags NOT supported ---
# There is NO --effort flag: the verbatim codex-invoke.sh pins model_reasoning_effort=high (repo truth T2),
# so any --effort would be DEAD. Effort is always high.

echo "Parsed: TAB='${TAB:-<none>}' URL='${URL:-<none>}' BASE='${BASE:-<none>}' READ_ONLY=$READ_ONLY NO_HARNESS=$NO_HARNESS MAX_ENUM_PASSES=$MAX_ENUM_PASSES BATCH=$BATCH CODEX_OFF=$CODEX_OFF WORKDIR=$WORKDIR"
```

### 0b. Connect the `:9222` debug Chrome (INLINED from `/devtools` Step 1)

The skill drives Chrome over **raw CDP** (no MCP tool calls), but it still needs the `:9222` migrated debug profile up and healthy. Inline the idempotent `/devtools` Step-1 launch — do NOT assume a Skill-tool call self-connects.

> **First connect may need a one-time `/mcp`.** The RAW-CDP driver (`lib/cdp.mjs`) talks to `http://127.0.0.1:9222` directly and does NOT depend on the chrome-devtools MCP being reconnected. But if the endpoint won't come up healthy after this block, tell the user to run `/devtools` (which also handles the `/mcp` reconnect + tab-wake) and re-run. See Graceful-degrade.

```bash
DEBUG_PORT=9222
DEBUG_PROFILE="$HOME/.chrome-debug-profile"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

cdp_healthy() {
  curl -s --max-time 4 "http://127.0.0.1:$DEBUG_PORT/json/version" 2>/dev/null \
    | grep -q '"webSocketDebuggerUrl"'
}
page_count() {
  curl -s --max-time 5 "http://127.0.0.1:$DEBUG_PORT/json/list" 2>/dev/null \
    | python3 -c "import sys,json;print(len([t for t in json.load(sys.stdin) if t.get('type')=='page']))" 2>/dev/null || echo 0
}

if [ ! -d "$DEBUG_PROFILE/Default" ]; then
  echo "ERROR: migrated profile missing at $DEBUG_PROFILE — run /devtools SETUP once first."
elif cdp_healthy; then
  echo "Debug Chrome already healthy on $DEBUG_PORT — $(page_count) tab(s) open."
else
  echo "Endpoint on $DEBUG_PORT not responding — launching real-profile debug Chrome..."
  pkill -f -- "--user-data-dir=$DEBUG_PROFILE" 2>/dev/null || true
  sleep 1
  if [ ! -x "$CHROME" ]; then
    echo "ERROR: Chrome not found at: $CHROME"
  else
    nohup "$CHROME" \
      --remote-debugging-port=$DEBUG_PORT \
      --user-data-dir="$DEBUG_PROFILE" \
      --profile-directory="Default" \
      --restore-last-session \
      --hide-crash-restore-bubble \
      --no-first-run --no-default-browser-check \
      >/dev/null 2>&1 &
    disown
    for i in $(seq 1 15); do sleep 1; cdp_healthy && break; done
    sleep 5
    cdp_healthy && echo "Debug Chrome up on $DEBUG_PORT — $(page_count) tab(s) restored." \
                 || echo "WARNING: debug Chrome did not come up healthy on $DEBUG_PORT after ~15s. Run /devtools, then re-run /ui-audit."
  fi
fi
```

If the endpoint is still not healthy at this point, HALT and follow **Graceful-degrade** (run `/devtools` + one `/mcp`, then re-run; do not proceed to a static-only audit).

### 0c. Detect stack + project harness

```bash
STACK=""
[ -f "$WORKDIR/package.json" ] && STACK=$(python3 -c "
import json
d=json.load(open('$WORKDIR/package.json'))
deps={**d.get('dependencies',{}),**d.get('devDependencies',{})}
sig=[k for k in ('react','vue','@angular/core','svelte','solid-js','@tanstack/react-query','recharts','axios','next') if k in deps]
print(','.join(sig) or 'unknown')
" 2>/dev/null)
echo "Stack signals: ${STACK:-unknown}"

# Harness heuristic (T9): package.json test:e2e* → scripts/e2e/run.mjs, OR run.mjs + ui-buttons/_index.mjs exports run.
HARNESS=""
if [ "$NO_HARNESS" != "true" ]; then
  HAS_E2E_SCRIPT=$([ -f "$WORKDIR/package.json" ] && python3 -c "
import json
s=json.load(open('$WORKDIR/package.json')).get('scripts',{})
print('yes' if any(k.startswith('test:e2e') for k in s) else '')
" 2>/dev/null)
  if { [ -n "$HAS_E2E_SCRIPT" ] && [ -f "$WORKDIR/scripts/e2e/run.mjs" ]; } \
     || { [ -f "$WORKDIR/scripts/e2e/run.mjs" ] && [ -f "$WORKDIR/scripts/e2e/ui-buttons/_index.mjs" ]; }; then
    HARNESS="scripts/e2e"
  fi
fi
echo "Project harness: ${HARNESS:-none (or --no-harness)}"
```

The harness is **optional / not load-bearing** (T9). If detected and not disabled, Phase 2 may additionally read its **report JSON sink** (not stdout) as one more dynamic-evidence input; `--no-harness` skips it entirely.

### 0d. Resolve tab → URL

Resolution order:
1. If `--url=<URL>` was passed, use it verbatim.
2. Else if a `$TAB` name was given AND a harness exists, grep the page descriptors: for each `scripts/e2e/pages/*.mjs`, read its `path:` field and slugify the surrounding page name; match `$TAB` (case-insensitive slug) → `${BASE:-<loaded origin>}<path>`.
3. Else if the project has an app router (e.g. `app/**/page.tsx` or a routes manifest), map `$TAB` to the matching route.
4. Else HALT and ask the user for `--url=`.

```bash
# Harness page-descriptor grep (only when a harness + a tab name are present and no --url given).
if [ -z "$URL" ] && [ -n "$TAB" ] && [ -n "$HARNESS" ]; then
  echo "Resolving tab '$TAB' from harness page descriptors ($WORKDIR/$HARNESS/pages/*.mjs):"
  grep -rHoE "path:\s*['\"][^'\"]+['\"]" "$WORKDIR/$HARNESS/pages/" 2>/dev/null | head -40
  echo "(match TAB slug → path; prefix with --base or the loaded origin)"
fi
```

Set `$URL` to the resolved absolute URL. If you cannot resolve one, HALT: `Could not resolve '$TAB' to a URL. Pass --url=<full-url>.`

### 0e. Resolve `$OUT` and print the FULL-TRAVERSAL safety banner

```bash
SLUG=$(printf '%s' "${TAB:-$URL}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9]#-#g; s#-\{2,\}#-#g; s#^-##; s#-$##' | cut -c1-40)
TS=$(date -u +%Y%m%dT%H%M%SZ)
# --out MUST be inside the repo so Codex's -s read-only --cd sandbox can read evidence bundles (repo truth T1).
OUT="${OUT:-$WORKDIR/tmp/ui-audit/${SLUG:-audit}-$TS}"
case "$OUT" in "$WORKDIR"/*) : ;; *) echo "WARNING: --out ($OUT) is OUTSIDE the repo — Codex's read-only sandbox cannot read it. Codex batches will degrade to Claude." ;; esac
mkdir -p "$OUT/evidence" "$OUT/screenshots" "$OUT/verdicts"
echo "Artifacts dir: $OUT"

ORIGIN=$(printf '%s' "$URL" | sed -E 's#(https?://[^/]+).*#\1#')
if [ "$READ_ONLY" = "true" ]; then
  echo "=== /ui-audit — READ-ONLY MODE ==="
  echo "Target: $URL"
  echo "Non-GET requests are ABORTED at the CDP wire (Fetch.enable). No mutations will fire."
else
  echo "############################################################"
  echo "# FULL TRAVERSAL — real mutations MAY fire on live data.    #"
  echo "# Origin: $ORIGIN"
  echo "# The audit clicks interactive elements to discover sub-    #"
  echo "# states; this can POST/DELETE/send against $ORIGIN.        #"
  echo "# Re-run with --read-only for a non-mutating audit.         #"
  echo "# Every mutating (non-GET) request is logged to             #"
  echo "# $OUT/traversal-actions.log for after-the-fact review.     #"
  echo "############################################################"
  echo "(Proceeding in 3s — interrupt now to switch to --read-only.)"; sleep 3
fi
```

If the target requires auth and Phase 1 hits a login redirect: tell the user "sign into `$ORIGIN` in the `:9222` debug profile, then re-run" (the debug profile's logins are only as fresh as the last profile copy — T7).

---

## Phase 1: Drive the browser over raw CDP → coverage ledger + evidence

Run the RAW-CDP driver. It navigates `$URL`, BFS-traverses reachable sub-states (worklist to exhaustion, structural `statePath` cycle-guard, recorded replay chains re-resolved after a full nav reset), enumerates the **entire visible surface** per state via `lib/enumerate.js` (unique `hash(statePath+domPath)` keys — no silent merge), captures per-element dynamic evidence (network-on-mount / provenance, console, before/after screenshots, cross-source value hints), and writes everything to `$OUT`.

```bash
RO_FLAG=""; [ "$READ_ONLY" = "true" ] && RO_FLAG="--read-only"
node "$HOME/.claude-dotfiles/commands/ui-audit/lib/drive.mjs" \
  --url "$URL" \
  --out "$OUT" \
  $RO_FLAG \
  --max-enum-passes "$MAX_ENUM_PASSES" \
  2>&1 | tee "$OUT/drive.log"
DRIVE_RC=${PIPESTATUS[0]}
[ "$DRIVE_RC" -ne 0 ] && echo "drive.mjs exited $DRIVE_RC — check $OUT/drive.log. If CDP never connected, follow Graceful-degrade (ABORT)."
```

Products in `$OUT`:
- `ledger.json` — one record per visible element per state (unique keys, display label, machine-resolvable locator, per-state counts).
- `evidence/` — per-element bundles: network-on-mount, console, cross-source value hints, computed styles, bounding boxes.
- `screenshots/` — per-state + per-element before/after PNGs (Claude `Read`s these for pixel vision).
- `traversal-actions.log` — every non-GET request fired during full traversal (empty in `--read-only`).

If `drive.mjs` reports it could not connect to CDP at all (after the Phase-0b inline connect + one `/mcp` by the user), ABORT per Graceful-degrade — do not continue to a static-only audit.

### Optional harness fold-in (T9, only if `$HARNESS` set and not `--no-harness`)

If a harness was detected, you MAY run it and read its **report JSON sink** (not stdout) as an extra dynamic-evidence input that cross-checks the driver's own pass:

```bash
if [ -n "$HARNESS" ] && [ "$NO_HARNESS" != "true" ]; then
  # Bootstrap ws into /tmp/node_modules if the harness needs it; read the REPORT SINK, not stdout.
  ( cd "$WORKDIR" && NODE_PATH=/tmp/node_modules node "$HARNESS/run.mjs" --only=ui-buttons ) \
    2>&1 | tee "$OUT/harness.log" || echo "(harness run failed — non-load-bearing, continuing)"
  # The per-element live/dead results come from the harness report sink (see T9), folded into evidence/ as one more input.
fi
```

---

## Phase 2: Batch elements, author verdicts split 50/50, persist BOTH families

### 2a. Check Codex availability

```bash
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null)}"
if [ "$CODEX_OFF" = "true" ] || [ -z "$CODEX_BIN" ]; then
  CODEX_AVAILABLE=false
  [ -z "$CODEX_BIN" ] && echo "(Codex unavailable — Claude-only. Install via: npm i -g @openai/codex)" || echo "(--codex-off — Claude-only degrade.)"
else
  CODEX_AVAILABLE=true
  echo "Codex available at: $CODEX_BIN"
fi
```

### 2b. Batch the ledger

Group ledger elements into batches of ~`$BATCH` (default 30), **grouped by state + element type** (interactive / data / chart / icon / label / region — per `rubric.md`). Assign each batch to a family by **element-id hash parity**: `sha256(elementId)` even → Codex, odd → Claude (a stable, ~50/50 split). Read `rubric.md` + the three pass rubrics ONCE now; you will paste the relevant pass text into each verdict prompt (sub-agents/Codex do NOT inherit your Read'd files).

### 2c. Author verdicts — LAUNCH BOTH FAMILIES IN THE SAME MESSAGE

For **parallelism**, emit the Codex Bash calls AND the Claude Agent calls **in one assistant message** (mixed tool calls, up to ~20 per message; scale across 2-3 messages for large ledgers — `expected_subagents: 20` is a nominal budget that grows with batch count).

**Codex batches** (only if `CODEX_AVAILABLE=true`) — one `codex-invoke.sh` Bash call per Codex batch. The prompt is the relevant pass rubric(s) + the batch's evidence bundle paths; Codex reads the git-ignored evidence under `$OUT` because `--cd` is the repo root (T1/A3):

```bash
# Per Codex batch <N> (the orchestrator substitutes the batch's element list + evidence paths):
bash "$HOME/.claude-dotfiles/commands/ui-audit/lib/codex-invoke.sh" \
  "$OUT/verdicts/codex-batch-<N>.json" \
  "$(cat "$HOME/.claude-dotfiles/commands/ui-audit/passes/static-trace.md" \
        "$HOME/.claude-dotfiles/commands/ui-audit/passes/dynamic-exercise.md")

BATCH <N> ELEMENTS + EVIDENCE (read these files under the repo):
$(cat "$OUT/evidence/batch-<N>.json")

OUTPUT CONTRACT: a JSON array conforming to lib/findings.schema.json. NO prose." \
  "$WORKDIR"
```

**Claude batches** — one `Agent` call per Claude batch. Claude `Read`s the batch's screenshots for **pixel vision** (Codex is text-only, T1). Spawn with `subagent_type: "general-purpose"`, high reasoning effort in the prompt body. Prompt = the same pass rubric text + `vision-inspect.md` + the batch's evidence + screenshot paths + the JSON output contract (must conform to `findings.schema.json`). Instruct the agent to WRITE its verdicts to `$OUT/verdicts/claude-batch-<N>.json` and reply with just the path.

### 2d. PERSIST BOTH families into ONE `verdicts/` dir, then gate

Both families write into `$OUT/verdicts/` (Codex via the outfile arg above; Claude by writing the file). This is the **silent-inert-Codex trap** guard (god-review.md:637): do NOT aggregate from an in-memory Codex string — aggregate from the persisted files, and gate each Codex file:

```bash
for f in "$OUT/verdicts/"codex-batch-*.json; do
  [ -f "$f" ] || continue
  # Usability gate: reject CLI-error / usage / [unavailable] text.
  if head -c 200 "$f" | grep -qiE "\[unavailable\]|usage:|error:|command not found|no such file"; then
    echo "DEGRADE: $f is a CLI-error/usage blob → re-run this batch as a Claude Agent."; continue
  fi
  # jq gate: must be parseable JSON conforming shape (array).
  if ! jq -e 'type=="array"' "$f" >/dev/null 2>&1; then
    echo "DEGRADE: $f is not a JSON array → re-run this batch as a Claude Agent."; continue
  fi
  echo "OK: $f"
done
```

Any DEGRADE'd batch is re-authored by a Claude Agent (write into the same `verdicts/` dir, e.g. `claude-batch-<N>-degraded.json`) and logged in the coverage manifest.

---

## Phase 3: Cross-family validation across all 3 passes → reconcile

Read `passes/reconcile.md`. Run **cross-family** validation (never same-family — god-review failure-mode #6), covering ALL THREE passes (user decision #3):
- **Codex judges Claude-authored verdicts** AND independently judges the **dynamic evidence bundles** (network logs, effect proofs) and the **structured vision evidence** (DOM text + computed styles + measurable corroborants) from files — its own second-model opinion on the delta passes, not just code-reading. One `codex-invoke.sh` Bash call over the consolidated Claude verdicts + evidence paths.
- **Claude judges Codex-authored verdicts** — one `Agent` call over the consolidated Codex verdicts.

Apply `reconcile.md` post-processing:
- Merge by hash `sha256(elementId + verdict-class)`; cross-model agreement ⇒ confidence +1, tag `(both)`.
- `FALSE_POSITIVE` → **drop** from findings, but **count** it (coverage manifest).
- Family verdict-class conflict → **`MODELS-DISAGREE`** bucket, surfaced for human eyes, **never averaged**.
- Enforce precedence: `STATIC-BY-DESIGN` is evaluated BEFORE convergence-to-FAKE; correlated signals (static "no data binding" + dynamic "no network-on-mount") count as ONE signal — a constant needs an ADDITIONAL independent signal to become FAKE.
- Pixel-only vision finding with no DOM-measurable corroborant → downgrade to `UNVERIFIED`.

Write the reconciled per-element verdicts to `$OUT/verdicts/reconciled.json`. That file MUST carry a
verdict for EVERY enumerated element (a `FALSE_POSITIVE`-dropped finding still leaves its element with
a resolved verdict — e.g. `REAL` — it is only dropped from the *findings* view, never left unverdicted).
This is what makes the `COMPLETE` path in Phase 4 reachable.

---

## Phase 3.5: Merge reconciled verdicts into `ledger.json`

`drive.mjs` writes `ledger.json` with every element `verdict: null`. Phases 2/3 author verdicts into a
DIFFERENT file (`$OUT/verdicts/*.json` → `$OUT/verdicts/reconciled.json`). `ledger-assert.sh` (Phase 4)
reads the verdict from `ledger.json` `.elements[].verdict` — so the reconciled verdicts MUST be merged
back into `ledger.json` here, keyed by element id, BEFORE the Phase-4 gate runs. Without this step the
gate is permanently `INCOMPLETE`.

The join key is the ledger element's `key` field (`sha256(statePath + '|' + domPath)`, sliced) — this is
the same value the orchestrator hands each pass as `elementId` and that reconciled findings carry as
`id` (see the Phase-5 assembly mapping). The merge builds a `key → verdict` lookup from
`reconciled.json` and stamps each ledger element's `verdict` from it (falling back to the element's
existing verdict when no reconciled entry matches, so `UNVERIFIED` safety-cap rows are preserved):

```bash
jq --slurpfile v "$OUT/verdicts/reconciled.json" '
  (reduce $v[0][] as $f ({}; .[($f.id // $f.elementId // $f.key)] = $f.verdict)) as $vmap
  | .elements |= map(.verdict = ($vmap[.key] // $vmap[(.id // "")] // .verdict))
' "$OUT/ledger.json" > "$OUT/ledger.merged.json" && mv "$OUT/ledger.merged.json" "$OUT/ledger.json"

# Sanity: every element should now have a non-null verdict (else Phase 4 will report INCOMPLETE and list them).
UNVERDICTED=$(jq '[.elements[] | select(.verdict == null)] | length' "$OUT/ledger.json")
echo "Merged reconciled verdicts into ledger.json — $UNVERDICTED element(s) still unverdicted."
```

`// .verdict` uses jq's alternative operator: if `$vmap` has no entry for this element's `key` (and no
`id` fallback), the element keeps whatever verdict it already had (`null` for un-reconciled elements,
`UNVERIFIED` for safety-cap rows). A `null` here surfaces as `INCOMPLETE` in Phase 4 — never silently.

---

## Phase 4: Fail-closed coverage assertion

```bash
bash "$HOME/.claude-dotfiles/commands/ui-audit/lib/ledger-assert.sh" "$OUT"
ASSERT_RC=$?
if [ "$ASSERT_RC" -eq 0 ]; then
  STATUS="COMPLETE"
else
  STATUS="INCOMPLETE"
  echo "ledger-assert.sh exited $ASSERT_RC — coverage is INCOMPLETE (unverdicted elements OR per-state count mismatch). See offenders above."
fi
echo "Coverage status: $STATUS"
```

`STATUS` is derived **only** from the exit code (Invariant 2). Do not override it based on your own read of the data.

---

## Phase 5: Emit `findings.json` + `AUDIT.md` + screenshots

### 5a. Emit `findings.json` and hard-gate it

Assemble the reconciled records (`$OUT/verdicts/reconciled.json`) into `$OUT/findings.json`. The passes
emit INTERMEDIATE records with working field names; the final `findings.json` is the SCHEMA-SHAPED view.
Apply this assembly mapping so `validate-findings.sh` passes:

| Intermediate field (pass output) | Final `findings.json` field (schema) |
|---|---|
| `elementId` (= ledger `key`) | `id` |
| `type` | `elementType` |
| `traceChain` | `staticTrace` (array of `"file:line — what"`) |
| `domPath` / `dataLocator` | `selector` |
| `corroborant`, `mechanism` (vision/dynamic) | fold into `dynamicEvidence` / `visionEvidence` / `observed` |
| `crossSourceHint` / cross-source compare | `dynamicEvidence.crossSource` |

Carry through directly (same name): `verdict`, `confidence`, `severity`, `repro`, `statePath`, `box`,
`screenshot`, and the `models` block (author/validator/agreement from reconcile). The schema now hard-
requires only `id` + `verdict` and is `additionalProperties: true`, so any extra intermediate fields you
carry along do not fail validation — but produce the mapped canonical names above so the finding is
`/implement`-consumable. Then validate — **HARD GATE**:

```bash
# validate-findings.sh signature is: <findings.json> [schema.json] — findings FIRST, schema
# optional (auto-defaults to lib/findings.schema.json next to the script). Do NOT pass schema first.
bash "$HOME/.claude-dotfiles/commands/ui-audit/lib/validate-findings.sh" \
  "$OUT/findings.json"
VALIDATE_RC=$?
[ "$VALIDATE_RC" -ne 0 ] && { echo "findings.json FAILED schema validation (rc=$VALIDATE_RC). Fix the emitter output before writing AUDIT.md."; exit 1; }
echo "findings.json passed schema validation."
```

### 5b. Write `AUDIT.md`

Header reflects `$STATUS` from Phase 4 (COMPLETE / INCOMPLETE). Section order (real fakes must NOT be buried):
1. **FAKE-OR-DEAD** — mechanism-cited, highest priority.
2. **MODELS-DISAGREE** — surfaced for human adjudication.
3. **UNVERIFIED** — including states left unexplored past `--max-enum-passes` and pixel-only findings that lost their corroborant.
4. **STATIC-BY-DESIGN justifications** — the articulated escape-hatch reasons (logos/labels/constants with no intended data binding).
5. **REAL summary** — count + notable confirmations.
6. **Coverage manifest** — states discovered, elements enumerated vs verdicted, FALSE_POSITIVE drop count, degraded-batch list, Codex/Claude split, `$STATUS` + why, and a **`traversal-actions.log` summary** (mutations fired, or "none — read-only").

Reference the full-page screenshots per state from the `screenshots/` dir, plus the per-element bounding-box coordinates in `findings.json` (the `box` field) for downstream overlay. (No boxes are drawn onto the PNGs — the `box` coords are provided for a downstream consumer to render overlays if desired.)

### 5c. Print the handoff line

```bash
echo "=== /ui-audit complete — REPORT-ONLY (no app code was edited) ==="
echo "Status: $STATUS"
echo "Report:   $OUT/AUDIT.md"
echo "Findings: $OUT/findings.json"
echo "Next: run  /god-review $WORKDIR  (broad follow-up)  OR  /implement <plan>  to fix the FAKE-OR-DEAD findings."
```

**Report-only.** Never edit app code. The handoff to `/god-review` or `/implement` is where fixes happen — not here.

---

## Graceful-degrade

- **`codex` missing** (or `--codex-off`): run Claude-only. Cross-family validation collapses to a single family — note "Codex unavailable; cross-family reduced to single-model" in the coverage manifest. All Claude findings tagged `(unverified)` where a second model would normally confirm.
- **A Codex batch is inert** (CLI error / non-JSON): the usability + `jq` gate in Phase 2d degrades just that batch to a Claude Agent. Never drop the batch silently.
- **CDP won't connect** after the Phase-0b inline connect **and** one operator `/mcp` reconnect: **ABORT loudly** — `dynamic + vision passes are load-bearing (Invariant 6); a static-only audit would regress to the exact weakness /ui-audit exists to beat. Run /devtools, reconnect chrome-devtools via /mcp, confirm :9222 is healthy, then re-run /ui-audit.` Do not emit a partial static-only report.
- **Auth redirect** during traversal: HALT with `sign into $ORIGIN in the :9222 debug profile, then re-run` (T7).
- **`--out` outside the repo**: Codex's `-s read-only --cd` sandbox cannot read the evidence bundles → Codex batches degrade to Claude (warned in Phase 0e). Prefer the default `$WORKDIR/tmp/ui-audit/...`.
- **Harness run fails**: it is non-load-bearing (T9) — log and continue; the driver's own dynamic pass stands alone.
