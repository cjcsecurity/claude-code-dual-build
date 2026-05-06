#!/usr/bin/env bash
# acceptance.sh — heuristic check that all 4 audit bugs are fixed.
#
# Strategy: run the test suite. All tests must pass. (Tests fail on the
# initial scaffold; only a complete fix turns them all green.)
#
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

sandbox="${1:?sandbox path required}"
cd "$sandbox"

fail=0

# All four module files must still exist.
for f in lib/throttle.js lib/csv-parse.js lib/flatten.js lib/format.js; do
  if [[ ! -f "$f" ]]; then
    echo "✗ $f missing"
    fail=1
  fi
done

# All four test files must still exist (builders may add more, but mustn't
# delete the contract tests).
for f in test/throttle.test.js test/csv-parse.test.js test/flatten.test.js test/format.test.js; do
  if [[ ! -f "$f" ]]; then
    echo "✗ $f missing"
    fail=1
  fi
done

# Run the suite. Builders may have added more tests; that's fine — what
# matters is zero failures.
echo "Running node --test..."
test_out=$(node --test 2>&1 | tail -30)
echo "$test_out"
if echo "$test_out" | grep -qE 'pass [0-9]+' && ! echo "$test_out" | grep -qE 'fail [1-9]'; then
  echo "✓ node --test — passed"
else
  echo "✗ node --test — failed"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: all 4 audit bugs fixed, full suite green"
  exit 0
else
  echo "FAIL: see above"
  exit 1
fi
