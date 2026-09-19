# /speedeval - file map and `report.json` schema (v1.0)

`/speedeval` drives a real browser, clicks a web app's controls, times what the user waits for, and
attributes that time to a layer. The skill file (`../speedeval.md`) is a thin sequencer; everything
below is the substance it calls.

## Files

| File | Role |
| --- | --- |
| `../speedeval.md` | The skill: args, safety invariants, phases, handoff. |
| `lib/measure.mjs` | The driver. Connect -> enumerate routes + actions -> navigate N times -> click each action -> classify -> write. CLI entry point. |
| `lib/inpage.js` | The in-page probe, injected with `Page.addScriptToEvaluateOnNewDocument` so it is live before app code on every document. CommonJS (`module.exports = { source }`) so `node --check` parses it without a package.json. |
| `lib/classify.mjs` | Pure functions: numbers -> `layers` -> `dominantLayer` -> `ranking` -> `hypotheses` -> fix classes. No I/O. |
| `lib/report.mjs` | `report.json` -> `REPORT.md`. Also runnable alone: `node report.mjs path/to/report.json`. |

**CDP transport is reused, never rebuilt.** `measure.mjs` imports
`../../ui-audit/lib/cdp.mjs` for `openTab`, `assertEndpoint`, `installReadOnlyGuard` and
`installMutationLogger`. There is exactly one CDP client in this dotfiles tree. Do not add a second
one, and do not modify anything under `ui-audit/`.

## Run it directly

```bash
node ~/.claude-dotfiles/commands/speedeval/lib/measure.mjs \
  --url https://example.com --out /tmp/se-run --runs 3 --read-only
```

Flags: `--url` `--base` `--routes a,b,c` `--out` (both required: url + out) `--read-only`
`--include-destructive` (only with `--read-only`) `--runs N` `--cold` `--no-clicks`
`--max-routes N` `--max-actions N` `--deny <regex>` `--port N` `--settle-timeout ms`.
Exit: `0` ok, `2` usage, `3` infrastructure (debug Chrome unreachable), `1` fatal.
Progress goes to stderr; a one-line JSON summary goes to stdout.

## Clock and units

Every millisecond value is a duration in ms unless the field name ends in `Epoch` (absolute
`performance.timeOrigin + performance.now()`, which lines up with CDP `Network` `wallTime`). Epoch
timestamps are used so a measurement survives a hard navigation, where the page gets a new
`timeOrigin`. Route-run metrics (`ttfb`, `fcp`, `lcp`, `dcl`, `load`, `responseEnd`) are relative to
that run's navigation start, exactly as `PerformanceNavigationTiming` reports them.

## `report.json` schema, v1.0

### Top level

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | `"1.0"` | Bump on any breaking field change. |
| `tool` | `"speedeval"` | Producer. |
| `meta` | object | Run conditions and caveats. Read before trusting a number. |
| `summary` | object | Counts: `routes`, `slowRoutes`, `actions`, `actionStatus{STATUS:n}`, `slowActions`, `feelsDead`. |
| `routes` | array | One entry per measured route. |
| `actions` | array | One entry per enumerated interactive element (clicked or skipped). |
| `ranking` | object | `slowest[]` (routes + actions, one list, descending `totalMs`, top 25) and `byLayer{layer:{count,totalMs,ids[]}}`. |
| `hypotheses` | array | Root-cause hypotheses, sorted by confidence then severity. **Start here.** |

### `meta`

`startedAt` / `finishedAt` (ISO) / `durationMs`; `target{startUrl, origin, routesExplicit}`;
`options{readOnly, includeDestructive, runs, cold, clicks, maxRoutes, maxActions}`;
`chrome{browser, port}`; `thresholds{...}` (the values classification used - never hardcode these
downstream, read them); `firedNonGet[]` (non-GET requests that actually executed, side-effect audit,
default mode only); `blockedNonGet[]` (aborted at the wire, `--read-only` only);
`caveats[]` (**plain-English warnings that change how the numbers should be read** - a sign-in
redirect, a hidden tab, cache left on, and so on).

### `routes[]`

| Field | Meaning |
| --- | --- |
| `id` | `R1`, `R2`, ... Stable within a run; referenced by `ranking` and `hypotheses[].affected`. |
| `url` / `path` | Requested URL, and its path with id-looking segments collapsed to `:id`. |
| `finalUrl`, `redirected`, `redirectedToLogin` | Where it actually landed. `redirectedToLogin: true` means the numbers describe a sign-in page, NOT the app. |
| `runs[]` | One object per navigation (see below). `runs[0]` is the cold hit. |
| `first` | `runs[0]`'s headline metrics: `{ttfb, docWait, responseEnd, fcp, lcp, dcl, load, requests, bytes}`. |
| `warmMedian` | Median of the same metrics across runs 2..N. `null` when `--runs=1`. |
| `coldPenaltyMs` | `first - warmMedian` per metric. The cold-start size. |
| `slow`, `dominantLayer`, `layers`, `flags[]`, `evidence[]`, `totalMs` | Classification (below). |

**`routes[].runs[i]`** - `run` (1-based), `error` (null when fine), `requestedUrl`, `finalUrl`,
`title`, `visibility`; timings `ttfb`, `responseEnd`, `domInteractive`, `dcl`, `load`, `fcp`, `lcp`,
`lcpElement`, `cls`; `redirectCount`, `redirectMs`, `navigationType`, `protocol`, `serverTiming[]`;
volume `requests`, `bytes`, `cachedRequests`, `byType{Type:{count,bytes}}`; `document` (the main
document request, summarized - **`document.phases.wait` is server + DB time**); `serverRequests[]`
(top 5 RSC / server-action / API calls by server wait); `slowestRequests[]` (top 5 by duration);
`sequential{depth, chainMs, chain[]}`; `longTasks[]`, `longTaskMax`, `tbt`; `domNodes`, `viewport`;
`httpErrors[]`, `failedRequests[]`, `consoleErrors[]`.

**A summarized request** (used by `document`, `slowestRequests[]`, `serverRequests[]`,
`actions[].requests.slowest[]`, `actions[].timing.mainResponse`): `url` (redacted), `method`,
`type`, `kind`, `status`, `protocol`, `fromCache`, `fromServiceWorker`, `bytes`, `failed`,
`startEpoch`, `endEpoch`, `responseStartEpoch`, `durationMs`, `phases`, `headers`.

- `kind`: `document` | `server-action` (a `next-action` header) | `rsc` (an `rsc: 1` header or
  `?_rsc=`) | `prefetch` | `api` (XHR/fetch) | lowercased CDP resource type otherwise.
- `phases` (ms, exclusive, `null` when served from cache - a cached request has no wire timing):
  `stalled`, `dns`, `connect`, `ssl`, `send`, **`wait`** (request sent -> first response byte =
  **server + database**), `receive` (download), `reusedConnection`.
- `headers`: an allowlist only - `server-timing`, `cache-control`, `age`, `x-nextjs-cache`,
  `x-nf-request-id`, `cache-status`, `cf-cache-status`, `x-vercel-cache`, `etag`, ... Never
  `set-cookie`, never `authorization`. URLs are redacted: any query parameter whose name looks like
  a token / key / secret / code / session / signature / jwt has its value replaced with `REDACTED`.

### `actions[]`

| Field | Meaning |
| --- | --- |
| `id` | `A1`, `A2`, ... |
| `routeId`, `routePath`, `routeUrl` | The route the element was found on. |
| `kind` | `nav-link` \| `button` \| `tab` \| `toggle` \| `row` \| `menuitem` \| `hash-link`. |
| `label`, `selector`, `tag`, `role`, `href`, `inNav` | Identity, enough to find it again in the code. |
| `status` | `PASS` \| `DEAD` \| `ERROR` \| `BLOCKED` \| `UNREACHABLE` \| `SKIPPED`. |
| `skipReason` | Why it was never clicked: `destructive-text`, `session-or-account-control`, `external-link`, `self-link`, `opens-new-tab`, `download`, `disabled`, `form-submit`, `state-toggle`, `unlabeled-control`, `row-sample-cap`, `over-max-actions`, `non-http-link`, `bad-href`, `destructive-href`. |
| `note` | Prose detail for `UNREACHABLE` / `DEAD`. |
| `timing` | See below. `null` for `SKIPPED` / `UNREACHABLE`. |
| `nav` | `{urlBefore, urlAfter, type}` where type is `hard` \| `soft` \| `hash` \| `none`. |
| `requests` | `{count, bytes, slowest[], sequential{}}` for requests caused by the click. |
| `mutations` | DOM mutation records after the click (`null` on a hard nav - a new document). |
| `consoleErrors[]`, `httpErrors[]`, `blockedNonGet[]`, `dialogs[]`, `noisyDom` | Functional evidence. |
| `slow`, `dominantLayer`, `layers`, `flags[]`, `evidence[]`, `totalMs` | Classification (below). |

**`actions[].timing`**

| Field | Meaning |
| --- | --- |
| `t0Epoch`, `t0Source` | The click instant. `page-pointerdown` (stamped by the in-page probe, preferred) or `node-dispatch` (fallback, slightly earlier). |
| `timeToFirstRequestMs` | Click -> first network request. Large here = the handler did work before asking the server. `null` = the click caused no request at all. |
| `feedbackMs`, `feedbackKind`, `feedbackWithin100ms` | **The feels-dead metric.** First visible response of any kind: `dom-mutation`, `busy-indicator` (a skeleton/spinner/`aria-busy` was on screen), `url-change`, or `new-document-first-paint` on a hard nav. |
| `busyIndicatorSeen` | A real pending affordance existed, not just any mutation. |
| `mainResponse` | The request that the click was really waiting on: document > server-action > RSC > the API call with the longest wait. Adds `startMs`, `waitMs` (**server**), `receiveMs` (**download**), `responseStartMs`, `responseEndMs`, all relative to t0. |
| `settleMs`, `settled` | Click -> last activity (mutations quiet 300ms, no inflight request, and `load` fired on a hard nav). `settled: false` means the page never went quiet within the timeout - `settleMs` is then a floor. |
| `inpMs` | Event Timing: input -> next paint. The browser's own responsiveness number. |
| `longTaskTotalMs`, `longTaskMaxMs` | Main-thread blocking after the click. |

### Classification (`layers`, `dominantLayer`, `flags`, `evidence`)

`layers` splits the measured total into named causes, in ms. Routes:
`{budgetMs, serverWaitMs, networkMs, clientRenderMs, waterfallMs}`. Actions:
`{totalMs, serverWaitMs, networkMs, clientRenderMs, waterfallMs, unattributedMs}`.

`dominantLayer` is the biggest bucket, and drives `hypotheses` and `FIX_CLASSES`:

| Layer | Means | Fix direction |
| --- | --- | --- |
| `server-wait` | Request sent, browser waiting for byte one. Server + DB. | Query batching / N+1, indexes, server cache, streaming with Suspense, co-locate compute and DB. |
| `network` | DNS / connect / TLS / download / subresource transfer. | Compression, cache-control, CDN, smaller payloads, preconnect. |
| `client-render` | Main-thread work, backed by **observed long tasks**. | Code-split, memoize/virtualize, less hydration, move work off the handler. |
| `waterfall` | >= 3 strictly sequential requests. | Parallelize, combine endpoints, prefetch, hoist fetching. |
| `cold-start` | First hit >= 2x warm median AND >= 300ms slower; warm is fine. | Min instances, keep-warm, smaller bundle, edge runtime, pooled DB connections. |
| `no-feedback` | Fast enough, but nothing visible within 100ms. | Skeleton, optimistic UI, pending state, prefetch. |
| `unattributed` | Time passed with no server wait, no transfer and **no long task** to blame. Usually an animation, a media player or a polling widget still mutating the DOM. | Confirm with a trace before optimizing anything; it is often not user-perceived work at all. |
| `none` | Not slow. | - |

`unattributed` exists on purpose: charging an un-explained tail to `client-render` would send a
fixing agent hunting for render cost that is not there. A layer only gets time the evidence
supports.

`flags[]` (non-exhaustive): `cold-start`, `sequential-requests`, `long-tasks`,
`document-uncacheable`, `http-errors`, `console-errors`, `no-feedback`, `not-prefetched`,
`slow-interaction-to-paint`, `never-settled`, `noisy-dom-feedback-unreliable`, `unattributed-tail`,
`blocked-by-read-only`, `tab-hidden-paint-metrics-unreliable`, `all-runs-failed`.

`evidence[]` is human-readable strings carrying the exact numbers and response headers each verdict
was derived from, so a consumer can **check the reasoning instead of trusting the label**.

### `hypotheses[]`

`{id: "H-<layer>", layer, title, confidence: high|medium|low, affected: [ids], worstMs, evidence[],
fixClasses[]}`. Confidence is `high` when >= 3 items hit the layer and >= 2 have it as their
dominant layer, `medium` at >= 2 items, else `low`. `H-no-prefetch` is an extra cross-cutting one:
slow soft navigations whose data request only fired *after* the click.

## Consuming this as a fixing agent

1. Read `meta.caveats[]` first. A sign-in redirect or a hidden tab invalidates the rest.
2. Read `hypotheses[]` top-down. Each carries `affected[]` ids.
3. Open those ids in `routes[]` / `actions[]` for `layers`, `evidence`, per-phase request timings
   and response headers - that is where the file to change becomes obvious.
4. Fix. Then re-run the identical command and diff `ranking.slowest[]` and `routes[].warmMedian`.
   Same routes, same `--runs`, same cache mode, or the comparison is meaningless.
