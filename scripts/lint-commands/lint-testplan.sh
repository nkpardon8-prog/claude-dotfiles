#!/usr/bin/env bash
# lint-testplan.sh — structural lint for commands/testplan.md.
#
# MANUAL PRE-COMMIT LINT. There is NO aggregate test runner / CI / husky in ~/.claude-dotfiles, so this
# does NOT run automatically. Run it by hand before committing a change to commands/testplan.md:
#     bash scripts/lint-commands/lint-testplan.sh
# It proves the command file is well-formed, self-consistent, and DOMAIN-AGNOSTIC (no hardcoded
# project-specific paths/symbols). It CANNOT judge whether the emitted PLANS are good — that is what the
# two worked-example dry-runs do. macOS bash 3.2 compatible.
set -u
ROOT="${1:-$HOME/.claude-dotfiles}"
F="$ROOT/commands/testplan.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
have(){ grep -qE "$1" "$F" && ok "$2" || bad "$2 [missing pattern: $1]"; }
deny(){ if grep -nE "$1" "$F" >/dev/null 2>&1; then bad "$2 [FOUND: $(grep -nE "$1" "$F" | head -1)]"; else ok "$2"; fi; }

[ -f "$F" ] || { echo "FATAL: $F not found"; exit 2; }

# --- frontmatter ---
have '^description:'   'frontmatter: description present'
have '^argument-hint:' 'frontmatter: argument-hint present'
have '^allowed-tools:' 'frontmatter: allowed-tools present'
DESC=$(sed -n 's/^description: *//p' "$F" | head -1)
WC=$(printf '%s' "$DESC" | wc -w | tr -d ' ')
{ [ -n "$WC" ] && [ "$WC" -le 45 ]; } && ok "description is crisp ($WC words <= 45)" || bad "description too long ($WC words > 45)"

# --- all five phases ---
for p in 0 1 2 3 4; do have "^## Phase $p" "Phase $p heading present"; done

# --- key mechanisms (the review-hardened contract) ---
have '### CORE'                'CORE (always-emitted) section present'
have 'Risk-gated extensions'   'risk-gated extensions section present'
have 'TIERED'                  'tiered per-item recipe present'
have 'tier-aware'              'tier-aware self-lint present'
have 'BLOCKED.*ORACLE GAP'     'blocked-oracle-gap concept present'
have 'READY.*NOT-READY'        'final READY/NOT-READY verdict present'
have 'deny-by-default'         'deny-by-default blast radius present'
have 'archetype'              'archetype classification present'
have 'ZERO'                    'zero-mutation planning stated'

# --- domain-agnostic: DENY concrete project literals (paths / code symbols / hosts) ---
deny 'projects/dentall'                              'no dentall filesystem path'
deny 'lib/api\.ts'                                   'no lib/api.ts hardcode'
deny 'withClinicContext'                             'no withClinicContext symbol'
deny 'odWriteback'                                   'no odWriteback symbol'
deny 'installFeatureGate'                            'no installFeatureGate symbol'
deny 'neon\.tech'                                    'no neon.tech host'
deny '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' 'no hardcoded IPv4 (CRD/host literal)'

# --- prose nouns (dental/OpenDental) are ALLOWED, but must be hedged as illustration ---
if grep -qiE 'dental|opendental' "$F"; then
  grep -qiE 'illustrat|example|e\.g\.|adapt' "$F" \
    && ok 'dental mentions are hedged as illustrations' \
    || bad 'dental mentioned with no illustration/example hedge'
else
  ok 'no dental mention (trivially agnostic)'
fi

echo ""
echo "==================================================="
echo "  lint-testplan:  PASS=$PASS  FAIL=$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ] || exit 1
