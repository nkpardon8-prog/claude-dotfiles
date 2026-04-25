# Credential Catalog

> **WARNING — references only.** This file is committed to a synced git repo.
> Never paste real secret values here. Only `op://` references and human-readable names.
> Real values live in 1Password and are resolved on-demand by `op inject`.

Index of API keys available via 1Password CLI for use by `/load-creds`.

## How Claude should use this file
1. Read this catalog when scaffolding a project that needs API keys.
2. Use the env var names below in `.env.example` so `/load-creds` can match them.
3. To populate a real `.env`: write `.env.op` with `op://` references from this file, then run `op inject -i .env.op -o .env`.
4. Never echo resolved secret values back to the user — reference by env var name only.

## Format
| Env Var | op:// Reference | Used For |

> **Edit me**: replace placeholder `op://Personal/...` paths below with the real ones from your vault.
> Discover refs with: `op item list --vault Personal` then `op item get "<item>" --format json | jq '.fields[] | {label, id}'`.
> Verify a ref with: `op read 'op://Personal/OpenAI/credential'`.

## LLM / AI

| Env Var              | op:// Reference                       | Used For                           |
|----------------------|---------------------------------------|------------------------------------|
| OPENAI_API_KEY       | op://Personal/OpenAI/credential       | OpenAI API (gpt-*, embeddings)     |
| ANTHROPIC_API_KEY    | op://Personal/Anthropic/credential    | Claude API                         |
| OPENROUTER_API_KEY   | op://Personal/OpenRouter/credential   | OpenRouter (multi-model gateway)   |
| GOOGLE_API_KEY       | op://Personal/Google AI/credential    | Gemini, Google AI Studio           |

## Supabase

| Env Var                       | op:// Reference                                  | Used For              |
|-------------------------------|--------------------------------------------------|-----------------------|
| SUPABASE_URL                  | op://Personal/Supabase Default/url               | Project URL           |
| SUPABASE_ANON_KEY             | op://Personal/Supabase Default/anon key          | Public client key     |
| SUPABASE_SERVICE_ROLE_KEY     | op://Personal/Supabase Default/service role key  | Server-side admin key |

## (extend as you add services)
