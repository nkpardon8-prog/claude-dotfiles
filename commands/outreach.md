---
description: "Arc Boats SMS re-engagement pipeline — ALWAYS opens with an intake (which report/list, campaign goal, message phrasing, and what to weigh in HubSpot; no defaults, samples approved before drafting), then vets every contact via the internal API (deals/DNC/opt-out/dead-number/30-day rule), reads their message history to tailor, and places short unsent drafts into the Salesmsg widget, one Chrome tab per contact, for Nick to review and send. DRAFT ONLY: never sends, never edits HubSpot."
argument-hint: "[report/list URL or name] [batch size (default 20)] [demo locations] [extra instructions]"
---

# /outreach — HubSpot → Salesmsg draft pipeline (Arc Boats)

Re-engage stale SQL/MQL leads by drafting SMS texts into the Salesmsg widget on each
HubSpot contact record. Built and battle-tested 2026-08-03 (3 batches, 60 drafts, 0 accidental
sends). The user reviews each tab and presses Send himself — the agent NEVER sends.

## Hard safety rails (non-negotiable)

1. **DRAFT ONLY.** Never click Send/Schedule, never press Enter inside a Salesmsg composer
   (Enter = send). Text goes in exclusively via CDP `Input.insertText` or `type_text` with no
   submit key. Never coordinate-click near the composer's bottom icon row (the send arrow
   lives there — a mis-click sends a real SMS to a real person).
2. **Never edit HubSpot**: no property writes, no notes, no list edits. Report drill-down
   view state (rows-per-page, ephemeral Advanced filters) is OK but always "Reset filters" after.
3. **Verify by mechanism** after every batch: re-read each composer (text === draft) AND
   API-check `last_sms_sent_date` != today for every drafted contact ("SENT_TODAY must be empty").
4. Field must be EMPTY before typing (or contain only our own prior draft when doing an
   approved rewrite — select-all + insertText replaces). Unexpected content → skip + log.
5. The user often sends batches WHILE the agent drafts the next one. Expect churn: tabs closing,
   replies arriving, `last_sms_sent_date` flipping to today for already-sent drafts. Flag warm
   replies to the user; never touch conversations with fresh inbound.
6. **No default lead source, no assumed copy, no assumed goal.** Never start from a remembered
   report, last run's wording, or anything in this file's reference list. Run the Step 0 intake
   (source, campaign goal, phrasing, HubSpot decision rules, run shape) and wait for answers.
   Guessing means real texts drafted to the wrong people saying the wrong thing. When proposing
   copy yourself, get 2-3 samples approved BEFORE drafting the batch.
7. **Never draft to a contact with a future demo already booked.** Check their engagement
   timeline for a `MEETING` type engagement with `metadata.startTime` in the future — a booked
   demo means the re-engagement ask is already answered; texting anyway is redundant and reads
   as sloppy. This is a hard API check (`FUTURE_DEMO:<date>` skip reason in `vet-pool.mjs` and
   `precheck.mjs`), not a judgment call — added 2026-08-12 after the user asked for it directly.
8. **Always read Notes on the contact and use them as context**, at both the pool-vet stage and
   the final pre-draft check. Notes carry real signal a property field won't show — e.g. "doesn't
   want a boat for a few years" (soft skip candidate, use judgment) or "came to check out the
   boat on lake Pleasant" (a tailoring hook). Both scripts surface the most recent note; read it
   before deciding to draft or how to phrase the message — don't just check for disqualifiers.

## Environment / setup facts

- HubSpot portal **44031266**, team **SouthWest** (id 71073924). Dashboard "Arc Product Advisor".
- **There is no default lead source. Always ask (see Step 0).** Sources used before, for
  reference only — do NOT assume any of them:
  - report "SQLs/MQLs Last Contacted > 30D ago" (id 167965371) — its REAL filter is >7 days, so
    enforce the 30-day rule yourself. Already excludes Lead status DNC/Unqualified. EXHAUSTED
    for NV/UT/AZ as of 2026-08-05.
  - list view "AZ For CC" (id 66215328) — EXHAUSTED as of 2026-08-06.
  - dashboard tile "Total MQL by owner" filtered to owner `__hs__ME` — 85 contacts, never
    harvested (chart tile, see Source types).
- Salesmsg shared line "West" (213) 444-5717. Widget opens via the **"Launch Salesmsg Widget"**
  button on the contact record (right-rail CRM card). Compose field = contenteditable DIV,
  a11y name `TextInput_MessageField`, auto-focuses on load. Typed text auto-persists as a
  per-conversation draft (red "Draft:" in the list; survives tab close).
- Browser: debug Chrome on port 9222 via `/devtools`. The chrome-devtools MCP **crashes
  repeatedly** once ~15+ heavy HubSpot tabs exist — for batch work use **raw CDP from node**
  (Node 24 has built-in WebSocket). Proven scripts live in `commands/outreach/scripts/`:
  - `lib-cdp.mjs` — shared helpers (`cdp`, `ev`, `hubTab`); every other script imports it.
  - `harvest-listview.mjs <viewId> [out]` — pull every member of a saved list view.
  - `vet-pool.mjs '<json ids>'` — bulk vet + rank. Writes `pool-vetted.json` / `pool-skipped.txt`.
  - `chains.mjs '<json ids>' [out]` — read recent SMS/call/note history for tailoring; prints a
    HARD STOPS / REPLIED / NEVER REPLIED digest.
  - `overlap.mjs '<json ids>'` — filter against the ledger of already-drafted + never-contact.
    Record after each batch: `node overlap.mjs --record '<ids>' "2026-08-06 batch9"`.
  - `precheck.mjs '<json ids>'` — re-vet immediately before drafting (deals, phone, opt_in,
    lead status, SMS today, customer date, dead number, 30-day rule).
  - `cdp-draft.mjs '<json>'` — [{id, first, msg}] → tab, launch widget, map conversation,
    name-check, empty-check, insertText, verify. Overwrites own prior "Hey ..." drafts only.
  - `check30.mjs '<json ids>'` — prints days since last contact per person; proves the 30-day floor.
  - `final-verify.mjs '<json ids>'` — post-batch sweep: SENT_TODAY empty + every composer holds a draft.
  - `/json/new` **requires PUT**, not GET, when opening a tab by URL.
- HubSpot **internal API** (from any app.hubspot.com tab; cookie auth + header
  `X-HubSpot-CSRF-hubspotapi` = value of `hubspotapi-csrf` cookie):
  - profile: `/api/contacts/v1/contact/vid/<id>/profile?portalId=44031266`
    key props: `firstname`, `hs_calculated_phone_number`, `hs_lead_status`, `opt_in_status`
    (Single/Unsubscribed — treat anything matching /out|unsub/i as opted out), `lifecyclestage`,
    `engagement_status`, `last_contacted_date`, `last_sms_sent_date`, `first_conversion_event_name`,
    `hs_v2_date_entered_customer`, `state`, `city`.
  - deals: `/api/crm-associations/v1/associations/<id>/HUBSPOT_DEFINED/4?portalId=...` (any result → skip)
  - timeline: `/api/engagements/v1/engagements/associated/contact/<id>/paged?limit=30&portalId=...`
- Report drill-down gotchas: rows-per-page menu is a real listbox (native clicks only);
  the drill-down silently **caps at 1000 rows** sorted ascending — recover the tail with an
  ephemeral Advanced filter (e.g. State/Region "is equal to any of" all spelling variants:
  arizona, az, nevada, nv, utah, ut), harvest, then **Reset filters**. Sort headers are
  `th[role=button]`, resistant to JS clicks.
- Widget iframe mapping: after load the iframe URL becomes
  `/widget-light/conversations/<convId>` (contact id is gone). Map contact → convId via the
  "View Conversation in Salesmsg" link on the record page. Contacts never texted have no such
  link — fall back to matching `contact_integration_id=<id>` in the iframe src. With ~20+
  widgets open Chrome consolidates iframe processes and some targets vanish from /json/list;
  fallbacks in order: browser-endpoint `Target.getTargets` + flat session attach → **close the
  tab and reopen the record fresh** (NOT `Page.reload`, see below) → precise mouse click on the
  "Write a message" line (45% width, ~92px above iframe bottom — NEVER lower, the icon/send row
  is ~55px above bottom) then page-level insertText + screenshot verify. Tab pressure is the
  root cause: past ~50 open tabs Chrome consolidates iframe processes and targets disappear.

## Source types (three, and they behave differently)

1. **Report drill-down** (e.g. "SQLs/MQLs Last Contacted > 30D ago", id 167965371): a real table.
   100 rows/page, silently caps at 1000 — see the drill-down gotchas above.
2. **Saved list view** (`/contacts/44031266/objects/0-1/views/<viewId>/list`, e.g. "AZ For CC"
   = 66215328): **virtualized and paginated**. Only rendered rows exist in the DOM, so you must
   scroll-loop until the id set stops growing, then click Next and repeat.
   Use `harvest-listview.mjs`.
3. **Dashboard chart tile** (e.g. "Total MQL by owner" with an owner quick-filter): the tile
   click opens a *chart*, not a contact table. The bar's `aria-label` gives the count
   ("Nicholas Pardon, 85") but clicking the bar did **not** yield a contact list in testing
   (2026-08-06, unresolved). If a chart tile is the only source, get the contacts another way:
   rebuild the same filter as a contact list view, or ask the user to save it as a list.
   Do not burn a session fighting the chart.

## Workflow

0. **INTAKE — ask before doing anything else. Every single run. Never guess, never reuse
   last run's answers.** Nick's lists, campaigns and copy change constantly; wrong assumptions
   here mean real texts drafted to the wrong people saying the wrong thing. Ask whatever he did
   not already state in the invoking message, then **confirm your understanding back to him in
   one short block and start only after that.** Batch the questions (`AskUserQuestion` takes up
   to 4 at a time; include the context % per the global rule) rather than interrogating him
   one at a time. Anything he already specified, do not re-ask — just reflect it back.

   **A. Source** (never assume; see the reference list above, all do-not-assume)
   - Which report, list view, or dashboard view? Ask for the URL or exact name.
   - Roughly how many people should this contain? A mismatch after harvesting means you got
     the wrong view or hit a pagination/1000-row cap — stop and re-ask rather than proceeding.

   **B. Goal of this campaign** — this drives the CTA and what counts as a good draft.
   - What is the ask? Book a demo, fill specific demo days, revive cold leads, push an
     inventory or pricing update, re-engage no-shows, something else.
   - Is there a deadline, event, or capacity behind it (dates opening, slots filling)? That
     changes urgency and whether a date belongs in the copy at all.
   - What does success look like — replies, booked demos, or just reopening the thread?

   **C. Message phrasing** — never invent this.
   - Does he have wording in mind, or should you propose it? If proposing, **show him 2-3
     sample drafts and get approval before drafting the batch.** Cheaper to fix one sample
     than 40 widgets.
   - Which demo locations, dates or offers should be named? Verify anything factual; never
     invent a location or date (arcboats.com/tour blocks bots, so ask rather than scrape).
   - Any phrasing to use or avoid this run, on top of the standing style rules below.
   - CTA verb and form: current default is "surf" and a question ending.

   **D. What to look for in HubSpot** — segmentation and decision rules beyond the standard vet.
   - Any property, lifecycle stage, lead status, engagement status, owner or tag that should
     include or exclude someone this run?
   - Geography rule for this run (default: NV excluding the Tahoe basin, plus UT and AZ).
   - Should message history change the copy? Default yes: never replied gets the template,
     a usable thread in the last 3 texts gets tailored. Confirm he still wants that.
   - Anything in notes, call summaries, or demo history to weigh — past demo attendance,
     no-shows, specific objections, boat model interest.
   - Anyone to hand-exclude beyond the automatic vetting.

   **E. Run shape**
   - Batch size (default 20; 40 works, split into two ~20 runs).
   - Leave prior tabs open, or is he done with them?
1. **Preflight**: `/devtools`; user logs into HubSpot (and Salesmsg auto-signs-in via the
   widget) if the migrated profile session expired. Confirm CSRF API access with one profile fetch.
   Check tab count — start a big batch under ~30 open tabs.
2. **Pull the list** per the source type above. Save to scratchpad.
2b. **Overlap guard**: run `overlap.mjs` over the harvested ids BEFORE vetting. Nick reuses and
   overlaps lists (the AZ list shared members with the report), and re-texting someone who
   already declined is worse than missing them. The 30-day rule catches anyone already *sent* to;
   the ledger catches people who have an unsent draft or said no.
3. **Geography filter** (default; user can override per run):
   - Nevada: EXCLUDE Tahoe basin — Reno, Incline Village, Stateline, Glenbrook, Carson City,
     Sparks, Minden, Gardnerville, Sun Valley. KEEP Las Vegas, North Las Vegas, Henderson, Boulder City.
   - Utah, Arizona: all cities.
4. **Vet everyone via API** (bulk, concurrency ~6): skip if any of — associated deal, no phone,
   lead status DNC/Unqualified, opt_in_status opted-out/Unsubscribed, became customer,
   SMS'd today, **last contacted <30 days ago** (compute from `max(last_contacted_date,
   last_sms_sent_date)`; the source report does NOT enforce 30 days, and Nick sends between
   batches so this MUST be re-checked immediately before drafting, not just at pool time).
   Also skip **dead numbers**: `last_sms_sent_status` matching /fail|undeliver/i means the
   carrier rejected the last text (found 2026-08-05 on a contact whose booked-demo reminder
   bounced). Re-texting is wasted; flag for a phone-number fix instead.
   Skip **junk first names** too (e.g. "Ddd", initials-only) — you cannot personalize them.
   Skip anyone with a **future demo already booked** (`MEETING` engagement, `metadata.startTime`
   in the future — `vet-pool.mjs`/`precheck.mjs` do this automatically, `FUTURE_DEMO:<date>`).
   Pull the most recent **Note** on every contact and read it — it's a hard signal (soft-decline,
   already-visited-a-demo, etc.) that no property field captures; both scripts surface it.
   Log every skip with its reason.
5. **Pick the batch** (default cap 20, confirm with user; 40 works fine, split into halves of
   ~20 per `cdp-draft.mjs` run): NV first if in scope, then Active > Inactive > Unresponsive,
   SQL > MQL, most recent last-contact first.
6. **Read the chains** with `chains.mjs` over the picks. This drives both tailoring and safety.
7. **Re-vet the picks** with `precheck.mjs` immediately before drafting (things change fast).
8. **Draft** with `cdp-draft.mjs`. One tab per contact, left open for review.
9. **Verify**: `confirm` pass (composer text === intended, per contact) then `final-verify.mjs`.
   Re-run stragglers individually. Screenshot-verify anything that used the coordinate fallback.
10. **Record** the batch into the ledger: `node overlap.mjs --record '<ids>' "<date> <label>"`,
   and anyone newly disqualified: `node overlap.mjs --record '<ids>' --never "<reason>"`.
11. **Report**: counts drafted/skipped(+why), review-sheet path, warm replies spotted,
   remaining pool size for the next batch.

## Tailoring from message history (what Nick asked for 2026-08-06)

Rule he gave: **never replied → cookie-cutter template. Something in the last 3 texts worth
building on → tailor it.** Keep tailored copy the same length and tone as the template; one
clause of personalization, not a rewritten message.

- The highest-value tailoring is **answering a question they actually asked and never got an
  answer to** ("Are you coming back to Lake Pleasant?", "Are you coming to Saguaro?",
  "Where are you doing the demos?"). Lead with the answer.
- Second best: **removing the obstacle they named** (had a scheduling conflict → "new dates
  opened up"; couldn't make morning slots → "we've got more than mornings now"; was traveling
  for work → "hope the travel wrapped up").
- Do NOT tailor from an outbound-only thread. Do not reference how long it has been or what
  campaign they came from. Forward-looking only, per the style rules.

**Hard stops — drop them from the batch and record them as `never`:**
explicit declines ("No", "Not interested", "can't afford", "won't work at that price point"),
wrong-number replies, and anyone whose note says wrong/fake number. `chains.mjs` flags likely
ones, but read them yourself; a human decides. Texting someone who already said no is the
worst failure mode this pipeline has.

**Also watch for:**
- **Duplicate contact records** for the same human (two records, different cities). Text one.
- **A pre-existing human-written draft** in the composer. `cdp-draft.mjs` refuses to overwrite
  anything that is not its own prior "Hey ..." draft and reports `field has unexpected text`.
  Read it, leave it alone, and surface it to Nick — it is probably his own work in progress.

## Message styling guide (Nick's rules — follow exactly)

- **No dashes, em dashes, or typical AI styling.** Run a literal `-`/`—` check on every draft.
- **No "been a minute"** — approved opener: "It's been a while since we last connected."
- **Forward-looking only. Do NOT reference old activities/past interactions** ("we talked about
  a factory tour a while back" is banned). A concrete past demo RIDE may be acceptable, but
  default to no callbacks.
- Short and sweet: 1-2 sentences + a question CTA, ideally 1 SMS segment, cookie-cutter across
  the batch. Goal is re-engagement, not a pitch.
- Nick's voice: "Hey {First}, it's Nick with Arc. ... Would love to get you out on the water."
- Region personalization is welcome but must be GROUNDED in real activity (the demo-west tour:
  Utah lakes, Lake Mead NV, Phoenix-area Southwest stops via info.arcboats.com/arc-sport-demo-west).
  **Never fabricate demo dates or locations** — arcboats.com/tour blocks bots, so verify stops
  with the user if a date is needed.
- **Name the actual demo locations** when Nick supplies them; they change per campaign and he
  will tell you which. Run them as a plain list, no dashes: "We're bringing the Sport out to
  Havasu, Saguaro and Pleasant." (2026-08-05 run used Havasu, St George, Lake Mead, Park City,
  Phoenix; 2026-08-06 used Havasu, Saguaro, Pleasant.) Never invent a location or a date.
- Approved templates:
  - Generic: "Hey {First}, it's Nick with Arc. It's been a while since we last connected.
    Still thinking about the Sport? Would love to get you out on the water for a ride."
  - Utah: "... We've had the Sport out on lakes across Utah this summer. Still interested?
    Would love to get you out for a surf."
  - Arizona: "... The Sport has been out across the Southwest this summer and the Phoenix area
    is on our list. Want me to line you up for a surf?"
  - Arizona outside Phoenix metro (e.g. Tucson): "... We're kicking up demos in AZ soon.
    Still interested? Would love to get you out for a surf."
- **"surf" beats "ride"** as the CTA verb (Nick's call 2026-08-05): "get you out for a surf",
  "line you up for a surf". Also banned: "we're getting Arizona folks on the water" — say what
  Arc is DOING ("we're kicking up demos in AZ soon"), not what the customer is a member of.

## NEVER reload a record tab to fix a widget

`Page.reload` on a contact record drops the Salesmsg widget's auth: it re-renders as a bare
**"Sign in"** screen with no conversation and no composer, and a coordinate click then lands on
the page body (focus reads BODY) instead of the iframe. Do NOT click that Sign in button.
The fix is to **discard that tab and reopen the contact record fresh** so the widget inherits the
already-authenticated Salesmsg session from the profile. Safe to close because a signed-out
widget by definition holds no draft — verify that first (no
`widget-light/conversations/<convId>` target exists for it), then close and re-run `cdp-draft.mjs`,
which creates a new tab. Prefer this over the coordinate fallback whenever a reload has happened.

## Known false negative: the widget name-check

`cdp-draft.mjs` refuses to type unless the widget body shows the contact's first name. The
conversation pane can lag behind the iframe load, so a correct contact fails with "widget body
does not show contact first name". Do NOT weaken the guard. Re-run those contacts with a longer
name-wait (poll ~20x2s) plus triple identity proof: record-page `document.title` contains the
first name, iframe src contains `contact_integration_id=<id>`, and the conversation id matches
the record page's Salesmsg link. Only then insertText.

## Per-draft logic-test checklist

correct contact/tab pairing (record page name = widget header name) · not already drafted and
not in the never-contact ledger · never explicitly declined or replied wrong-number · not a
duplicate of another record in the same batch · state passes geography rule · no associated
deal · no DNC/opt-out · not a customer · live phone (no undelivered status) · >30d since last
contact · no SMS today · real first name · message passes style rules (no dashes, no
"been a minute", forward-looking, real locations only) · composer was empty or held only our
own prior draft · composer text === intended draft · Send never touched.

## Scale reference (what a real run looks like)

229 drafts across 10 batches, 2026-08-03 to 08-06, zero accidental sends. A 20-batch takes
roughly 15 minutes of drafting plus vetting; a 40-batch splits into two runs. Expect 1-3
stragglers per 20 from iframe-target churn — the fallback chain recovers them. Vetting
routinely disqualifies 30-50% of a raw list (Unqualified lead status, open deals, missing or
dead phones, contacted <30d), so a "166-member list" is realistically ~84 textable people.
