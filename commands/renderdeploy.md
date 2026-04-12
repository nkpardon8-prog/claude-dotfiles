---
description: One-shot Render deployment — deploys both frontend (static site) and backend (web service) via Render MCP + REST API. Detects repo, asks user to confirm, handles env vars, returns live URLs.
argument-hint: "[optional: 'frontend only', 'backend only', 'preview', specific instructions]"
---

# Render Deploy

You are executing `/renderdeploy`. This deploys the project to **Render.com** — supporting both static frontends and full backend web services. Do not assume any specific tech stack — detect everything dynamically.

**User instructions:** $ARGUMENTS

---

## Phase 1: Ensure Render MCP is Connected

1. Check if the `render` MCP server is available by looking at your available tools for Render-related tools (e.g., `list_workspaces`, `create_web_service`, `create_static_site`, `list_services`).
2. If NOT connected:
   - Ask the user for their Render API key: "I need your Render API key. Generate one at: Render Dashboard > Account Settings > API Keys (starts with `rnd_`)"
   - Run: `claude mcp add --transport http render https://mcp.render.com/mcp --header "Authorization: Bearer <API_KEY>"`
   - Tell the user: "I've added the Render MCP. Please restart this Claude Code session and run `/renderdeploy` again."
   - **STOP here.** The MCP tools won't be available until restart.
3. If connected, test by listing workspaces or services.
4. If auth fails, ask the user to verify their API key and reconfigure.

---

## Phase 2: Detect Project & Git Remote

### 2A: Detect the Git Remote

1. Run `git remote -v` to find the GitHub repo URL
2. Extract the `owner/repo` from the remote URL
3. If no remote exists, ask the user: "This project doesn't have a GitHub remote. What repo should I deploy from? (e.g., `username/repo-name`)"
4. **Confirm with the user**: "I'll deploy from `[owner/repo]` on branch `[current branch]`. Correct?"
5. **Wait for confirmation before proceeding.**

### 2B: Codebase Analysis

Spawn an `Explore` agent with `very thorough` thoroughness:

```
Do a very thorough exploration of this project to understand what needs to be deployed. Analyze:

1. **Framework & Build**: package.json (dependencies, scripts, build command), framework config files, Python requirements
2. **Backend Detection**: Look for FastAPI, Flask, Django, Express, any server framework. Find the start command, port configuration, runtime (Python/Node)
3. **Frontend Detection**: React, Vue, Svelte, Next.js, Vite — find build command and output directory
4. **Database**: Supabase, PostgreSQL, MongoDB, Redis — connection strings, ORM
5. **Environment Variables**: Read .env, .env.example, .env.template, .env.local — list every variable and its purpose
6. **Existing Deploy Config**: Check for render.yaml, Dockerfile, docker-compose.yml, Procfile, netlify.toml, vercel.json
7. **Monorepo Detection**: Are frontend and backend in separate directories? What are the root dirs?
8. **External Services**: What APIs/services does the app connect to?

Return a structured **Stack Profile**:

Frontend:         [framework + build command + output dir + root dir]
Backend:          [framework + start command + runtime + root dir]
Database:         [provider + connection method]
Env Vars:         [complete list with purposes, separated by frontend vs backend]
Deploy Config:    [existing config files found]
Monorepo:         [yes/no + structure]
External Services: [list of external APIs/services]
```

---

## Phase 3: Determine Deployment Shape

Based on the codebase analysis, determine what to deploy:

### 3A: Identify Services to Create

| Service | Render Type | Root Dir | Build Command | Start/Publish | Runtime |
|---------|------------|----------|---------------|---------------|---------|
| Frontend | `static_site` | [dir] | [command] | [publish path] | N/A |
| Backend | `web_service` | [dir] | [command] | [start command] | [python/node] |

### 3B: Identify Environment Variables

Separate env vars into:
- **Frontend env vars** (public, prefixed with VITE_ or NEXT_PUBLIC_ etc.)
- **Backend env vars** (API keys, database URLs, secrets)

### 3C: Identify Potential Issues

- Missing env vars that are required
- Build commands that might fail
- Port configuration (Render uses `$PORT` — backend must bind to `0.0.0.0:$PORT`)
- Any serverless vs server differences

---

## Phase 4: Present Strategy & Get Approval

Present to the user:

```
## Render Deployment Plan

**Repo**: [owner/repo] (branch: [branch])

### Services to Deploy

**Frontend** ([framework])
  - Type: Static Site
  - Root: [dir]
  - Build: [command]
  - Publish: [path]

**Backend** ([framework])
  - Type: Web Service
  - Root: [dir]
  - Build: [command]
  - Start: [command]
  - Runtime: [python/node]

### Environment Variables Needed
[List what's needed, flag any you don't have values for]

### Potential Issues
[Any blockers or concerns]

Proceed with deployment?
```

**Wait for the user to respond.** Do not proceed without approval. If the user says "frontend only" or "backend only", respect that.

---

## Phase 5: Pre-Deploy Setup

1. **Get the workspace/owner ID**: Use the Render MCP tool to list workspaces (`list_workspaces` or equivalent). Extract the owner ID (starts with `tea-`).
2. **Check for existing services**: List current services to avoid creating duplicates. If matching services exist, ask: "Found existing service [name]. Update it or create new?"
3. **Collect missing env var values**: If any required env vars are missing values, ask the user for them. **Never guess API keys or secrets.**
4. **Verify build locally** (optional but recommended): Run the build command to catch errors before deploying.

---

## Phase 6: Create Services & Deploy

### 6A: Create Backend Web Service (if applicable)

Use the Render MCP tools to create the web service. If the MCP has a `create_web_service` tool, use it with:
- `name`: derived from project name (e.g., `estim8r-api`)
- `repo`: GitHub repo URL
- `branch`: the confirmed branch
- `rootDir`: backend directory
- `buildCommand`: e.g., `pip install -r requirements.txt`
- `startCommand`: e.g., `uvicorn backend.main:app --host 0.0.0.0 --port $PORT`
- `runtime`: `python` or `node`
- `plan`: `starter` (or ask user)
- `region`: `oregon` (or ask user)
- `autoDeploy`: `yes`

If the MCP tool doesn't support all these fields, fall back to the REST API:

```bash
curl -X POST https://api.render.com/v1/services \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{...}'
```

After creation, set environment variables using the MCP env var tools or REST API.

### 6B: Create Frontend Static Site (if applicable)

Use the Render MCP tools to create the static site with:
- `name`: derived from project name (e.g., `estim8r-app`)
- `repo`: GitHub repo URL
- `branch`: the confirmed branch
- `rootDir`: frontend directory
- `buildCommand`: e.g., `npm install && npm run build`
- `publishPath`: e.g., `dist`
- `autoDeploy`: `yes`

After creation, set any frontend env vars (like the backend API URL — which you now know from 6A).

### 6C: Link Frontend to Backend

After both services are created:
1. Get the backend's live URL (e.g., `https://estim8r-api.onrender.com`)
2. Set the frontend's API URL env var (e.g., `VITE_API_URL=https://estim8r-api.onrender.com`) so the frontend knows where to call

---

## Phase 7: Monitor Deploy & Verify

1. Both services should auto-deploy since `autoDeploy: yes` and the repo is connected.
2. Check deploy status using MCP tools or REST API (`GET /v1/services/{id}/deploys`).
3. **Note**: Render MCP cannot trigger deploys directly. If a manual trigger is needed, use the REST API:
   ```bash
   curl -X POST https://api.render.com/v1/services/{serviceId}/deploys \
     -H "Authorization: Bearer $RENDER_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"clearCache": "do_not_clear"}'
   ```
4. If a deploy fails, check logs (via MCP `get_logs` tool or REST API), diagnose, and help the user fix.

---

## Phase 8: Present Results

Tell the user:

```
## Deployment Complete!

**Frontend**: https://[name].onrender.com
**Backend**: https://[name].onrender.com

### Auto-Deploy
- Push to [branch] → both services auto-redeploy
- No manual deploys needed

### Next Steps
- Custom domain: Render Dashboard > [Service] > Settings > Custom Domains
- SSL: Auto-provisioned by Render
- Scaling: Render Dashboard > [Service] > Settings > Instance Type
```

---

## Phase 9: Domain Setup (if requested)

If the user asks about custom domains:

1. Ask for their domain name
2. Use the Render MCP or REST API to add the custom domain to the service
3. Provide DNS records:
   - **CNAME**: Point domain to `[service-name].onrender.com`
4. Render auto-provisions SSL via Let's Encrypt
5. Tell the user DNS propagation timing

---

## Important Rules

- **Always detect the repo from git remote** and confirm with the user before deploying
- **Never commit secrets** to code or version control
- **Never guess env var values** — ask the user for any missing secrets/keys
- **Be idempotent** — running this twice should not create duplicate services. Always check for existing services first.
- **If the user passes arguments** (e.g., "frontend only", "backend only"), respect those directives
- **Keep the user informed** at each phase — show progress, not silence
- **Render MCP limitation**: The MCP cannot trigger deploys or delete resources. Use REST API as fallback for deploy triggers.
- **Port binding**: Backend services MUST use `$PORT` env var (Render sets this automatically). Ensure the start command binds to `0.0.0.0:$PORT`.
- **Free tier cold starts**: Render free tier services spin down after inactivity. Warn the user about this if they're on the free/starter plan.
