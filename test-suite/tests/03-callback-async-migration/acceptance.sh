#!/usr/bin/env bash
# acceptance.sh — heuristic check that all 4 modules were migrated to
# async/await and the test suite still passes.
#
# Strategy: read the per-module diff against main and require each module's
# diff to (a) remove at least one `cb(` call (callback signature gone) and
# (b) add at least one `async`/`await` token. This avoids false positives
# from regex-matching the original callback files (whose comments contain
# the instruction text "async/await").
#
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

sandbox="${1:?sandbox path required}"
cd "$sandbox"

fail=0

# Find any branch other than main with commits ahead of main; if none,
# fall back to comparing HEAD against the initial commit.
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

# Per-module diff signal. Use git's pathspec rather than awk-slicing the diff
# body — `git diff -- path` gives us just the file's diff cleanly.
for f in lib/cache.js lib/file-ops.js lib/http-fetch.js lib/job-queue.js; do
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
  # Removed callback-call lines (signal that the cb-style code is gone).
  removed_cb=$(echo "$mdiff" | grep -cE '^-[[:space:]]*[^-].*\bcb\(' || true)
  # Added async-style tokens. Restrict to `+` lines so comments-only diffs
  # don't pass.
  added_async=$(echo "$mdiff" | grep -cE '^\+[[:space:]]*[^+].*\b(async|await|Promise|fs/promises|fsPromises|util\.promisify)\b' || true)
  if [[ "$removed_cb" -lt 1 ]]; then
    echo "✗ $f no callback removals in diff"
    fail=1
  elif [[ "$added_async" -lt 1 ]]; then
    echo "✗ $f no async/await/Promise additions in diff"
    fail=1
  else
    echo "✓ $f migrated (removed ${removed_cb} cb-call line(s), added ${added_async} async-token line(s))"
  fi
done

# Test files must exist and pass. Look for any *.test.js / test/*.js.
test_files=$(find . -maxdepth 4 \
  \( -path ./node_modules -prune -o -path ./.git -prune \) -o \
  \( -name '*.test.js' -print -o -name '*.test.mjs' -print \) -o \
  \( -path './test/*.js' -print -o -path './test/*.mjs' -print \) -o \
  \( -path './tests/*.js' -print -o -path './tests/*.mjs' -print \) 2>/dev/null \
  | grep -v node_modules | head -10)

if [[ -z "$test_files" ]]; then
  echo "✗ no test files found"
  fail=1
else
  echo "Running node --test (found: $(echo "$test_files" | wc -l) test file(s))..."
  test_out=$(node --test 2>&1 | tail -30)
  echo "$test_out"
  if echo "$test_out" | grep -qE 'pass [0-9]+' && ! echo "$test_out" | grep -qE 'fail [1-9]'; then
    echo "✓ node --test — passed"
  else
    echo "✗ node --test — failed"
    fail=1
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: all 4 modules migrated, tests pass"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
