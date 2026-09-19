---
description: "Speed-evaluate a running web app by CLICKING it. Report-only: drives the :9222 debug Chrome over RAW CDP, enumerates routes + every bounded interactive element, verifies each one actually works, and times it accurately - per route (TTFB, document server-wait, FCP, LCP, load, bytes, slowest requests with dns/connect/ssl/send/wait/receive) and per click (time to first request, server wait vs download, DOM settle, and whether ANY visual feedback appeared within 100ms - the 'feels dead' metric). Classifies every slow action by DOMINANT LAYER (server-wait / network / client-render / waterfall / cold-start / no-feedback / unattributed) and emits report.json + REPORT.md for a fixing agent. Never edits app code, never signs in, never clicks destructive controls."
argument-hint: "[url] [--base=] [--routes=a,b,c] [--read-only] [--runs=N] [--out=] [--cold]"
allowed-tools: "Read, Glob, Grep, Bash"
---

# /speedeval - Click-Every-Button Speed Evaluation

You are a performance engineer running a **report-only** speed evaluation of a running web app.
You do not guess at performance from source code: you drive a real browser, click the real
controls, and time what the user actually waits for. The output is a machine-readable
`report.json` plus a human `REPORT.md`, written so **another agent** can pick them up and know
*which layer* to go fix - not just that something is slow.

This command is a **thin sequencer**. All measurement substance lives in Node libraries it invokes
by absolute path (they are NOT auto-loaded into context, and you normally never need to read them):

- `~/.claude-dotfiles/commands/speedeval/lib/measure.mjs` - the driver: connect, enumerate, click, time, write.
- `~/.claude-dotfiles/commands/speedeval/lib/inpage.js` - the in-page probe (paint/LCP/long-task/mutation/URL observers).
- `~/.claude-dotfiles/commands/speedeval/lib/classify.mjs` - raw numbers -> dominant layer + hypotheses + fix classes.
- `~/.claude-dotfiles/commands/speedeval/lib/report.mjs` - report.json -> REPORT.md.
- `~/.claude-dotfiles/commands/speedeval/README.md` - the report.json schema, in full.

The CDP transport is **reused, not rebuilt**: `measure.mjs` imports
`~/.claude-dotfiles/commands/ui-audit/lib/cdp.mjs` (`openTab`, `installReadOnlyGuard`,
`installMutationLogger`). There is exactly one CDP client in this dotfiles tree. **Never modify
anything under `ui-audit/`.**

---

## Invariants (must never weaken)

1. **Report-only.** This skill NEVER edits, writes or deletes application code, never commits,
   never runs mutating git. Its only writes are the run artifacts under `$OUT`.
2. **Never authenticate.** Never type a username, password, OTP or magic-link into anything.
   The harness measures whatever the debug Chrome profile can already see. If a route redirects
   to a sign-in page, that is a **finding to report**, not a problem to solve by signing in.
3. **Never touch the user's tabs.** The driver opens ONE fresh tab via `/json/new`, works only in
   it, and closes it (plus any popup that tab opened) on exit, including on SIGINT/SIGTERM.
4. **Destructive controls are never clicked.** Sign-in / sign-out / account controls are skipped in
   EVERY mode. A label matching the destructive denylist (delete, remove, send, cancel, confirm,
   pay, submit, approve, book, save, call, text, ...) is SKIPPED and logged with its reason. In
   default mode form submits, state toggles and unlabeled controls are skipped too.
5. **`--read-only` fails closed at the WIRE.** It installs ui-audit's `Fetch.enable` guard, which
   aborts EVERY non-GET before it leaves the browser. The text denylist is a *secondary hint
   only*, never the guarantee. Prefer `--read-only` on anything that is not disposable.
6. **Attribution must be earned, not assumed.** A layer only gets charged time the evidence
   supports. Tail time with no server wait, no transfer and no long task behind it is reported as
   `unattributed`, NOT as `client-render`. A mislabeled root cause sends the fixing agent to the
   wrong file, which is worse than saying "unknown".
7. **Timing honesty.** Every number in the report comes from CDP `Network.*` timing or in-page
   `PerformanceObserver`, in epoch ms so it survives a hard navigation. Nothing is estimated.

---

## Phase 0: Parse args, connect Chrome, pick the output directory

### 0a. Parse `$ARGUMENTS`

```bash
set -o pipefail
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

URL=""; BASE=""; ROUTES=""; OUT=""
READ_ONLY=false; COLD=false; RUNS=3
MAX_ROUTES=10; MAX_ACTIONS=15; PORT=9222; NO_CLICKS=false

eval set -- $ARGUMENTS

while [ $# -gt 0 ]; do
  case "$1" in
    --base=*)        BASE="${1#*=}"; shift ;;
    --base)          BASE="$2"; shift 2 ;;
    --routes=*)      ROUTES="${1#*=}"; shift ;;
    --routes)        ROUTES="$2"; shift 2 ;;
    --out=*)         OUT="${1#*=}"; shift ;;
    --out)           OUT="$2"; shift 2 ;;
    --runs=*)        RUNS="${1#*=}"; shift ;;
    --runs)          RUNS="$2"; shift 2 ;;
    --read-only)     READ_ONLY=true; shift ;;
    --cold)          COLD=true; shift ;;
    --no-clicks)     NO_CLICKS=true; shift ;;
    --max-routes=*)  MAX_ROUTES="${1#*=}"; shift ;;
    --max-actions=*) MAX_ACTIONS="${1#*=}"; shift ;;
    --port=*)        PORT="${1#*=}"; shift ;;
    --*)             echo "Error: unknown flag $1" >&2; exit 1 ;;
    *)               [ -z "$URL" ] && URL="$1" || { echo "Error: unexpected extra positional '$1'" >&2; exit 1; }
                     shift ;;
  esac
done

[ -z "$URL" ] && URL="$BASE"
[ -z "$URL" ] && { echo "Error: need a url (positional) or --base" >&2; exit 1; }
[ "$RUNS" -ge 1 ] 2>/dev/null || { echo "Error: --runs must be an integer >= 1 (got: $RUNS)" >&2; exit 1; }

TS="$(date -u +%Y%m%d-%H%M%S)"
[ -z "$OUT" ] && OUT="$WORKDIR/tmp/speedeval/$TS"
mkdir -p "$OUT"

echo "Parsed: URL='$URL' BASE='${BASE:-<none>}' ROUTES='${ROUTES:-<discover>}' RUNS=$RUNS READ_ONLY=$READ_ONLY COLD=$COLD OUT=$OUT"
```

**Choosing flags for the user (do this thinking, do not just pass through):**

- **`--read-only` is the default posture for any app with real data** (an admin panel, a booking
  system, anything with a customer's records behind it). Only omit it when the target is a public
  marketing site or a disposable environment, and say which you chose and why.
- **`--routes`**: pass the app's real routes when you know them (from the repo's `app/` tree or the
  user's list). Without it the harness measures the start URL and then crawls same-origin links it
  finds there, capped at `--max-routes` - fine for a public site, usually too shallow for an app
  whose nav is behind a client-side shell.
- **`--runs=3`** is the default and is what makes cold-vs-warm possible: run 1 is the first hit,
  runs 2..N give the warm median. `--runs=1` disables cold-start detection entirely.
- **`--cold`** disables the browser HTTP cache for every run. It measures a true first-time
  visitor. It does NOT force a *server* cold start - nothing can, from the client side.

### 0b. Connect the `:9222` debug Chrome

The driver talks to `http://127.0.0.1:9222` directly over raw CDP. It needs that endpoint healthy.
Inline the idempotent `/devtools` launch - do not assume anything self-connects.

```bash
DEBUG_PROFILE="$HOME/.chrome-debug-profile"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

cdp_healthy() {
  curl -s --max-time 4 "http://127.0.0.1:$PORT/json/version" 2>/dev/null | grep -q '"webSocketDebuggerUrl"'
}

if cdp_healthy; then
  echo "Debug Chrome healthy on :$PORT - $(curl -s --max-time 4 http://127.0.0.1:$PORT/json/version | grep -o '"Browser":"[^"]*"')"
elif [ -d "$DEBUG_PROFILE/Default" ] && [ -x "$CHROME" ]; then
  echo "Endpoint on :$PORT not responding - launching real-profile debug Chrome..."
  pkill -f -- "--user-data-dir=$DEBUG_PROFILE" 2>/dev/null || true
  sleep 1
  nohup "$CHROME" --remote-debugging-port=$PORT --user-data-dir="$DEBUG_PROFILE" \
    --restore-last-session >/dev/null 2>&1 &
  for i in $(seq 1 20); do cdp_healthy && break; sleep 1; done
  cdp_healthy && echo "Debug Chrome up on :$PORT" || echo "STILL DOWN - see Graceful degrade"
else
  echo "No debug profile at $DEBUG_PROFILE - run /devtools SETUP once, or see Graceful degrade"
fi
```

**Graceful degrade (headless fallback).** If the user's debug Chrome cannot be brought up, AND the
target is public (no login needed), launch a throwaway headless Chrome on a **different port with a
temp profile**, run against that, and **say so loudly in your final answer** - the numbers come from
a cold, extension-free, profile-less browser and will read faster than the user's real one:

```bash
ALT_PORT=9333; ALT_PROFILE="$(mktemp -d)/chrome"
nohup "$CHROME" --headless=new --remote-debugging-port=$ALT_PORT --user-data-dir="$ALT_PROFILE" \
  --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
for i in $(seq 1 20); do curl -s --max-time 2 http://127.0.0.1:$ALT_PORT/json/version >/dev/null && break; sleep 1; done
# ... then add --port=$ALT_PORT to the measure.mjs call below, and kill the browser afterwards.
```

Never fall back to headless for a route that needs the user's session - a headless temp profile has
no cookies, so it would measure the sign-in page and call it the app.

---

## Phase 1: Measure

One command does enumerate + click + time + classify + write. Run it in the foreground and let the
progress lines stream - they are your live view of what is being clicked.

```bash
LIB="$HOME/.claude-dotfiles/commands/speedeval/lib"
ARGS=(--url "$URL" --out "$OUT" --runs "$RUNS" --max-routes "$MAX_ROUTES" --max-actions "$MAX_ACTIONS" --port "$PORT")
[ -n "$BASE" ]   && ARGS+=(--base "$BASE")
[ -n "$ROUTES" ] && ARGS+=(--routes "$ROUTES")
$READ_ONLY       && ARGS+=(--read-only)
$COLD            && ARGS+=(--cold)
$NO_CLICKS       && ARGS+=(--no-clicks)

node "$LIB/measure.mjs" "${ARGS[@]}"
```

Budget roughly **(routes x runs x ~4s) + (actions x ~6s)**; a 10-route app with 3 runs and ~60
clicked actions takes 8-12 minutes. Never run two measurements against the same Chrome at once -
they contend for the main thread and both sets of numbers become fiction.

**Exit codes:** `0` ok - `2` usage error - `3` infrastructure (debug Chrome unreachable; go back to
0b or the headless fallback) - `1` anything else (report the stack trace, do not silently continue).

### What it measures (so you can explain the report)

**Per route navigation**, `--runs` times: TTFB, `responseEnd`, DOMContentLoaded, load, FCP, LCP
(+ the LCP element), CLS, request count, bytes, cached-request count, the slowest 5 requests each
with `dns / connect / ssl / send / wait / receive`, long tasks and total blocking time, and
specifically the **document / RSC / server-action request's `wait`** - request sent to first
response byte, i.e. **server + database time**, which is independent of the browser cache. Run 1 is
the cold hit; the median of runs 2..N is warm. Attribution headers (`server-timing`,
`cache-control`, `age`, `x-nextjs-cache`, `cache-status`, `cf-cache-status`, `x-vercel-cache`,
`x-nf-request-id`, ...) are captured verbatim on the document and on every slow request.

**Per click** (each click starts from a FRESH navigation of its route, plus a 100ms hover, so the
state is identical for every action and hover-prefetch has already had its chance, as it would for
a real user): time to the first network request, the main response's server `wait` vs `receive`
(download), time to DOM settle (MutationObserver quiet 300ms AND no inflight request AND, on a hard
navigation, `load` fired), whether ANY visible feedback appeared within 100ms (**the feels-dead
metric** - a DOM mutation, a busy indicator, or a URL change), soft-nav vs hard-nav vs no-nav, INP
from the Event Timing API, long tasks after the click, and a functional verdict.

**Functional verdict per action:** `PASS` (something real happened), `DEAD` (no navigation, no DOM
mutation, no request, no dialog - the button does nothing), `ERROR` (it worked but produced a
console error or an HTTP >= 400), `BLOCKED` (read-only aborted its non-GET, so no server timing),
`UNREACHABLE` (the element could not be re-found or is covered), `SKIPPED` (never clicked, with a
reason). "It works" is proven by mechanism, never by the label on the button.

---

## Phase 2: Read the report and hand it off

```bash
sed -n '1,120p' "$OUT/REPORT.md"
node -e "const r=require('$OUT/report.json');
  console.log('slowest:'); r.ranking.slowest.slice(0,10).forEach((x,i)=>console.log(' ',i+1,x.id,x.label,Math.round(x.totalMs||0)+'ms',x.dominantLayer));
  console.log('hypotheses:'); r.hypotheses.forEach(h=>console.log(' ',h.id,h.confidence,(h.worstMs||0)+'ms',h.affected.join(',')));"
```

Then, in your answer to the user:

1. **Name the top 10 slowest things with their dominant layer.** Route ids are `R*`, actions `A*`.
2. **Lead with the hypotheses, not the table.** `hypotheses[]` is already sorted by confidence then
   severity, and each one carries the evidence it was derived from plus its fix classes.
3. **Surface every caveat in `meta.caveats`** - especially a redirect to a sign-in page, which means
   the numbers describe the login screen and not the app.
4. **Say what was NOT measured**: skipped destructive controls, `over-max-actions`, unreachable
   elements. A speed report that hides its blind spots gets trusted more than it deserves.
5. **Print the handoff line** so a fixing agent can start from the artifact, not from your prose:

```
HANDOFF: speedeval baseline at <OUT>/report.json (+ REPORT.md).
Start at hypotheses[] (sorted by confidence), each has affected[] ids -> open those ids in
routes[]/actions[] for layers, evidence, per-phase request timings and response headers.
Schema: ~/.claude-dotfiles/commands/speedeval/README.md. Re-run the same command after the fix
wave and diff ranking.slowest[] + routes[].warmMedian to prove the improvement.
```

**Never propose or apply a code fix inside this skill.** Hand off to `/implement` or `/plan`.

---

## report.json contract (stable, v1.0)

Full field-by-field schema: `~/.claude-dotfiles/commands/speedeval/README.md`. The shape a consumer
can rely on:

```
{ schemaVersion, tool: "speedeval",
  meta:      { startedAt, finishedAt, durationMs, target, options, chrome, thresholds,
               firedNonGet[], blockedNonGet[], caveats[] },
  summary:   { routes, slowRoutes, actions, actionStatus{}, slowActions, feelsDead },
  routes:    [ { id:"R1", url, path, runs[], first{}, warmMedian{}, coldPenaltyMs{},
                 redirected, redirectedToLogin, slow, dominantLayer, layers{}, flags[], evidence[], totalMs } ],
  actions:   [ { id:"A1", routeId, routePath, kind, label, status, skipReason, timing{}, nav{},
                 requests{}, consoleErrors[], httpErrors[], blockedNonGet[], dialogs[],
                 slow, dominantLayer, layers{}, flags[], evidence[], totalMs } ],
  ranking:   { slowest[], byLayer{} },
  hypotheses:[ { id, layer, title, confidence, affected[], worstMs, evidence[], fixClasses[] } ] }
```

`dominantLayer` vocabulary (stable): `server-wait` | `network` | `client-render` | `waterfall` |
`cold-start` | `no-feedback` | `unattributed` | `none`.

Default thresholds (`meta.thresholds`, so a consumer never has to hardcode them): route slow at
LCP/load > 1500ms or document wait > 600ms; action slow at click -> settle > 500ms; feels-dead at
first feedback > 100ms; cold-start at first hit >= 2x warm median AND >= 300ms slower; waterfall at
a sequential chain of >= 3 requests.

---

## Known limits (state these, do not paper over them)

- **Server cold start cannot be forced** from the browser. `first vs warm` is a strong hint, not proof.
- **Third-party noise is in the numbers.** Analytics, chat widgets and video players run on the same
  main thread as the app, and their long tasks land in `client-render`. The `unattributed` layer
  exists to stop a self-animating widget from being reported as app render cost.
- **`settleMs` is quiet-based.** A page that mutates forever (carousel, ticker, live clock) never
  settles; those actions carry the `never-settled` flag and their total is a floor, not a duration.
  `noisy-dom-feedback-unreliable` marks a page that was already mutating *before* the click.
- **One click per element, one state.** The harness re-navigates before each click, so it never
  reaches a state that requires two clicks to enter, and it samples at most 2 list rows per route.
- **Read-only distorts what it protects.** Blocked non-GETs have no server timing at all, and
  `Fetch` interception adds roughly 1-3ms per request across the board.
- **A foreground tab is required for paint metrics.** The driver uses focus emulation, but if the
  OS backgrounds the whole browser, FCP/LCP can be late or missing; runs affected carry
  `tab-hidden-paint-metrics-unreliable`.
