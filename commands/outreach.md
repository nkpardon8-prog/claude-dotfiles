---
description: "HubSpot → Salesmsg draft pipeline (Arc Boats), built to be handed to any teammate safely. First run per person: a one-time onboarding (identity, voice, a HubSpot map) saved to native memory, never repeated. Every run: MANDATORY interactive intake before any devtools/HubSpot access — data source, campaign goal, message content (your template or approved samples), which HubSpot fields/signals to weigh, and targeting, all asked explicitly, nothing defaulted. Then it vets every contact via the internal API, reads message history to tailor, and places short unsent drafts into the Salesmsg widget, one Chrome tab per contact, for the user to review and send. DRAFT ONLY: never sends, never edits HubSpot."
argument-hint: "[report/list URL or name] [batch size (default 20)] [demo locations] [extra instructions]"
---

# /outreach — HubSpot → Salesmsg draft pipeline (Arc Boats)

Re-engage stale SQL/MQL leads by drafting SMS texts into the Salesmsg widget on each
HubSpot contact record. Built and battle-tested 2026-08-03 through 08-12 (12 batches, 261
drafts, 0 accidental sends). The user reviews each tab and presses Send themself — the agent
NEVER sends. Designed to be run by anyone on the team, not just its original author — see
Step 0 below, which exists specifically so a new teammate never has to know any tribal
knowledge to run this safely.

## Hard safety rails (non-negotiable — these do not change per user or per run)

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
6. **No default lead source, no assumed copy, no assumed goal, no assumed vetting criteria,
   no assumed targeting.** Every one of those is asked fresh in Step 0, every run, regardless
   of who is running it or what a past run used. Guessing means real texts drafted to the wrong
   people saying the wrong thing. (The one deliberate exception: onboarding identity/voice —
   see the Onboarding section — persists per person and is never re-asked once captured.)
7. **Never draft to a contact with a future demo already booked.** Check their engagement
   timeline for a `MEETING` type engagement with `metadata.startTime` in the future — a booked
   demo means the re-engagement ask is already answered; texting anyway is redundant and reads
   as sloppy. This is a hard API check (`FUTURE_DEMO:<date>` skip reason in `vet-pool.mjs` and
   `precheck.mjs`), not a judgment call.
8. **Always read Notes on the contact and use them as context**, at both the pool-vet stage and
   the final pre-draft check. Notes carry real signal a property field won't show — e.g. "doesn't
   want a boat for a few years" (soft skip candidate, use judgment) or "came to check out the
   boat on lake Pleasant" (a tailoring hook). Both scripts surface the most recent note; read it
   before deciding to draft or how to phrase the message — don't just check for disqualifiers.
9. **This is a shared team tool.** Never assume the previous runner's source, copy, style, or
   targeting rules apply to this run, even if it's the same person five minutes later. Step 0
   below is the enforcement mechanism for this — it is not optional, and it is not a formality
   to rush through.

## Automated setup (the agent runs this silently, before Step 0 — no user questions needed here)

This whole skill folder must travel as one unit: `outreach.md` + `scripts/*.mjs` +
`memory/style-prefs.json`, all under `commands/outreach/`. If you were handed only this `.md`
file, stop and tell the user the companion `scripts/` and `memory/` folders are missing — the
whole package is needed, not just this file.

Run these checks automatically, in order, before Step 0 begins. Fix what's fixable; only
surface a question if it genuinely needs a human (e.g. logging into HubSpot):

1. **Node.** `node --version` — need 18+ (raw CDP scripts use the built-in `WebSocket`; 20+
   preferred). If missing or too old, tell the user to install a current Node and stop here.
2. **Scripts present.** Confirm all 9 files exist in `commands/outreach/scripts/`: `lib-cdp.mjs`,
   `harvest-listview.mjs`, `vet-pool.mjs`, `chains.mjs`, `overlap.mjs`, `precheck.mjs`,
   `cdp-draft.mjs`, `check30.mjs`, `final-verify.mjs`. Missing files mean an incomplete copy —
   stop and say so; do not try to recreate them from memory.
3. **Memory file present.** Confirm `commands/outreach/memory/style-prefs.json` exists; if not,
   create it as `{"entries": []}`. Nothing to migrate on a first run.
4. **Debug Chrome.** Run `/devtools`. If its one-time profile migration hasn't happened on this
   machine yet (no `~/.chrome-debug-profile`), that skill self-detects and walks through it —
   follow it once per machine, then continue.
5. **HubSpot + Salesmsg session live.** Confirm a HubSpot tab is logged in, and that one
   contact record's "Launch Salesmsg Widget" opens a real conversation pane, not a bare
   "Sign in" screen. If it doesn't, ask the user to log in, then re-check — this is the one
   step that can't be automated around.

Once all five pass, proceed to Step 0.

## Browser automation: which tool to use, and why

Three ways to drive the browser exist. They are not interchangeable — pick by the phase of
work, not habit.

- **Raw CDP via the Node scripts (`scripts/*.mjs`)** — the proven path for anything touching
  more than a couple of contacts. Every drafting batch, vetting pass, and verification sweep in
  this skill runs on this. It's the only method tested at real batch scale (10-50+ contacts,
  100+ open tabs) and the only one with the iframe-target-churn fallback chain built in.
  **Default to this for Workflow Steps 2 through 10, no exceptions.**
- **`chrome-devtools` MCP** — fine for Automated-setup-era checks (confirm login, open one tab,
  grab a single screenshot or console message) and for debugging ONE contact's widget mid-batch.
  **Do not use it to drive a real drafting batch** — it repeatedly crashes once ~15+ heavy
  HubSpot tabs are open (a `Promise.all` page-enumeration hang; see the `/devtools` skill's own
  notes). If you catch yourself looping `mcp__chrome-devtools__*` calls over a contact list,
  stop and switch to the Node scripts.
- **`playwright` MCP** — an acceptable substitute for `chrome-devtools` MCP on the same
  small-scale uses if `chrome-devtools` isn't connected. Same rule: never the driver for a real
  batch. Handy as an independent second check when screenshot-verifying a coordinate-click
  fallback draft, since it's a separate code path from the raw-CDP screenshot already used to
  verify it.
- If none of the three are available or connected, that's a setup gap, not a workflow decision —
  go back to Automated setup, run `/devtools`, and retry before doing anything else.

## Onboarding (first time only, per person — uses your platform's memory system, not a repo file)

Runs once per person, ever — not once per run, not once per repo clone. This is the one
deliberate exception to hard rail #6 ("never assume, always ask fresh"): identity and voice are
meant to persist; per-run specifics (source, goal, targeting) still get asked every time in
Step 0 regardless of what onboarding captured.

**Use your own persistent memory system for this** — the cross-session memory mechanism your
environment provides you, if you have one — never a file inside this repo. That keeps each
person's profile correctly scoped to their own account, and nowhere near this git repo (which
may be public). If you have no memory system available in this environment at all, say so
plainly and skip onboarding entirely — fall back to asking what you need inline during Step 0
each run rather than blocking the tool on a foundation that doesn't exist here.

**Check first, before asking anything.** Look for an existing memory entry from a prior
`/outreach` onboarding — search for something named/described like "outreach onboarding" or
"Arc Boats outreach user profile." If found, **load it silently and do not re-ask any of it** —
go straight to Step 0. Never run this interview twice for the same person.

**If not onboarded, run this interview once:**

1. **Identity**: full name, and role (what they actually do — sales rep, regional manager,
   etc.).
2. **Hobbies / interests**: for calibrating tone and rapport in *their* drafts, not for
   mentioning to leads. A surfer and a numbers-first closer write differently — this is about
   making drafts sound like this specific person instead of generic AI copy.
3. **Writing voice**: ask directly — *"Want to paste a few texts or emails you've actually
   sent, so I can match your voice? Or, if HubSpot's already connected, I can pull a handful of
   your own recent outbound SMS as samples instead."* Either way, distill what you're given
   into a few concrete voice notes (sentence length, formality, recurring phrases, things they
   never say) rather than storing walls of raw text.
4. **Anything else that shapes tailoring**: typical CTA style, whether they always sign off
   with their name, phrasing or topics to avoid, their usual demo circuit/region — anything
   Step 0 would otherwise have to ask fresh every single run.
5. **A first HubSpot map** (below) — part of the same onboarding pass, not a separate ask.

Save the result as a **`user`-type** memory (role/hobbies/voice/preferences) via your memory
system's normal save contract. Name it clearly (e.g. `outreach_user_profile`) so it is easy to
find and update later, and so it never collides with unrelated memories from other work this
person's account has done.

### First HubSpot map (part of onboarding, then kept current over time)

Ask: *"What are the lists, reports, and dashboards you use most for outreach like this?"*
Capture name + URL/id + what each is for. If HubSpot is already connected (`/devtools` has run),
do one light live pass — open the Lists and Reports/Dashboards pages, screenshot, and use that
to jog their memory or confirm ids. Best effort, not a full crawl of the portal.

Save this as a **`reference`-type** memory (e.g. `outreach_hubspot_map`) — portal id, team id,
Salesmsg line, and the lists/reports/dashboards named, each with what it's for. Never store
credential values or session tokens in it — structure and purpose only, same as everywhere else
in this skill.

**Keep it current, not static.** After every future run, if Step 0.1's data source isn't
already in the map, add it — name, id, date first used — by updating the existing memory entry
in place. Never create a duplicate entry and never drop what's already there. Over enough runs
this becomes a real map of how this person actually works in HubSpot, grown from what they've
actually used rather than a one-time guess.

**6. Print the welcome guide.** Immediately after saving the profile (once, right after
onboarding — never on a returning run), print the full text under "Welcome guide for new
users" further down this file, verbatim, as a normal chat message. This skill is written for
someone comfortable with AI tools; a lot of the people who'll actually run this are not, and
that message is their entire manual. If this section got truncated out of your context by a
compaction, Read this file from disk for the exact text rather than paraphrasing it from
memory — the whole point is that a non-technical user gets something consistent and reliable,
not a summary. Reprint the same guide, verbatim, any time the user later asks something like
"how does this work," "help," or "what can I say to you."

## Step 0 — Mandatory intake gate (complete before touching devtools, Chrome, or HubSpot)

**Do not call `/devtools`. Do not open a HubSpot tab. Do not make a single API call. Do not
read any file for "reference" purposes beyond this skill file itself.** Everything below must
be answered, and the summary confirmed back, before Workflow Step 1 begins. This gate is what
makes the skill safe to hand to a teammate who has never run it before and has none of the
context baked into anyone's head — nothing here is assumed, remembered, or defaulted.

Ask in batches via `AskUserQuestion` (up to 4 questions per call; always include the current
context % per the global rule). If the invoking message already answered something, reflect it
back instead of re-asking it — but never silently fill an unanswered gap with a guess, a past
run's value, or anything from a memory file. If any answer is ambiguous, ask a follow-up rather
than interpreting it generously.

**1. Data source — always required, never assumed, never reused.**
- Which HubSpot report, list view, or dashboard should this batch pull contacts from? Get the
  exact URL or the exact saved name.
- Roughly how many contacts should it contain? If the harvested count is wildly different from
  that expectation, stop and re-confirm before vetting anything further — a mismatch means you
  probably have the wrong view, or hit a pagination/1000-row cap, not a green light to continue.

**2. Campaign goal.** This drives what counts as a good draft and what the CTA should be.
- What's the ask — book a demo, revive cold leads, announce new dates or locations, fill
  specific demo slots, win back a no-show, something else entirely?
- Any deadline, event, or capacity behind it (dates opening, slots filling) that should shape
  urgency, or that a date/location belongs in the copy at all?
- What does a successful run look like — replies, booked demos, or just reopening dead threads?

**3. Message content — get a template, or show samples and get feedback. Never invent copy
silently.**
- Ask directly: *"Do you have exact wording you want used, or should I propose some options?"*
- **If they have wording**: capture it verbatim. Confirm the personalization token (usually
  `{First}`) and any location/date/offer detail that needs to vary per contact — verify anything
  factual rather than inventing it (arcboats.com/tour blocks bots, so ask rather than scrape).
- **If they want options proposed**: first read `commands/outreach/memory/style-prefs.json`
  (see the Style memory section below) AND this person's `outreach_user_profile` memory (see
  Onboarding above) if they have one — voice notes from onboarding should shape the samples as
  much as the team's shared style log. Summarize both as your starting point — this makes the
  proposal smarter without skipping confirmation. Then show 2-3 sample
  drafts before drafting a single real message to a real contact. Ground the samples in the
  stated goal. The style examples later in this file (Nick's historical rules) are a reasonable
  fallback starting point when memory is empty, not a rulebook a different user is bound to —
  present them as suggestions. Ask explicitly for feedback — approve as-is, edit, or reject —
  and do not proceed to a real batch until you get a clear yes. Once approved, append what was
  learned to `style-prefs.json` (see Style memory below) so the next run starts smarter.
- Either way, confirm the **style constraints** for this run: dashes/em-dashes okay or not,
  tone (casual vs. formal), a length limit, banned phrases, anything that reads as AI-generated
  to avoid. Offer Nick's historical defaults (no dashes, no "been a minute", forward-looking
  only, "surf" not "ride" as the CTA verb) as a strong suggestion, but confirm rather than assume
  a different teammate or campaign wants the same voice.

**4. HubSpot fields to weigh — confirm the checklist, don't silently assume it applies.**
Show the user the standard vetting checklist this pipeline runs by default, and ask whether it
should change for this run:
  - Associated deal (skip if any exist)
  - Phone number on file (skip if none)
  - Opt-in / DNC / unsubscribed status (skip if opted out)
  - Lead status (skip if Unqualified/DNC)
  - Became-customer date (skip if already a customer)
  - SMS already sent today (skip — avoid a same-day double text)
  - Days since last contact — default floor 30 days (confirm the number for this run)
  - Dead/undeliverable number history (skip)
  - Future demo/meeting already booked (skip — hard rail #7, always on)
  - Most recent Note (always read, always used as context — hard rail #8, always on)

  Ask: *"Use this checklist as-is, or add/remove/change anything — a different day threshold,
  an extra property to check, a lifecycle stage to include or exclude?"*

**5. Targeting — what and who this run is actually for. Ask fresh; do not reuse a past answer.**
- What's the target audience for this batch — which states, cities, or regions; which lifecycle
  stage or lead status; anyone to explicitly exclude (e.g. a different office's territory, a
  market not currently served)?
- Any exclusion zone *within* a broader area? (Nick's example: Nevada minus the Tahoe basin,
  because that's a different regional office's territory — offered as an example of the kind of
  answer needed, not something to assume carries over to this run, this state, or this product.)
- Should message history change the copy — never-replied gets the template, a usable thread in
  the last 3 texts gets lightly tailored? Confirm this is still wanted for this run.
- Anyone to hand-exclude beyond what the automatic vetting will catch.

**6. Run shape.**
- Batch size (default suggestion 20; 40+ works but splits into two runs of ~20 each via
  `cdp-draft.mjs`).
- Leave prior open tabs alone, or is the user done with them (safe to let old ones sit either
  way — never close a tab that might hold someone else's unsent draft without checking first)?
- Stop condition: stop at the batch cap, or stop when the qualified pool runs out — whichever
  is smaller. If the qualified pool is far short of the requested batch size, say so plainly
  before drafting anything (do not silently loosen the Step 0.4 checklist to hit a number).

**Close Step 0** by reading the full intake back in one short, concrete block — e.g. "Source: X
(~N contacts). Goal: Y. Message: [samples/template]. Vetting checklist: as-is / modified how.
Targeting: Z. Batch cap: N, stop at exhaustion or cap." — and wait for explicit confirmation
before Workflow Step 1 begins. If nothing else in the run changes anyone's mind, this is the
one step that must never be skipped or rushed, for any user.

<!-- CONTRACT-CORE-END -->

**Truncation note:** this file re-injects head-truncated to its first 20,000 characters after a
context compaction. Everything above this line — Hard safety rails, Automated setup, Browser
automation guidance, and the full Step 0 intake gate — is self-sufficient to run this skill
safely. Everything below (script reference, Workflow execution detail, tailoring rules, style
memory mechanics, style examples, known gotchas, the per-draft checklist) is real operational
detail Workflow Steps 1+ depend on — if it's missing from this turn's context, Read
`~/.claude-dotfiles/commands/outreach.md` from disk before proceeding past Step 0.

## Welcome guide for new users (print verbatim, per the Onboarding section's step 6)

Print this exact text as a normal chat message — no jargon added, no paraphrasing, no
technical asides. Fill in `{Name}` from onboarding; leave everything else as written. This is
written for someone who has never used an AI tool before and doesn't want to have to learn one.

> **Hi {Name} — here's everything you need to know to use this. No tech background required.**
>
> **What this does, in plain terms.** This helps you write personalized text messages to leads
> in HubSpot and gets them ready to send in Salesmsg. You review every single message before it
> goes out — nothing is ever sent automatically. Think of it as a fast, careful assistant who
> drafts your texts and lines them up for your approval.
>
> **How to start.** Just tell me in plain English what you want. For example:
> - "I want to text my Arizona leads about the new demo dates."
> - "Let's follow up with people we haven't reached in a while."
> - "Run another batch of 20."
>
> You don't need to remember any commands. If you want to be precise you can also just say
> "Run outreach" and I'll ask you everything I need to know.
>
> **What happens when you run it:**
> 1. I'll ask a few questions — which contacts, what the message should say (or I'll suggest
>    some for you to approve), and roughly how many people. I won't do anything until you answer.
> 2. I'll show you sample messages first and wait for your okay before writing anything for real.
> 3. I'll check every contact against your rules (skip anyone with a deal already going, anyone
>    who opted out, anyone texted too recently, anyone who already has an appointment booked) so
>    you don't have to think about that part.
> 4. I'll open a browser tab for each person with their message already typed in, ready for you
>    to look at.
> 5. You review and hit Send yourself, one at a time, whenever you're ready. I never click Send.
>
> **Where to find your drafts.** After a batch finishes, look at your open Chrome tabs — each
> one is a different contact's HubSpot page with their text already sitting in the box, unsent.
> Read it, change it if you want, and press send yourself.
>
> **Things you never have to worry about:**
> - I will never send a text without you personally pressing send.
> - I will never change anything in HubSpot itself — no edited contacts, no deleted notes, no
>   changed lists.
> - I will never text someone twice, or someone who already said no, or someone who already has
>   an appointment booked — that's tracked automatically.
>
> **If something looks wrong or confusing**, just say so — "that doesn't look right," "stop,"
> "wait, why did you do that" all work fine. You're always allowed to pause or ask questions.
> Nothing bad happens if you stop partway through a batch — nothing sends unless you send it.
>
> **Common things to say:**
> - "Do another batch of 20"
> - "Only text people in [state/city]"
> - "Use this exact wording: ..."
> - "Stop for now, I'll finish reviewing these first"
> - "Don't text [person] again"
>
> **The first time only,** I asked about your name, role, and writing style — that's saved and I
> won't ask again. Every time after today, we go straight to planning the actual batch.
>
> **If something breaks** — Chrome doesn't open, HubSpot asks you to log in, or I seem stuck —
> just tell me and I'll walk you through it. It's always safe to say "stop"; nothing sends
> itself, so there's no risk in pausing.
>
> Ask me "how does this work" any time you want to see this again.

## Environment / setup facts

- HubSpot portal **44031266**, team **SouthWest** (id 71073924). Dashboard "Arc Product Advisor".
- Prior sources used before, kept here **for reference only — never assume any of them, always
  run Step 0**:
  - report "SQLs/MQLs Last Contacted > 30D ago" (id 167965371) — its REAL filter is >7 days, so
    enforce whatever day threshold Step 0 confirmed yourself. Already excludes Lead status
    DNC/Unqualified. EXHAUSTED for NV/UT/AZ as of 2026-08-05.
  - list view "AZ For CC" (id 66215328) — EXHAUSTED as of 2026-08-12.
  - list view id 66412328 (NV/Vegas-area) — EXHAUSTED as of 2026-08-12.
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
  - `vet-pool.mjs '<json ids>'` — bulk vet + rank against the Step 0.4-confirmed checklist
    (deals/phone/opt-in/lead-status/customer/SMS-today/day-threshold/dead-number/future-demo),
    plus always fetches the most recent Note. Writes `pool-vetted.json` / `pool-skipped.txt`.
  - `chains.mjs '<json ids>' [out]` — read recent SMS/call/note history for tailoring; prints a
    HARD STOPS / REPLIED / NEVER REPLIED digest. The STOP-phrase regex is a hint, not a gate —
    always read the digest yourself; it has missed real hard stops before (hostile replies
    phrased outside its pattern list).
  - `overlap.mjs '<json ids>'` — filter against the ledger of already-drafted + never-contact.
    Record after each batch: `node overlap.mjs --record '<ids>' "2026-08-12 batch-label"`.
  - `precheck.mjs '<json ids>'` — re-vet immediately before drafting against the same checklist
    (things change fast; the user often sends between batches).
  - `cdp-draft.mjs '<json>'` — [{id, first, msg}] → tab, launch widget, map conversation,
    name-check, empty-check, insertText, verify. Overwrites own prior "Hey ..." drafts only.
  - `check30.mjs '<json ids>'` — prints days since last contact per person; proves the
    confirmed day-threshold floor was actually respected.
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
  - timeline: `/api/engagements/v1/engagements/associated/contact/<id>/paged?limit=40&portalId=...`
    (SMS, CALL, NOTE, and MEETING engagement types all live here — MEETING carries
    `metadata.startTime`/`endTime` for the future-demo check, NOTE carries `metadata.body`).
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
  root cause: past ~50 open tabs Chrome consolidates iframe processes and targets disappear;
  it gets materially worse past ~150 (observed live 2026-08-12).

## Source types (three, and they behave differently)

1. **Report drill-down** (e.g. "SQLs/MQLs Last Contacted > 30D ago", id 167965371): a real table.
   100 rows/page, silently caps at 1000 — see the drill-down gotchas above.
2. **Saved list view** (`/contacts/44031266/objects/0-1/views/<viewId>/list`): **virtualized
   and paginated**. Only rendered rows exist in the DOM, so you must scroll-loop until the id
   set stops growing, then click Next and repeat. Use `harvest-listview.mjs`.
3. **Dashboard chart tile** (e.g. "Total MQL by owner" with an owner quick-filter): the tile
   click opens a *chart*, not a contact table. The bar's `aria-label` gives the count
   ("Nicholas Pardon, 85") but clicking the bar did **not** yield a contact list in testing
   (2026-08-06, unresolved). If a chart tile is the only source, get the contacts another way:
   rebuild the same filter as a contact list view, or ask the user to save it as a list.
   Do not burn a session fighting the chart.

## Workflow (only begin here once Step 0 intake is fully confirmed)

1. **Preflight**: `/devtools`; user logs into HubSpot (and Salesmsg auto-signs-in via the
   widget) if the migrated profile session expired. Confirm CSRF API access with one profile fetch.
   Check tab count — start a big batch under ~30 open tabs.
2. **Pull the list** per the source type above. Save to scratchpad.
2b. **Overlap guard**: run `overlap.mjs` over the harvested ids BEFORE vetting. Lists get reused
   and overlap with each other, and re-texting someone who already declined is worse than
   missing them. The day-threshold rule catches anyone already *sent* to; the ledger catches
   people who have an unsent draft or already said no, in any past run by anyone.
3. **Geography/targeting filter** using exactly what Step 0.5 confirmed — do not fall back to
   any prior run's rule (e.g. the NV-minus-Tahoe exclusion) unless this run's intake explicitly
   asked for it.
4. **Vet everyone via API** against exactly the Step 0.4-confirmed checklist (bulk, concurrency
   ~6): associated deal, no phone, disqualifying lead status, opted-out, became customer,
   SMS'd today, contacted more recently than the confirmed day threshold (compute from
   `max(last_contacted_date, last_sms_sent_date)` — many source reports do NOT enforce this
   themselves, and the user often sends between batches, so this MUST be re-checked immediately
   before drafting, not just at pool time). Also always skip **dead numbers**
   (`last_sms_sent_status` matching /fail|undeliver/i) and **future demos already booked**
   (`MEETING` engagement, `metadata.startTime` in the future) — both are hard rails, always on
   regardless of what Step 0.4 changed. Skip **junk first names** too (e.g. "Ddd",
   initials-only) — you cannot personalize them. Pull the most recent **Note** on every contact
   and read it — always on, hard rail #8. Log every skip with its reason.
5. **Pick the batch** (per the Step 0.6-confirmed cap): rank by whatever Step 0.5 specified
   (Nick's historical default: named region first if applicable, then Active > Inactive >
   Unresponsive engagement, SQL > MQL, most recent last-contact first) — confirm this ranking
   is still wanted rather than assuming it.
6. **Read the chains** with `chains.mjs` over the picks. This drives both tailoring and safety —
   always read the digest by eye; the STOP-phrase regex is a hint, not a gate.
7. **Re-vet the picks** with `precheck.mjs` immediately before drafting (things change fast).
8. **Draft** with `cdp-draft.mjs`, using the message content confirmed/approved in Step 0.3.
   One tab per contact, left open for review.
9. **Verify**: `confirm` pass (composer text === intended, per contact) then `final-verify.mjs`.
   Re-run stragglers individually. Screenshot-verify anything that used the coordinate fallback.
10. **Record** the batch into the ledger: `node overlap.mjs --record '<ids>' "<date> <label>"`,
   and anyone newly disqualified: `node overlap.mjs --record '<ids>' --never "<reason>"`.
11. **Report**: counts drafted/skipped(+why), review-sheet path, warm replies spotted,
   remaining pool size for the next batch, and anything Step 0 confirmed that materially
   shaped the run (so the user can verify their intake answers were actually followed).
   If any live correction happened mid-run (a phrase changed, a CTA dropped), append it to
   `style-prefs.json` now if Step 8 didn't already capture it.

## Style memory (learns preferences over time, travels with the skill package)

`commands/outreach/memory/style-prefs.json` is a durable, append-only log this skill reads and
writes itself. It lives inside the skill package — not tied to any one person's Claude Code
account — so a shared copy accumulates every teammate's confirmed style choices, and everyone
benefits from what worked for everyone else.

**Shape:**
```json
{"entries": [
  {"date": "2026-08-12", "user": "nick", "note": "CTA: 'You interested?' not 'Want me to pencil you in?' — the latter reads as an immediate scheduling ask", "source": "correction"}
]}
```
`source` is one of `approved-sample` (a proposed draft got approved as-is), `correction` (the
user edited or explicitly changed something), or `rejection` (a proposed approach was turned
down — record why, so it isn't proposed again). Keep it bounded: cap at the most recent 50
entries, drop the oldest when adding past that.

**Read it at Step 0.3**, before proposing anything — summarize the last 5-10 relevant entries as
a starting suggestion. **Write to it right after Step 0.3 concludes** (samples approved/edited,
or a template given with explicit style notes), and again at Step 11 if a live correction
happened mid-run. One short entry per distinct piece of feedback, in the user's own words where
possible rather than a paraphrase. This is additive only — never overwrite or prune anything
except the 50-entry cap; memory that gets silently discarded defeats the entire point of it.
Reading memory never replaces asking in Step 0 — it only makes the default smarter.

## Tailoring from message history

Default rule (confirm in Step 0.5 that it still applies): **never replied → cookie-cutter
template. Something in the last 3 texts worth building on → tailor it.** Keep tailored copy the
same length and tone as the template; one clause of personalization, not a rewritten message.

- The highest-value tailoring is **answering a question they actually asked and never got an
  answer to** ("Are you coming back to Lake Pleasant?", "Where are you doing the demos?").
  Lead with the answer.
- Second best: **removing the obstacle they named** (had a scheduling conflict → "new dates
  opened up"; couldn't make morning slots → "we've got more than mornings now").
- Do NOT tailor from an outbound-only thread. Do not reference how long it has been or what
  campaign they came from, unless Step 0.3 specifically confirmed otherwise. Forward-looking
  only is the default style constraint, not an absolute rule for every team.

**Hard stops — drop them from the batch and record them as `never`:**
explicit declines ("No", "Not interested", "can't afford", "won't work at that price point"),
hostile/profane replies demanding no further contact (in ANY phrasing, not just the regex's
pattern list — read the digest yourself, always), wrong-number replies, and anyone whose note
says wrong/fake number. `chains.mjs` flags likely ones, but a human decides every time. Texting
someone who already said no is the worst failure mode this pipeline has.

**Also watch for:**
- **Duplicate contact records** for the same human (same phone number, two different contact
  ids — check phone number, not just name, before assuming two records are actually two people).
  Text one, record the other as `never` with a note pointing at the kept record.
- **A pre-existing human-written draft** in the composer. `cdp-draft.mjs` refuses to overwrite
  anything that is not its own prior "Hey ..." draft and reports `field has unexpected text`.
  Read it, leave it alone, and surface it to the user — it is probably their own work in progress.

## Default style examples (offered during Step 0.3 as a starting point — confirm or override every run, for every user)

These are Nick's historical rules for his own campaigns. Offer them as a reasonable default
when a user wants copy proposed, but they are not binding on a different user's voice, product,
or campaign — Step 0.3 must confirm them (or their replacement) explicitly before any real
drafting happens.

- **No dashes, em dashes, or typical AI styling** (Nick's standing preference). Run a literal
  `-`/`—` check on every draft if this constraint is confirmed for the run.
- **No "been a minute"** — Nick's approved opener instead: "It's been a while since we last
  connected."
- **Forward-looking only. Do NOT reference old activities/past interactions** by default (e.g.
  "we talked about a factory tour a while back" is banned in Nick's campaigns). A concrete past
  demo RIDE may be acceptable as a tailoring hook — confirm per run.
- Short and sweet: 1-2 sentences + a light CTA, ideally 1 SMS segment, cookie-cutter across the
  batch unless tailoring applies. Goal is re-engagement, not a pitch.
- Nick's voice example: "Hey {First}, it's Nick with Arc. ... Would love to get you out for a surf."
- Region personalization is welcome but must be GROUNDED in real, user-confirmed activity —
  never invent a location or date. If a date is needed and can't be verified another way, ask
  the user rather than guessing or scraping (arcboats.com/tour blocks bots).
- **Name the actual demo locations** only when the user supplies them for this run — they
  change per campaign. Run them as a plain list, no dashes: "We've got demos coming up at
  Havasu, Saguaro, and Pleasant." Never invent a location or a date.
- Approved CTA verb (Nick's call, 2026-08-05): **"surf" beats "ride"** — "get you out for a
  surf". Avoid phrasing that makes the customer sound like a member of a group ("Arizona
  folks") — say what the business is doing instead ("we're kicking up demos in AZ soon").
- Avoid asks that sound like an immediate scheduling commitment unless that's really the goal
  (Nick dropped "Want me to pencil you in?" in favor of a lighter "You interested?" on
  2026-08-12) — confirm the CTA phrasing explicitly in Step 0.3 rather than reusing either.

## NEVER reload a record tab to fix a widget

`Page.reload` on a contact record drops the Salesmsg widget's auth: it re-renders as a bare
**"Sign in"** screen with no conversation and no composer, and a coordinate click then lands on
the page body (focus reads BODY) instead of the iframe. Do NOT click that Sign in button.
The fix is to **discard that tab and reopen the contact record fresh** so the widget inherits the
already-authenticated Salesmsg session from the profile. Safe to close because a signed-out
widget by definition holds no draft — verify that first (no
`widget-light/conversations/<convId>` target exists for it), then close and re-run `cdp-draft.mjs`,
which creates a new tab. If a fresh tab still fails to expose the widget iframe as a CDP target
(common past ~150 open tabs), fall back to the coordinate-click method: get the iframe's
`getBoundingClientRect()` via `Runtime.evaluate` even though it has no separate CDP target,
click at 45% width / ~92px above the iframe's bottom edge via `Input.dispatchMouseEvent`, then
`Input.insertText`, and always screenshot-verify the result before moving on — this method
inserts into whatever has page-level focus, so verify by eye every time, not just by the
verified-text-matches check.

## Known false negative: the widget name-check

`cdp-draft.mjs` refuses to type unless the widget body shows the contact's first name. The
conversation pane can lag behind the iframe load, so a correct contact fails with "widget body
does not show contact first name". Do NOT weaken the guard. Re-run those contacts with a longer
name-wait (poll ~20x2s) plus triple identity proof: record-page `document.title` contains the
first name, iframe src contains `contact_integration_id=<id>`, and the conversation id matches
the record page's Salesmsg link. Only then insertText.

## Per-draft logic-test checklist

correct contact/tab pairing (record page name = widget header name) · not already drafted and
not in the never-contact ledger · never explicitly declined, replied wrong-number, or replied
hostile/profane in any phrasing · not a duplicate phone number of another record in the same
batch · targeting rule from Step 0.5 passes · vetting checklist from Step 0.4 passes in full
(deal/phone/opt-out/lead-status/customer/SMS-today/day-threshold/dead-number/future-demo) ·
most recent Note read and factored in · real first name · message matches the Step 0.3-confirmed
content and style constraints exactly · composer was empty or held only our own prior draft ·
composer text === intended draft, verified by re-reading it (and by screenshot if the
coordinate fallback was used) · Send never touched.

## Scale reference (what a real run looks like)

261 drafts across 12 batches, 2026-08-03 to 08-12, zero accidental sends. A 20-batch takes
roughly 15 minutes of drafting plus vetting; a 40-batch splits into two runs. Expect 1-3
stragglers per 20 from iframe-target churn — the fallback chain recovers them, worse past ~150
open tabs. Vetting routinely disqualifies 30-80% of a raw list (Unqualified lead status, open
deals, missing or dead phones, recently contacted, future demo already booked) — a large source
list is often a much smaller *qualified* pool once every rail is applied for real; say so
plainly in the Step 0 confirmation and again in the final report rather than letting a requested
batch size imply more qualified contacts exist than actually do.
