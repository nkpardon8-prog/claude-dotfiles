---
description: One-shot Netlify deployment — analyzes any project, builds deployment strategy, configures, and deploys via the Netlify MCP. Always researches latest docs first.
argument-hint: "[optional: specific instructions like 'preview only' or 'use Supabase']"
---

# Netlify Deploy

You are executing `/netlifydeploy`. This is a **general-purpose deployment skill** that works on any project. Do not assume any specific tech stack — detect everything dynamically.

## Phase 1: Ensure Netlify MCP is Connected

1. Check if the `netlify` MCP server is available by looking at your available tools for Netlify-related tools (e.g., `deploy-site`, `get-user`, `create-new-project`).
2. If NOT connected:
   - Run: `claude mcp add netlify -- npx -y @netlify/mcp`
   - Tell the user: "I've added the Netlify MCP. Please restart this Claude Code session (`/exit` then relaunch) and run `/netlifydeploy` again."
   - **STOP here.** The MCP tools won't be available until restart.
3. If connected, test auth by calling the `get-user` MCP tool.
4. If auth fails, ask the user:
   - **Option A** (quick): "Provide a Netlify Personal Access Token. Generate one at: Netlify Dashboard → User Settings → Applications → Personal access tokens"
   - **Option B** (preferred): "Run `netlify login` in a separate terminal, then try again"
   - If they provide a PAT, reconfigure: `claude mcp add --env NETLIFY_PERSONAL_ACCESS_TOKEN=<token> netlify -- npx -y @netlify/mcp` and restart.

## Phase 2: Research Latest Netlify Docs

Use `WebSearch` and `WebFetch` to pull **current** documentation. Netlify's platform evolves — never rely solely on cached knowledge.

Research these (in parallel where possible):
1. **Framework deployment**: Search `"deploy [detected-framework] on Netlify" site:docs.netlify.com` — get the latest adapter/plugin info, build commands, publish directories
2. **Netlify MCP tools**: Fetch `https://github.com/netlify/netlify-mcp` README — confirm current tool names and signatures
3. **Database provider** (if applicable): Search `"[detected-db-provider] serverless deployment"` — get connection string formats, pooling requirements

Save a brief summary of findings to `./tmp/netlify-deploy-context.md` so the user has a record.

## Phase 3: Analyze the Project

Read the codebase to detect the full stack. Check these files:

| Check | Files to Read |
|-------|--------------|
| Framework | `package.json` → look for `next`, `remix`, `astro`, `nuxt`, `svelte`, `vite`, `gatsby` |
| Database/ORM | `prisma/schema.prisma`, `drizzle.config.*`, `package.json` deps for `mongoose`, `@supabase/supabase-js`, `better-sqlite3`, `pg`, `mysql2`, `mongodb`, `drizzle-orm`, `typeorm`, `knex` |
| Auth | `package.json` deps for `next-auth`, `@clerk/nextjs`, `@auth0/nextjs-auth0`, `@supabase/auth-helpers-nextjs`, `lucia` |
| Background jobs | Grep for `node-cron`, `bull`, `bullmq`, `agenda`, `@netlify/functions` schedule config |
| Env vars | `.env.example`, `.env.local.example`, `.env.template` |
| Existing deploy config | `netlify.toml`, `vercel.json`, `fly.toml`, `Dockerfile`, `render.yaml` |
| Build config | `package.json` scripts (`build`, `postinstall`), `next.config.*`, `vite.config.*` |

Build a **stack profile**:
```
Framework:     [e.g., Next.js 14]
Database:      [e.g., Prisma + SQLite / Supabase / MongoDB Atlas / none]
Auth:          [e.g., NextAuth JWT / Clerk / none]
Background:    [e.g., node-cron / none]
Build command: [e.g., npm run build]
Publish dir:   [e.g., .next / dist / build]
Env vars needed: [list from .env.example]
```

## Phase 4: Identify Deployment Blockers

Check for serverless incompatibilities:

| Blocker | Detection | Resolution |
|---------|-----------|------------|
| SQLite / file-based DB | `provider = "sqlite"` in Prisma or `better-sqlite3` dep | Must switch to external DB (PostgreSQL via Neon/Supabase, or MongoDB Atlas) |
| Persistent cron jobs | `node-cron`, `setInterval` in server code | Convert to Netlify Scheduled Functions |
| Filesystem writes | Writing to local disk (uploads, temp files) | Use Netlify Blobs or external storage (S3, Cloudflare R2) |
| Long-running processes | Sync jobs > 60s, heavy PDF generation | Use Netlify Background Functions (15min limit) |
| Private network access | `mysql2` or DB connecting to LAN server | Needs tunnel (Tailscale, Cloudflare Tunnel) or cloud relay |
| Missing postinstall | Prisma without `"postinstall": "prisma generate"` | Add to package.json scripts |

**Present blockers to the user clearly.** For each blocker, explain:
- What it is
- Why it breaks on Netlify
- The simplest fix
- Ask if they want you to fix it now or skip it

## Phase 5: Collect Missing Credentials

After analysis, determine what's needed:

1. **Netlify auth** — already verified in Phase 1
2. **Database URL** — if migrating, ask the user for their new connection string
3. **App env vars** — list everything from `.env.example` that the Netlify site will need
4. **Ask for all missing values at once** — don't ask one at a time

## Phase 6: Pre-Deploy Setup

Using the Netlify MCP tools:

1. **Check for existing site**: Call `get-projects` and search for a matching project name
   - If found: ask the user "Deploy to existing site [name]?" or "Create new?"
   - If not found: call `create-new-project`
2. **Set environment variables**: Call `manage-env-vars` to set all required env vars on the Netlify site
3. **Verify build locally** (optional but recommended): Run `npm run build` to catch errors before deploying

## Phase 7: Deploy

1. **Preview first**: Call `deploy-site` for a preview/draft deployment
2. **Show the preview URL** to the user
3. **Ask for confirmation** before production: "Preview is live at [URL]. Deploy to production?"
4. **Production deploy**: Call `deploy-site` for production on confirmation
5. **Report the live URL**

## Phase 8: Post-Deploy

Tell the user:
- The production URL
- Any manual steps remaining (custom domain, DNS)
- Suggest: deploy previews for PRs, build notifications

---

## Important Rules

- **Never commit secrets** to code or version control
- **Always preview before production** — never skip this
- **Be idempotent** — running this twice should not create duplicate sites
- **If web research tools are unavailable**, fall back to your training knowledge but warn the user that docs may be outdated
- **If the user passes arguments** (e.g., "preview only", "use Supabase"), respect those directives
- **Keep the user informed** at each phase — don't go silent during long operations
