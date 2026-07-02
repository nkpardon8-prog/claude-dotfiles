# Pass 2 — Dynamic Exercise (live browser x-ray, raw CDP)

You are running the **dynamic-exercise** pass of `/ui-audit`. Read `../rubric.md`
first — it is the source of truth for element types, the proof-of-real bar, the
four verdicts, and the precedence rules. This pass drives the LIVE app in the
`:9222` debug Chrome over **raw CDP** (Node global `WebSocket`, zero deps, the
`Runtime.evaluate` / `Network.*` / `Page.captureScreenshot` patterns from
`scripts/e2e/harness/{chrome,network,ui-observe}.mjs`). There is NO Playwright MCP
and NO chrome-devtools MCP — the orchestrator runs node CDP scripts and reads their
JSON; you consume that evidence and issue mechanism-grounded verdicts.

## Transport & driver facts (do not re-derive)
- Requests/bodies come from `Network.requestWillBeSent` / `Network.responseReceived`
  + `Network.getResponseBody`. Screenshots from `Page.captureScreenshot` → files.
- **The endpoint you evaluate against is derived from the OBSERVED network-on-mount**,
  NOT from a not-yet-run static trace (`rubric.md` §2 / the oracle is live-first).
  The static-trace `crossSourceHint`, when present, only tells you WHERE an
  independent source lives — it never supplies the display endpoint.
- State replay = a recorded text/aria descriptor re-resolved by an in-page query
  after a full nav reset (proven in assumption test A1). Esc-and-back is unreliable.

## The signal set (superset, aligned to dentall's `ui-observe.mjs`, T4)
The real observer (`scripts/e2e/harness/ui-observe.mjs`) emits exactly these signal
names; this pass adopts them as its vocabulary and defines the superset explicitly:

| Signal              | Meaning                                                        |
|---------------------|----------------------------------------------------------------|
| `networkResponse`   | a matching `{method, urlRegex, statusRange}` response arrived  |
| `toast`             | success/alert toast text appeared (Sonner/Radix/role=status)   |
| `url`               | `location.href` matched an expected route pattern              |
| `textPresent`       | expected text present (optionally within a selector, portal-aware) |
| `selectorAppears`   | an expected node appeared                                      |
| `selectorDisappears`| an expected node disappeared (e.g. "modal closes")            |
| `auth_lost`         | `location.pathname` hit `/login` mid-observe → abort fast      |

**Superset additions this pass defines on top of those names:**
- `networkOnMount` — the set of requests fired during initial tab mount, snapshotted
  BEFORE any interaction (the provenance channel, `rubric.md` §2b prong 1).
- `effectPersistsAfterRefetch` — after a mutating action returned 2xx, an INDEPENDENT
  refetch (fresh load / separate query) still shows the change (`rubric.md` §2a). This
  is the ONLY proof of an interactive effect.
- `crossSourceValue` — a value read from a DIFFERENT source than the display path
  (DB/Prisma or a canonical endpoint), for the value-honesty compare (§2b prong 2).

**Stability guard (mandatory for interactive):** mirror `ui-observe.mjs`'s
`stableForMs` re-check — a success cue that appears then vanishes before the real
response lands is optimistic-UI flicker, NOT success. A `toast`/`selectorAppears`
alone is never proof; it must be corroborated by `networkResponse` 2xx AND
`effectPersistsAfterRefetch`.

## Per-element-type mechanism rubric

### Interactive — `button`, `link`, `input`
Verify = **click/interact → 2xx → effect persists after an independent refetch**
(`rubric.md` §2a):
1. Snapshot network event index, interact, observe with a real timeout window.
2. Require a `networkResponse` in the 2xx range for the mutation/nav.
3. Perform an INDEPENDENT refetch and confirm `effectPersistsAfterRefetch`.
4. Verdicts: no request fired → dead click → `FAKE-OR-DEAD`. Request 4xx/5xx
   (unexpected) → `FAKE-OR-DEAD`. Toast/spinner only, no 2xx or no persistence →
   `FAKE-OR-DEAD` (optimistic-UI-only). All three met → `REAL`.
5. A `link`: require the `url`/route change or the data load it claims; nothing
   changes → `FAKE-OR-DEAD`.

### Data — `stat`, `table`, `badge`, `progress`, value-bearing `text`
Two prongs, both required for `REAL` (`rubric.md` §2b):
1. **Provenance:** the element's value must have a backing request in
   `networkOnMount`. NO backing request on mount → client-side static → the
   hardcoded-value catch → suspect (resolve per precedence below).
2. **Cross-source:** compare the displayed value to `crossSourceValue` from a
   DIFFERENT source (DB/Prisma or canonical endpoint). **Never re-fetch the display
   endpoint** — a stubbed/seeded/constant-returning endpoint would just re-confirm
   itself. **Normalize both sides first** (`"$85"`↔`85.0`, `"1,234"`↔`1234`, dates,
   case, whitespace) so formatting never yields a false `FAKE`.
   - displayed == cross-source (normalized) AND provenance present → `REAL`.
   - displayed ≠ cross-source (normalized) → mechanism (displayed ≠ canonical) →
     `FAKE-OR-DEAD`.
   - No independent source exists → `UNVERIFIED` with a note (never false-`REAL`).

### Chart — `chart`
Provenance as above: the series must come from a real fetched endpoint, not a
literal in-code array (`rubric.md` §2c). Series with no network-on-mount backing →
`FAKE-OR-DEAD` (or `STATIC-BY-DESIGN` only for an explicitly-labelled sample chart,
justified). Cross-source the series shape where an independent source exists; else
provenance-present is the minimum and the gap is noted.

### Asset — `image`
Broken/missing ⇒ `naturalWidth === 0` (DOM-measurable) → `FAKE-OR-DEAD`
(`rubric.md` §2d). Loads fine → `REAL`.

### Static / structural — `icon`, decorative `text`, `region`
No intended binding → `STATIC-BY-DESIGN` with justification (evaluated FIRST, §4b).
A `region` meant to hold content but showing zero child text where content is
expected → suspect empty-state, corroborated in the vision pass (`rubric.md` §2f).

## Precedence at verdict time (from `rubric.md` §4)
- **`STATIC-BY-DESIGN` is decided BEFORE convergence-to-FAKE** (§4b). A
  constant/icon/label with no intended binding, vision-confirmed as structural, is
  static-by-design — not fake.
- **Correlated-signal dedup (§4c):** "no network-on-mount" (this pass) and static's
  "no data binding" are the SAME signal. A bare constant does NOT become
  `FAKE-OR-DEAD` on those two alone — you need an INDEPENDENT second signal: a
  cross-source value mismatch, or a DOM-measurable vision corroborant. Absent it,
  the honest verdict is `STATIC-BY-DESIGN` (justified) or `UNVERIFIED`.
- `FAKE-OR-DEAD` always cites a concrete mechanism (dead click, 4xx/5xx, no
  network-on-mount for a value that claims to be dynamic, displayed ≠ cross-source,
  `naturalWidth===0`, literal-array chart). "Looks off" alone → `UNVERIFIED` (§4a).

## Traversal safety — full (default) vs `--read-only`
- **Full traversal (default):** the driver MAY click interactive elements to
  discover sub-states, and this MAY fire real mutations (POST/PUT/DELETE/send)
  against live data. **Every mutating (non-GET) request is logged to
  `traversal-actions.log`** with its request line, so all side effects are auditable
  after the fact. A loud pre-run banner already warned the operator.
- **`--read-only` fails closed at the WIRE:** CDP `Fetch.enable` aborts EVERY non-GET
  request before it leaves the browser. This is the guarantee. The start-anchored
  `DESTRUCTIVE_DENY` denylist (`Delete|Remove|Cancel|Break|Submit|Approve|Reject|
  Send|Finalize|Destroy`) is INSUFFICIENT on its own ("Save preferences" / "Confirm
  and Submit" leak past a start-anchored match), so it is a **secondary hint only,
  never the guarantee.** In `--read-only`, mutating controls are still ENUMERATED and
  verdicted via static + vision, but not exercised — absent a mechanism failure they
  resolve to `UNVERIFIED` (we did not prove the effect), never a false `REAL`.

## Evidence bundle (what you write per element)
Write a per-element evidence bundle into the `--out` dir (inside the repo, so Codex
can read it): `networkOnMount` list, any interaction's request/response lines +
status, the `crossSourceValue` + its source, the normalized compare result, the
observed signal(s), before/after screenshot paths, and the mechanism string. Codex
independently reads THIS bundle in the reconcile pass and issues its own verdict
(user decision #3) — so the bundle must stand on its own as evidence, not rely on
your prose. Emit your own verdict per element conforming to
`../lib/findings.schema.json` (`pass: "dynamic-exercise"`).
