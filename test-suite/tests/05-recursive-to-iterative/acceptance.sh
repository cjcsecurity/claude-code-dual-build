#!/usr/bin/env bash
# acceptance.sh — heuristic check that all 4 recursive functions are
# migrated to iterative form and the deep-input tests pass.
#
# Strategy: each module's diff against the base must (a) remove or replace
# the recursive self-call, and (b) add iterative-shape tokens (while/for/
# stack/queue). Plus the full `node --test` suite must be green (which
# includes the deep-input tests).
#
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

sandbox="${1:?sandbox path required}"
cd "$sandbox"

fail=0

# Find any branch other than main with commits ahead of main.
branch="$(git for-each-ref --format='%(refname:short)' refs/heads/ \
  | while read -r b; do
      [[ "$b" == "main" || "$b" == "master" ]] && continue
      ahead=$(git rev-list --count "main..$b" 2>/dev/null || echo 0)
      [[ "$ahead" -gt 0 ]] && { echo "$b"; break; }
    done)"

if [[ -z "$branch" ]]; then
  base=$(git rev-list --max-parents=0 HEAD)
  branch="HEAD"
  diff_range="$base..HEAD"
else
  diff_range="main...$branch"
fi

echo "Diff range: $diff_range"

# Each module must have a non-trivial migration: at least one removed line
# AND at least one added iterative-shape token.
for f in lib/tree-sum.js lib/json-clone.js lib/list-reverse.js lib/expr-eval.js; do
  if [[ ! -f "$f" ]]; then
    echo "✗ $f missing"
    fail=1
    continue
  fi
  mdiff="$(git diff "$diff_range" -- "$f" 2>/dev/null || echo '')"
  if [[ -z "$mdiff" ]]; then
    echo "✗ $f no diff against base — not migrated"
    fail=1
    continue
  fi
  removed=$(echo "$mdiff" | grep -cE '^-[[:space:]]*[^-]' || true)
  added_iter=$(echo "$mdiff" | grep -cE '^\+[[:space:]]*[^+].*\b(while|for[[:space:]]*\(|stack|queue|push|pop|shift|unshift)\b' || true)
  if [[ "$removed" -lt 1 ]]; then
    echo "✗ $f no removals in diff"
    fail=1
  elif [[ "$added_iter" -lt 1 ]]; then
    echo "✗ $f no iterative tokens (while/for/stack/queue/push/pop) in additions"
    fail=1
  else
    echo "✓ $f migrated (removed ${removed} line(s), added ${added_iter} iterative-token line(s))"
  fi
done

# Full suite must pass — that's the deep-input gate.
echo "Running node --test..."
test_out=$(node --test 2>&1 | tail -30)
echo "$test_out"
if echo "$test_out" | grep -qE 'pass [0-9]+' && ! echo "$test_out" | grep -qE 'fail [1-9]'; then
  echo "✓ node --test — passed (including deep-input tests)"
else
  echo "✗ node --test — failed"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: all 4 modules iterative, deep-input tests green"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
