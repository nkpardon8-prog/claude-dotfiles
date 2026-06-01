# database-audit — Redaction Rules

This file is `Read` by the `/database-audit` orchestrator. Apply these rules during Phase 6 report assembly, before writing any report to disk.

1. **Secret values.** Replace with `[REDACTED: <first-8-of-sha256>]` any of:
   - JWT-shaped string: `eyJ[A-Za-z0-9_-]{20,}`.
   - Value after `SUPABASE_SERVICE_ROLE_KEY=`, `SUPABASE_ANON_KEY=`, `JWT_SECRET=`, `ANON_KEY=` where the value is longer than its key name.
   - **Adjacent-long-string rule** (covers non-JWT service role keys): on any line matching `service_role` or within 40 characters of any matched secret-related identifier, replace any contiguous run of 20+ characters from `[A-Za-z0-9_.+/=-]` — regardless of JWT shape.
   - Password literals in seed files: `password\s*[:=]\s*['"]?[^'"\s]+['"]?`, and common weak values (`'admin'`, `'123456'`, `'password'`, `'test'`).
2. **Policy expressions.** Include RLS `qual`/`with_check` expressions as-is but prefix the enclosing finding with `Warning: contains policy logic — handle like source code.`
3. **PII.** Never run SELECT against actual PII column values. Read column NAMES only from `information_schema`. Report mentions names, never values.
4. **Env keys.** Emit key NAMES only, never values.
5. **Connection strings.** Redact any `postgres://` or `postgresql://` connection string — including the `user:pass@host` userinfo within it — by replacing the whole URI with `[REDACTED:<first-8-of-sha256>]` (same marker format as rule 1). This applies wherever a connection string can surface: report bodies, Meta, finding text, and any error string passed through redaction. This rule fulfills the promise made by `core.md` FS.1/FS.2, which scan the working tree and tracked files for connection-string shapes and rely on this rule to scrub them before anything is written to disk. Match shape: `postgres(ql)?:\/\/[^ \t\r\n'"]+` (case-insensitive scheme). Never emit the host, user, or password from a connection string verbatim — the Meta "Connection host" line derives the bare host only after this redaction confirms no credentials accompany it.
