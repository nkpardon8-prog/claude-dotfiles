#!/bin/bash
# E2E test for /god-review — generates a synthetic test project with intentional
# violations across multiple principles, runs /god-review on it, asserts findings.
#
# Usage: bash ~/.claude-dotfiles/commands/god-review/lib/e2e-test.sh
# Exit 0 on pass, non-zero on fail.

set -e

TEST_DIR="/tmp/god-review-e2e-test-$$"
trap "rm -rf $TEST_DIR" EXIT

mkdir -p "$TEST_DIR" && cd "$TEST_DIR"

# 1. Initialize git repo + npm project
git init -q
git config user.email "test@god-review.local"
git config user.name "god-review-e2e"
cat > package.json << 'EOF'
{
  "name": "god-review-e2e-test",
  "version": "1.0.0",
  "dependencies": {
    "react": "^19.0.0",
    "@tanstack/react-query": "^5.0.0"
  }
}
EOF

mkdir -p src tests src/imports

# 2. Single-pattern violation: two near-identical hooks
cat > src/duplicate-hook-1.ts << 'EOF'
export function useFooData() {
  // duplicated logic
  const data = { x: 1, y: 2 };
  return { data, loading: false };
}
EOF

cat > src/duplicate-hook-2.ts << 'EOF'
export function useFooDataAgain() {
  // near-identical to useFooData
  const data = { x: 1, y: 2 };
  return { data, loading: false };
}
EOF

# 3. Clarity violation: 250-line function
{
  echo "export function bigFunction() {"
  for i in $(seq 1 245); do echo "  console.log('line $i');"; done
  echo "}"
} > src/long-function.ts

# 4. Circular-deps + late-import violation
cat > src/a.ts << 'EOF'
import { foo } from './b';
export const x = 1;
EOF
cat > src/b.ts << 'EOF'
import { x } from './a';
export const foo = 1;
EOF

# Late-import on line 51
{
  for i in $(seq 1 50); do echo "// padding line $i"; done
  echo "import { something } from './a'"
} > src/late-import.ts

# 5. TanStack-query violation: raw string queryKey
cat > src/raw-key.ts << 'EOF'
import { useQuery } from '@tanstack/react-query';
export function badHook() {
  return useQuery({ queryKey: ['raw-string-key'], queryFn: () => 1 });
}
EOF

# 6. Secret-leak violation
# Construct fake key dynamically to avoid pre-commit scanners flagging this script.
FAKE_PREFIX="sk"
FAKE_BODY="this-is-a-fake-key-for-testing-$(date +%N)"
FAKE_KEY="${FAKE_PREFIX}-${FAKE_BODY}1234567890abcdef"
echo "FAKE_KEY=${FAKE_KEY}" > .env
cat > src/leaks-secret.ts << EOF
const KEY = "${FAKE_KEY}";
console.log(KEY);
EOF

# 7. Hallucinated-imports violation
cat > src/imports/uses-nonexistent.ts << 'EOF'
import { foo } from 'this-package-does-not-exist-987654';
export const bar = foo;
EOF

# 8. Test-deletion baseline (will exist; deletion is detected via git diff)
cat > tests/example.test.ts << 'EOF'
// Example test file with 30 lines
import { describe, it, expect } from 'vitest';
describe('something', () => {
EOF
for i in $(seq 1 25); do
  echo "  it('test $i', () => { expect(1).toBe(1); });" >> tests/example.test.ts
done
echo "});" >> tests/example.test.ts

# 9. Initial commit
git add -A
git commit -q -m "initial: test project with intentional violations"

echo ""
echo "=== Synthetic test project created at $TEST_DIR ==="
echo "=== Files: ==="
find . -type f -not -path "./.git/*" | sort
echo ""

# Note: this script can't actually invoke /god-review (it's a slash command).
# It prepares the test environment. Manual step: cd into $TEST_DIR and run /god-review.
echo ""
echo "=== Next step (manual): ==="
echo "  cd $TEST_DIR"
echo "  /god-review"
echo ""
echo "=== Expected findings (PASS criteria): ==="
echo "  - At least 5 findings total"
echo "  - At least 4 of these principles fired:"
echo "    1. single-pattern (duplicate-hook-1.ts vs duplicate-hook-2.ts)"
echo "    2. clarity (long-function.ts has 250-line function)"
echo "    3. circular-deps (a.ts <-> b.ts cycle AND late-import.ts line 51)"
echo "    4. tanstack-query (raw string key in raw-key.ts)"
echo "    5. secret-leak (sk- key in leaks-secret.ts matches .env)"
echo "    6. hallucinated-imports (this-package-does-not-exist-987654 in uses-nonexistent.ts)"
echo ""
echo "=== Test directory will auto-cleanup on script exit ==="
echo "=== Set KEEP_TEST_DIR=true to preserve it instead ==="

# Optional: keep test dir for inspection by setting KEEP_TEST_DIR=true.
if [ "${KEEP_TEST_DIR:-false}" = "true" ]; then
  echo "Keeping test dir at $TEST_DIR (KEEP_TEST_DIR=true)"
  trap - EXIT  # disable the cleanup trap
fi
