---
description: One-shot Netlify deployment — deeply researches Netlify docs AND the codebase in parallel, synthesizes a deployment strategy, then deploys via the Netlify MCP. Works on any project.
argument-hint: "[optional: specific instructions like 'preview only' or 'use Supabase']"
---

# Netlify Deploy

You are executing `/netlifydeploy`. This is a **general-purpose deployment skill** that works on any project. Do not assume any specific tech stack — detect everything dynamically.

**User instructions:** $ARGUMENTS

---

## Phase 1: Ensure Netlify MCP is Connected

1. Check if the `netlify` MCP server is available by looking at your available tools for Netlify-related tools (e.g., `deploy-site`, `get-user`, `create-new-project`).
2. If NOT connected:
   - Run: `claude mcp add netlify -- npx -y @netlify/mcp`
   - Tell the user: "I've added the Netlify MCP. Please restart this Claude Code session and run `/netlifydeploy` again."
   - **STOP here.** The MCP tools won't be available until restart.
3. If connected, test auth by calling the `get-user` MCP tool (or equivalent — check your available Netlify tools).
4. If auth fails, ask the user:
   - **Option A** (quick): "Provide a Netlify Personal Access Token. Generate one at: Netlify Dashboard → User Settings → Applications → Personal access tokens"
   - **Option B** (preferred): "Run `netlify login` in a separate terminal, then try again"
   - If they provide a PAT, reconfigure: `claude mcp add --env NETLIFY_PERSONAL_ACCESS_TOKEN=<token> netlify -- npx -y @netlify/mcp` and restart.

---

## Phase 2: Deep Parallel Research

**This is the most important phase.** Before making ANY recommendations, you must deeply understand two things: (A) the current state of Netlify's platform and (B) the current project's architecture. Do both in parallel.

### 2A: Netlify Platform Research (Agent)

Spawn a `general-purpose` Agent with this prompt:

```
You are researching Netlify's deployment platform to prepare for a deployment. Use WebSearch and WebFetch extensively. Do NOT rely on cached knowledge — Netlify's platform evolves.

Research these dimensions IN PARALLEL using multiple sub-agents:

1. **Netlify MCP Server** — Fetch https://github.com/netlify/netlify-mcp README.
   Get: all available tool names, their parameters, auth method, config format.
   Search for any recent changes or new tools.

2. **Framework Adapter** — Search for "deploy [FRAMEWORK] on Netlify site:docs.netlify.com"
   (The framework will be provided by the codebase analysis. If unknown, research Next.js, Remix, Astro, and Vite adapters.)
   Get: build command, publish directory, plugin/adapter name, supported features (SSR, ISR, edge), limitations, required config.

3. **Serverless Constraints** — Search for "Netlify functions limits timeout memory site:docs.netlify.com"
   Get: function timeout (sync vs background vs scheduled), memory limits, payload limits, cold start behavior, connection limits, filesystem behavior (ephemeral).

4. **Database on Netlify** — Search for "database serverless Netlify" and the specific DB provider if known.
   Get: recommended providers (Neon, Supabase, PlanetScale, MongoDB Atlas, Turso), connection pooling requirements, Netlify DB (native), environment variable patterns.

5. **Netlify Scheduled Functions** — Search for "Netlify scheduled functions cron site:docs.netlify.com"
   Get: syntax, file location, schedule format, timeout, how to configure in netlify.toml.

Save your complete findings to: ./tmp/research/netlify-platform-research.md
Use the standard research document format with frontmatter, executive summary, detailed findings, and source URLs.
Every claim must have a source URL.
```

### 2B: Codebase Analysis (Agent)

Spawn an `Explore` agent with `very thorough` thoroughness:

```
Do a very thorough exploration of this project. I need a complete understanding of the tech stack, architecture, and deployment requirements. Analyze:

1. **Framework & Build**: package.json (dependencies, scripts, build command), framework config files (next.config.*, vite.config.*, remix.config.*, astro.config.*)
2. **Database & ORM**: Look for prisma/schema.prisma (read the provider and all models), drizzle configs, mongoose models, @supabase/supabase-js usage, raw SQL files, any database connection code
3. **Authentication**: NextAuth, Clerk, Auth0, Supabase Auth, Lucia, custom auth — find the actual auth setup
4. **Background Jobs**: Grep for node-cron, bull, bullmq, agenda, setInterval in server code, any instrumentation hooks that start workers
5. **Server-Side Features**: PDF generation (pdfkit, puppeteer), email (nodemailer, sendgrid, resend), file uploads, image processing (sharp)
6. **API Routes / Server Functions**: List ALL API endpoints, what they do, and what external services they call
7. **Environment Variables**: Read .env.example, .env.template, .env.local.example — list every variable and its purpose
8. **Existing Deploy Config**: Check for netlify.toml, vercel.json, fly.toml, Dockerfile, docker-compose.yml, render.yaml, railway.toml
9. **External Connections**: Any outbound connections to databases, APIs, or services that may not be reachable from serverless
10. **Monorepo Detection**: Check for workspaces in package.json, turbo.json, nx.json, lerna.json

Return a structured **Stack Profile**:

Framework:        [name + version]
Database:         [provider + ORM + connection method]
Auth:             [provider + session strategy]
Background Jobs:  [what runs, on what schedule, how it's triggered]
Server Features:  [PDF, email, uploads, etc.]
API Routes:       [count + summary of what they do]
Env Vars:         [complete list with purposes]
External Connections: [what connects where]
Deploy Config:    [existing config files found]
Monorepo:         [yes/no + structure if yes]

Also note any **serverless red flags**: file-based databases, persistent processes, local filesystem writes, long-running operations, private network dependencies.
```

### Wait for Both

Wait for BOTH agents to complete before proceeding. Read the research document at `./tmp/research/netlify-platform-research.md` and the codebase analysis results.

---

## Phase 3: Synthesize — Deployment Strategy

Now cross-reference the two research outputs. For each aspect of the project, match it against Netlify's capabilities:

### 3A: Build the Compatibility Matrix

| Project Aspect | Current State | Netlify Support | Action Needed |
|---------------|---------------|-----------------|---------------|
| Framework | [from codebase] | [from research] | [none / config change / plugin needed] |
| Database | [from codebase] | [from research] | [none / migrate / add provider] |
| Auth | [from codebase] | [from research] | [none / env var / config] |
| Background Jobs | [from codebase] | [from research] | [none / convert to scheduled fn] |
| Server Features | [from codebase] | [from research] | [none / background fn / external service] |
| Env Vars | [from codebase] | [from research] | [list what needs setting] |

### 3B: Identify Blockers

For each row where "Action Needed" is not "none", classify:

- **Auto-fixable**: Can be resolved by adding config/env vars (no code changes)
- **Code change required**: Needs refactoring before deploy (list specific files and changes)
- **Architecture change**: Fundamental incompatibility that needs discussion (e.g., file-based DB, persistent processes, private network access)
- **User decision needed**: Multiple valid approaches, user must choose (e.g., which DB provider)

### 3C: Determine Deployment Shape

Based on research:
- **Single site** (typical) vs **multiple sites** (monorepo)
- **Compute needs**: Which functions need sync (60s), background (15min), scheduled, or edge
- **Build command** and **publish directory** (from framework research)
- Whether a `netlify.toml` is needed or if auto-detection suffices

---

## Phase 4: Present Strategy & Collect Input

Present to the user:

```
## Deployment Strategy

**Project**: [name] ([framework] + [db] + [auth])
**Deployment type**: [single site / multiple]
**Build**: [command] → [publish dir]

### Compatibility
[The matrix from 3A — only rows that need action]

### Blockers
[Ordered by severity — architecture changes first, then code changes, then auto-fixable]

### What I Need From You
- [Credentials / API keys / env var values needed]
- [Decisions on blocker resolutions]
- [Any preferences on DB provider, domain, etc.]
```

**Wait for the user to respond.** Do not proceed until blockers are resolved and credentials are provided.

---

## Phase 5: Pre-Deploy Setup

Using the Netlify MCP tools:

1. **Check for existing site**: Use the project reader tool to search for a matching project name
   - If found: ask "Deploy to existing site [name]?" or "Create new?"
   - If not found: create a new project
2. **Set environment variables**: Use the env var management tool to set all required vars
3. **Apply auto-fixable changes**: Add `netlify.toml`, `postinstall` script, etc. if needed
4. **Verify build locally**: Run the build command to catch errors before deploying

---

## Phase 6: Deploy

1. **Preview first**: Deploy a draft/preview build
2. **Show the preview URL** to the user
3. **Ask for confirmation**: "Preview is live at [URL]. Deploy to production?"
4. **Production deploy** on confirmation
5. **Report the live URL**

---

## Phase 7: Domain Setup

After a successful deploy, ask the user:

```
Your site is live at [netlify-subdomain].netlify.app

Would you like to:
  A) Keep the default Netlify subdomain ([name].netlify.app)
  B) Connect a domain you already own
  C) Register a new domain through Netlify
```

**Wait for the user to respond.** Do not proceed with any domain action without explicit input.

### Option A: Default Subdomain
No action needed. Confirm the URL and move to Phase 8.

### Option B: Connect Existing Domain
Walk the user through DNS configuration step by step:

1. Ask for their domain name (e.g., `myapp.com`)
2. Use the Netlify MCP project updater tool to add the custom domain to the site (if the MCP supports this — check your available tools)
3. Provide the exact DNS records they need to set at their registrar:
   - **For apex domain** (e.g., `myapp.com`): ALIAS or ANAME record pointing to the Netlify load balancer, OR an A record to Netlify's IP (research the current IP via WebSearch — it changes)
   - **For subdomain** (e.g., `www.myapp.com` or `app.myapp.com`): CNAME record pointing to `[site-name].netlify.app`
4. Explain that Netlify auto-provisions HTTPS via Let's Encrypt once DNS propagates
5. Tell the user: "DNS propagation can take up to 48 hours but usually completes within minutes. Netlify will automatically provision an SSL certificate once it detects the DNS records."
6. If the user doesn't know how to access their registrar's DNS settings, ask who their registrar is (GoDaddy, Namecheap, Cloudflare, Google Domains, etc.) and give registrar-specific instructions

### Option C: Register New Domain Through Netlify

**CRITICAL: This costs money. Require explicit confirmation before ANY purchase.**

1. Ask the user what domain they want (e.g., `myapp.com`)
2. Research whether Netlify's MCP tools support domain registration/purchase — check your available Netlify tools for anything related to domains
3. **If the MCP supports domain purchase**:
   - Look up availability and price
   - Present to the user: "The domain [name] is available for $[price]/year through Netlify. Do you want to proceed with the purchase? Type 'yes, purchase [domain] for $[price]' to confirm."
   - **Do NOT proceed unless the user replies with explicit confirmation that includes the domain name and price.**
   - After purchase, the domain auto-configures with the Netlify site — no manual DNS needed
4. **If the MCP does NOT support domain purchase**:
   - Tell the user: "Domain registration isn't available through the MCP tools. You can buy a domain directly in the Netlify Dashboard (Domains → Add or register domain) or through a registrar like Namecheap, Cloudflare, or Google Domains."
   - If they buy through Netlify Dashboard, it auto-configures
   - If they buy elsewhere, fall back to Option B instructions

### Domain Spending Safeguard

**NEVER execute a domain purchase, plan upgrade, or any action that costs money without ALL of these:**
1. The user has been told the exact price
2. The user has explicitly confirmed with a clear affirmative that references the action and cost
3. You have re-stated the action before executing: "Confirming: purchasing [domain] for $[price]/year. Proceeding now."

If there is ANY ambiguity in the user's response, ask again. Err on the side of asking too many times rather than spending money without clear consent.

---

## Phase 8: Post-Deploy

Tell the user:
- The production URL (and custom domain if configured)
- SSL/HTTPS status
- Any manual steps remaining
- Suggest: deploy previews for PRs, build notifications, branch deploys

---

## Important Rules

- **Never commit secrets** to code or version control
- **Always preview before production** — never skip this
- **Be idempotent** — running this twice should not create duplicate sites
- **If research tools are unavailable**, fall back to training knowledge but warn the user that docs may be outdated
- **If the user passes arguments** (e.g., "preview only", "use Supabase"), respect those directives and adjust the research queries accordingly
- **Keep the user informed** at each phase — show progress, not silence
- **Trust the research, not assumptions** — if the Netlify research says a tool is named X, use X, even if your training says it was called Y
