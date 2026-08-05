---
description: "Arc Boats SMS re-engagement pipeline — pull a stale-lead list from HubSpot, vet every contact via the internal API (deals/DNC/opt-out/phone/30-day rule), and place short unsent drafts into the Salesmsg widget, one Chrome tab per contact, for Nick to review and send. DRAFT ONLY: never sends, never edits HubSpot."
argument-hint: "[batch size (default 20)] [states/regions] [extra instructions]"
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

## Environment / setup facts

- HubSpot portal **44031266**, team **SouthWest** (id 71073924). Dashboard "Arc Product Advisor";
  source report "SQLs/MQLs Last Contacted > 30D ago" (id 167965371) — its REAL filter is
  >7 days, so enforce the 30-day rule yourself. Report already excludes Lead status DNC/Unqualified.
- Salesmsg shared line "West" (213) 444-5717. Widget opens via the **"Launch Salesmsg Widget"**
  button on the contact record (right-rail CRM card). Compose field = contenteditable DIV,
  a11y name `TextInput_MessageField`, auto-focuses on load. Typed text auto-persists as a
  per-conversation draft (red "Draft:" in the list; survives tab close).
- Browser: debug Chrome on port 9222 via `/devtools`. The chrome-devtools MCP **crashes
  repeatedly** once ~15+ heavy HubSpot tabs exist — for batch work use **raw CDP from node**
  (Node 24 has built-in WebSocket). Proven scripts live in `commands/outreach/scripts/`:
  - `cdp-draft.mjs '<json>'` — [{id, first, msg}] → tab, launch widget, map conversation,
    name-check, empty-check, insertText, verify. Overwrites own prior "Hey ..." drafts only.
  - `precheck.mjs '<json ids>'` — re-vet immediately before drafting (deals, phone, opt_in,
    lead status, SMS today, customer date).
  - `final-verify.mjs '<json ids>'` — post-batch sweep: SENT_TODAY empty + every composer holds a draft.
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
  fallbacks in order: browser-endpoint `Target.getTargets` + flat session attach → reload tab
  and relaunch → precise mouse click on the "Write a message" line (45% width, ~92px above
  iframe bottom — NEVER lower, the icon/send row is ~55px above bottom) then page-level
  insertText + screenshot verify.

## Workflow

1. **Preflight**: `/devtools`; user logs into HubSpot (and Salesmsg auto-signs-in via the
   widget) if the migrated profile session expired. Confirm CSRF API access with one profile fetch.
2. **Pull the list**: open the report drill-down, 100 rows/page, harvest id|state|city rows
   (or apply the ephemeral state filter directly). Save to scratchpad.
3. **Geography filter** (default; user can override per run):
   - Nevada: EXCLUDE Tahoe basin — Reno, Incline Village, Stateline, Glenbrook, Carson City,
     Sparks, Minden, Gardnerville, Sun Valley. KEEP Las Vegas, North Las Vegas, Henderson, Boulder City.
   - Utah, Arizona: all cities.
4. **Vet everyone via API** (bulk, concurrency ~6): skip if any of — associated deal, no phone,
   lead status DNC/Unqualified, opt_in_status opted-out/Unsubscribed, became customer,
   SMS'd today, **last contacted <30 days ago** (compute from `max(last_contacted_date,
   last_sms_sent_date)`; the source report does NOT enforce 30 days, and Nick sends between
   batches so this MUST be re-checked immediately before drafting, not just at pool time).
   Log every skip with its reason.
5. **Pick the batch** (default cap 20, confirm with user): NV first if in scope, then
   Active engagement > Inactive > Unresponsive, SQL > MQL, most recent last-contact first.
6. **Re-vet the picks** with `precheck.mjs` immediately before drafting (things change fast).
7. **Draft** with `cdp-draft.mjs`. One tab per contact, left open for review.
8. **Verify** with `final-verify.mjs` + fix stragglers individually. Screenshot-verify anything
   that needed the coordinate-click fallback.
9. **Report**: counts drafted/skipped(+why), review-sheet path, warm replies spotted,
   remaining pool size for the next batch.

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

## Known false negative: the widget name-check

`cdp-draft.mjs` refuses to type unless the widget body shows the contact's first name. The
conversation pane can lag behind the iframe load, so a correct contact fails with "widget body
does not show contact first name". Do NOT weaken the guard. Re-run those contacts with a longer
name-wait (poll ~20x2s) plus triple identity proof: record-page `document.title` contains the
first name, iframe src contains `contact_integration_id=<id>`, and the conversation id matches
the record page's Salesmsg link. Only then insertText.

## Per-draft logic-test checklist

correct contact/tab pairing (record page name = widget header name) · state passes geography
rule · no associated deal · no DNC/opt-out · not a customer · >30d since last contact ·
no SMS today · phone on file · message passes style rules · composer text === intended draft ·
Send never touched.
