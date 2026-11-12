# Credential Catalog (TEMPLATE)

> **DO NOT USE THIS FILE.** This is a template that ships with the dotfiles repo.
> Your real catalog lives **outside** this synced repo at `~/.config/claude/credentials.md` — local-only, never committed.
>
> On a fresh machine: `cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md` and edit.

---

Index of API keys you use, for `/load-creds`. Env var **names** and where each value comes from — **never paste real secret values here**. No password manager or CLI is involved: values live in each project's own `.env` (or an env file you point `/load-creds` at).

## How Claude should use this file
1. Read the user's catalog at `~/.config/claude/credentials.md` (NOT this template).
2. Use the env var names below in `.env.example` so `/load-creds` can match them.
3. To populate a real `.env`: run `/load-creds`. It copies values from the project's `.env`, an env file you name (`--from`), or the shell environment; anything it cannot find is left as an empty `KEY=` line for you to paste into `.env` yourself.
4. Never echo secret values — reference by env var name only.

## Format
| Env Var | Where it comes from | Used For |

## LLM / AI

| Env Var              | Where it comes from                              | Used For                           |
|----------------------|--------------------------------------------------|------------------------------------|
| OPENAI_API_KEY       | platform.openai.com > API keys                   | OpenAI API (gpt-*, embeddings)     |
| ANTHROPIC_API_KEY    | console.anthropic.com > API keys                 | Claude API                         |
| OPENROUTER_API_KEY   | openrouter.ai > Keys                             | OpenRouter (multi-model gateway)   |
| GOOGLE_API_KEY       | aistudio.google.com > Get API key                | Gemini, Google AI Studio           |

## Supabase

| Env Var                       | Where it comes from                              | Used For              |
|-------------------------------|--------------------------------------------------|-----------------------|
| SUPABASE_URL                  | Supabase dashboard > Project Settings > API      | Project URL           |
| SUPABASE_ANON_KEY             | Supabase dashboard > Project Settings > API      | Public client key     |
| SUPABASE_SERVICE_ROLE_KEY     | Supabase dashboard > Project Settings > API      | Server-side admin key |

## Mac mini remote (CRD skill)

> CRD_DEVICE_NAME is the aria-label shown on the device tile at https://remotedesktop.google.com/access (typically the Mac mini's macOS hostname or a user-set name). The CRD PIN is never stored anywhere; you type it when the page comes up.

| Env Var               | Where it comes from                                         | Used For                                                                                                                        |
|-----------------------|-------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| CRD_DEVICE_NAME       | the device tile name on remotedesktop.google.com/access     | CRD device-tile aria-label. Often the macOS hostname; check by visiting that URL.                                               |

## (extend as you add services — DB URLs, OAuth secrets, webhook secrets, signing keys, etc.)
