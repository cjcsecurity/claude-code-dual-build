#!/usr/bin/env bash
# acceptance.sh — heuristic check that all three bugs were addressed.
# Looks at the diff against main for evidence of each fix; runs `node --test` if a test runner is wired.
#
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

sandbox="${1:?sandbox path required}"
cd "$sandbox"

fail=0

# Find any branch other than main that has commits ahead of main
branch="$(git for-each-ref --format='%(refname:short)' refs/heads/ \
  | while read -r b; do
      [[ "$b" == "main" || "$b" == "master" ]] && continue
      ahead=$(git rev-list --count "main..$b" 2>/dev/null || echo 0)
      [[ "$ahead" -gt 0 ]] && { echo "$b"; break; }
    done)"

if [[ -z "$branch" ]]; then
  # Maybe they merged into main directly. Compare against initial commit.
  base=$(git rev-list --max-parents=0 HEAD)
  branch="HEAD"
  diff_range="$base..HEAD"
else
  diff_range="main...$branch"
fi

echo "Diff range: $diff_range"
diff_content="$(git diff "$diff_range" 2>/dev/null || echo '')"

# Bug 1: validation in server/index.js — must reject empty/non-string fields
if echo "$diff_content" | awk '/server\/index\.js/,/^diff --git/' | grep -qE '\b(400|status\(400\)|res\.status\(400\)|return.*400|Bad Request|missing|required|typeof.*string)'; then
  echo "✓ Bug 1 (validation) — fix detected"
else
  echo "✗ Bug 1 (validation) — no fix detected in server/index.js"
  fail=1
fi

# Bug 2: timezone fix in lib/dates.js — must use Intl.DateTimeFormat or America/Los_Angeles
if echo "$diff_content" | awk '/lib\/dates\.js/,/^diff --git/' | grep -qE '(America/Los_Angeles|timeZone|Intl\.DateTimeFormat)'; then
  echo "✓ Bug 2 (timezone) — fix detected"
else
  echo "✗ Bug 2 (timezone) — no fix detected in lib/dates.js"
  fail=1
fi

# Bug 3: debounce in public/search.js — must have setTimeout/clearTimeout or a debounce function
if echo "$diff_content" | awk '/public\/search\.js/,/^diff --git/' | grep -qE '(debounce|setTimeout|clearTimeout)'; then
  echo "✓ Bug 3 (debounce) — fix detected"
else
  echo "✗ Bug 3 (debounce) — no fix detected in public/search.js"
  fail=1
fi

# If a test command is configured, run it
if [[ -f package.json ]] && grep -q '"test"' package.json 2>/dev/null; then
  echo "Running npm test..."
  if npm test --silent 2>&1 | tail -20; then
    echo "✓ npm test — passed"
  else
    echo "✗ npm test — failed"
    fail=1
  fi
elif command -v node >/dev/null 2>&1 && find . -maxdepth 4 -name '*.test.js' -not -path './node_modules/*' | head -1 | grep -q .; then
  echo "Running node --test..."
  if node --test 2>&1 | tail -20; then
    echo "✓ node --test — passed"
  else
    echo "✗ node --test — failed"
    fail=1
  fi
else
  echo "(no tests detected)"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: all 3 fixes detected"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
