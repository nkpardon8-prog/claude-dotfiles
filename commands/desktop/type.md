---
description: Type text into the focused app via cliclick. Always confirms with the user before typing.
argument-hint: "[text to type, will be confirmed]"
---

# /desktop type

Type text. Always confirms first.

## Steps

1. **Always confirm with user before typing.** Print the literal text. If it looks credential-shaped (long base64-ish blob, `sk-` prefix, `Bearer `, JWT pattern), display as `<credentials redacted — confirm value out of band>` and refuse to proceed without explicit user opt-in (this is a heuristic, not a guarantee).

2. **Execute:**
   ```bash
   cliclick t:'<text>'
   ```
   - Single-quote outer wrap.
   - Escape inner single quotes by closing/reopening: `'foo'\''bar'`.
   - Capitals and shifted symbols work natively (cliclick has no Shift-stripping).

3. **Verify** (if a visible field is expected to populate): run `/desktop shot`, vision-compare. If no visible change in the expected field → warn user the focus may have been elsewhere.

## Gotchas

- Credential redaction is best-effort heuristic. If you're not sure the value is safe, ASK.
- Text with double quotes inside is fine in single-quoted shell wrap.
- If the user wants to enter a password, prefer routing through a different mechanism (e.g., `pbcopy`-then-paste) so the value isn't echoed in transcripts.

## See also

- Screenshot primitive: `/desktop shot`
