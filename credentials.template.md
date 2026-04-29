# Credential Catalog (TEMPLATE)

> **DO NOT USE THIS FILE.** This is a template that ships with the dotfiles repo.
> Your real catalog lives **outside** this synced repo at `~/.config/claude/credentials.md` — local-only, never committed.
>
> On a fresh machine: `cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md` and edit.

---

Index of API keys available via 1Password CLI for use by `/load-creds`. References only — **never paste real secret values here**.

## How Claude should use this file
1. Read the user's catalog at `~/.config/claude/credentials.md` (NOT this template).
2. Use the env var names below in `.env.example` so `/load-creds` can match them.
3. To populate a real `.env`: write `.env.op` with `op://` references, then run `op inject -i .env.op -o .env` (with `--account` if multi-account).
4. Quote any `op://` reference that contains spaces when emitting `.env.op` lines: `OPENAI_API_KEY="op://My Vault/OpenAI/credential"`.
5. Never echo resolved secret values — reference by env var name only.

## Vault placeholder

The examples below use `<VAULT>` as a placeholder. Replace with your actual 1Password vault name (commonly `Personal`, `Private`, or a team vault). Discover yours with `op vault list`.

## Format
| Env Var | op:// Reference | Used For |

## LLM / AI

| Env Var              | op:// Reference                          | Used For                           |
|----------------------|------------------------------------------|------------------------------------|
| OPENAI_API_KEY       | op://<VAULT>/OpenAI/credential           | OpenAI API (gpt-*, embeddings)     |
| ANTHROPIC_API_KEY    | op://<VAULT>/Anthropic/credential        | Claude API                         |
| OPENROUTER_API_KEY   | op://<VAULT>/OpenRouter/credential       | OpenRouter (multi-model gateway)   |
| GOOGLE_API_KEY       | op://<VAULT>/Google AI/credential        | Gemini, Google AI Studio (quote on emit — has space) |

## Supabase

| Env Var                       | op:// Reference                                      | Used For              |
|-------------------------------|------------------------------------------------------|-----------------------|
| SUPABASE_URL                  | op://<VAULT>/Supabase Default/url                    | Project URL           |
| SUPABASE_ANON_KEY             | op://<VAULT>/Supabase Default/anon key               | Public client key     |
| SUPABASE_SERVICE_ROLE_KEY     | op://<VAULT>/Supabase Default/service role key       | Server-side admin key |

## Mac mini remote (CRD skill)

> CRD_PIN is set when you create the CRD device on the Mac mini. CRD_DEVICE_NAME is the aria-label shown on the device tile at https://remotedesktop.google.com/access (typically the Mac mini's macOS hostname or a user-set name).

| Env Var               | op:// Reference                          | Used For                                                                                                                                                                  |
|-----------------------|------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| CRD_PIN               | op://<VAULT>/Mac mini CRD/PIN            | 6-digit Chrome Remote Desktop connection PIN                                                                                                                              |
| CRD_DEVICE_NAME       | op://<VAULT>/Mac mini CRD/Device Name    | CRD device-tile aria-label — the name on remotedesktop.google.com/access. Often the macOS hostname; check by visiting that URL.                                           |

## (extend as you add services — DB URLs, OAuth secrets, webhook secrets, signing keys, etc.)
