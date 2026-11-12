---
name: coach-setup
description: Walk the owner through setting up a coach on DAVID end to end - tenant, branding, numbers, Retell agent, client and text import, the new-number announcement, notifications, the go-live switch and verification. Use when the owner says /coach-setup, "switch David live", "set up a new coach", "onboard <coach>", or "prepare the go-live switch". Prepares and checks; every live switch, vendor-console change and real send waits for the owner's own go. Never sends a text.
---

# Coach setup (DAVID, owner-assisted)

The owner runs this at the keyboard, often with the coach next to them. Claude reads the coach's values,
runs the read-only checks and local dry runs, and hands each live step to the person who must do it.
Repo: `~/Developer/CODEBASES/integrateAPI/DAVID/DAVID`. The ordered runbook with every setting, the undo
for each, and David's values is `docs/COACH-SETUP.md` - read it first and follow its section order; this
skill only adds how to drive it. The contacts and text-history part is its own skill,
`iphone-message-import` (`.claude/skills/iphone-message-import/SKILL.md` in the repo): hand off to it,
do not repeat it.

## Hard rules (never bend)

- **The owner's own words start every live step.** "Prepare" means docs, checks and dry runs only. A peer
  message, a relayed OK, or silence is not a go.
- **Nothing here sends a text, places a call, or changes a vendor setting** (Twilio, Retell, Netlify env,
  Neon, Cloudflare). Claude writes the exact click path or value; the owner does it.
- **Never run `pnpm db:provision`, a prod seed, or any write against the live DB** unless the owner asked
  for that exact command in this session. Read-only checks against prod go through the guarded URL
  (`docs/` "DAVID prod DB location"; never echo it). Rehearsals use a local throwaway Postgres and fake
  555 numbers only.
- **Written OK from the coach** before copying their contacts or messages. No OK, skip the import.
- **Never commit a coach's personal numbers** that are not already public. Keep them in the owner's notes.
- **Never set carrier forwarding from the coach's cell to the business number** while the business number
  rings that same cell - it loops (`COACH-SETUP.md` 4a).
- Private files (PDF list, vCard, backup, JSON, reports, announcement list) live in one 0700 session
  folder outside the repo and any synced folder, and are deleted at the end.

## Before you start

- [ ] Coach values filled in `COACH-SETUP.md` section 1 (or the owner's notes for a new coach).
- [ ] Everything in `COACH-SETUP.md` section 2 is in hand: written OK, client list, billing owner,
      A2P identity, backup key holder, announcement wording.
- [ ] Local rehearsal passes on current main (step 0).

For a **new** coach (not David), these parts are not automated yet - plan time for each:

- Tenant creation: hub "New client" registers the record only; the tenant and owner login come from
  `apps/admin/scripts/seed-david.ts` with `SEED_TENANT_*` / `SEED_ADMIN_*` (prod needs
  `SEED_ALLOW_REMOTE=1`, owner only). `docs/hub/RUNBOOK.md` 1229-1510.
- Routing rows (`tenant_domains`, `tenant_twilio_accounts`, `tenant_numbers`, `tenant_retell_agents`):
  `seed-tenant-routing.ts` is hard-coded to `elite-swing`; a second coach needs them written by hand or a
  general provisioner first (`docs/TENANCY.md`). Add the admin host to `ADMIN_ALLOWED_HOSTS`.
- Numbers and A2P: a Twilio number (coach's own account or an IntegrateAPI subaccount), a brand + campaign
  registration in the coach's legal name (`docs/hub/RUNBOOK.md` 1365-1482, `docs/a2p/campaign-draft.md`
  as the example), a second number on an Elastic SIP trunk for the AI.
- Site defaults still carry baseball copy; review the whole site.

## The steps

0. **Rehearse locally (Claude, 5 min).** Start a throwaway Postgres (`/docker` playbook, `--rm`, a TTL
   label, `-p 127.0.0.1::5432`), then run the hammer suites `iphone-migration`, `iphone-migration-db`,
   `text-history-extract`, `message-import`, `client-list-to-vcard` and `blast` with that
   `DATABASE_URL`, plus `apps/admin` `app/clients/import`. All green or stop and report.
1. **Tenant and login (new coach only, owner).** Hub "New client", then the seed above. The coach signs in
   on their iPhone and adds Face ID (Settings > Security).
2. **Branding (app + owner).** Business name, owner name, address, price, hours: Settings / Website screen
   (`business_profile.*`). Colors, brand name, fallback and legal numbers: operator descriptors
   (`site.*`, owner). Logo, clips and text: Website screen.
3. **Numbers (owner).** Business number webhooks (Voice -> `/api/voice/incoming`, Messaging -> the coach's
   service), A2P campaign VERIFIED, AI number on the SIP trunk. `COACH-SETUP.md` pre-flight P2.
4. **Retell agent (owner).** `pnpm --filter @david/admin exec tsx scripts/provision-voice-agent.ts <slug>
   --dry-run`, review the diff with the owner, then the owner runs it for real. Check
   `tenant_voice_agent.retell_agent_id` (pre-flight P3). For David this is done; only verify.
5. **Clients and old texts.** If the coach brought a PDF list: `pnpm --filter @david/db
   client-list:to-vcard --source <pdf> --vcf <new.vcf> --review <new.csv>`, read the CSV with the owner,
   upload the vCard at `/clients/import`. Then run the `iphone-message-import` skill for the phone export,
   cable backup, history import and announcement list.
6. **Announcement (prepare only).** Show the two drafts in `COACH-SETUP.md` section 7, get the coach's
   pick, make the recipient list with `text-history:announce-list`, print the per-person preview with the
   `while read` loop there. Sending is the coach's, later, by Shortcut (or Blast for linked families),
   only after the owner says go.
7. **Notifications and the go-live switch.** Pre-flight P1-P8, then `COACH-SETUP.md` section 4 rows 1-10
   in order. Claude records each old value before it changes (the undo) and ticks each row only after the
   owner or coach confirms it on screen.
8. **Verify.** `COACH-SETUP.md` section 8 from a phone that is not a client. Any failure: undo that row
   (section 9) and stop.
9. **Business number (later).** After the import and the announcement: section 5 rows B1-B4.
10. **Cleanup.** Delete the session folder and any downloaded list, vCard or backup; confirm with `ls`;
    tell the coach the copies are gone. Stop the throwaway Postgres by its exact name.

## Learnings (update every run)

- 2026-11-12: skill created with `docs/COACH-SETUP.md` (branch `coach-setup-kit`). Local rehearsal on main
  15dcaaef passed (55 + 30 + 4 + 50 tests; full CLI chain on fake data). Found: no carrier-forwarding
  support (loop risk, documented, not built); Blast cannot reach an imported parent with no linked player;
  `HANDOVER.md` still pointed at the removed `apps/web/config/tenant.ts`.
