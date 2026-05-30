---
description: Deep Supabase audit — schema, RLS, security, prod-readiness, client coherence. Report-only. Refuses prod without --env=prod. Optionally emits DATABASE.md. (deprecated alias for /database-audit --provider=supabase)
argument-hint: "[--only=schema,rls,security,prod,client] [--env=prod]"
expected_subagents: 4
---

# /supabase-audit (deprecated alias)

`/supabase-audit` is now a thin deprecated alias. The single source of truth is `/database-audit`. This command exists only so existing muscle memory keeps working — it forwards to `/database-audit --provider=supabase`.

## Behavior

1. Print this one-line deprecation notice to the user, exactly:

   ```
   ⚠️ /supabase-audit is deprecated — running /database-audit --provider=supabase. Update your muscle memory.
   ```

2. `Read ~/.claude-dotfiles/commands/database-audit.md` and execute it as the orchestrator, with:
   - `--provider=supabase` **forced** (always present, regardless of `$ARGUMENTS`).
   - Any `--only=<csv>` and `--env=prod` flags the user supplied in `$ARGUMENTS` passed through verbatim.
   - If the user passed `--provider=<anything>` in `$ARGUMENTS`, ignore it and force `--provider=supabase` (this alias is Supabase-only by definition).

   Effective invocation: `/database-audit --provider=supabase [pass-through --only / --env from $ARGUMENTS]`.

## Output

Output is **byte-identical to `/database-audit --provider=supabase`** (after the deprecation notice line). The report title is the provider-templated `# Database Audit — supabase — <host>` — the change from the old `# Supabase Audit` header is expected and intentional; do not try to reproduce the old title.

All guardrails (Forbidden Tools, SELECT-only, redaction, prod-stop-before-SQL, never commit/mutate, never echo connection strings/secrets) come from `database-audit.md` and its sub-files. This alias adds no logic of its own beyond the notice + forced provider.
