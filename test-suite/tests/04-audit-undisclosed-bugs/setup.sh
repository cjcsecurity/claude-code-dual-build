#!/usr/bin/env bash
# Scaffolds 4 utility modules, each with a real but UNENUMERATED bug, plus
# a test suite where some tests pass and others fail (the failing ones pin
# the bugs). The /dual-build (or baseline) run must read the modules + tests,
# identify each bug, and produce a fix.
#
# This differs from 01-bugfix-trio by NOT enumerating the bugs in the prompt —
# the builder must audit the code on its own. Cross-review value: catch
# incomplete fixes (test passes but a sibling case still fails) or additional
# issues the builder missed.
#
# The four bugs:
# - lib/throttle.js: throttle drops the trailing call. Most users want
#   leading + trailing. Test pins "trailing call must fire after the throttle
#   window if it was the latest queued call".
# - lib/csv-parse.js: doesn't handle quoted fields containing commas. Test
#   pins '"a,b",c' parses as ['a,b', 'c'].
# - lib/flatten.js: deep flatten preserves holes (sparse arrays) as
#   `undefined`. Test pins `flatten([1, [2, , 3]])` returns `[1, 2, 3]`
#   (skip holes). Buggy code produces `[1, 2, undefined, 3]`.
# - lib/format.js: simple `format(template, ...args)` substitutes `{}`
#   placeholders. Bug: when a substitution VALUE itself contains `{}`,
#   subsequent placeholders get mis-aligned. Test pins behavior on a
#   value-with-braces input.
set -euo pipefail

sandbox="${1:?sandbox path required}"
rm -rf "$sandbox"
mkdir -p "$sandbox"
cd "$sandbox"

git init -q -b main
git config user.email "test@example.com"
git config user.name "test"

npm init -y -q >/dev/null
npm pkg set type=module >/dev/null

mkdir -p lib test

# ----------------------------------------------------------------------------
# lib/throttle.js — bug: drops trailing call
# ----------------------------------------------------------------------------
cat > lib/throttle.js <<'EOF'
// throttle(fn, ms): returns a wrapped fn that runs at most once per `ms` window.
//
// Contract: a "trailing" call is a call made during a window after the leading
// call already fired. The wrapper MUST eventually invoke the wrapped fn again
// with the LATEST trailing args once the window elapses (debounce-like trail).
// If no calls happen during the window, no trailing fire occurs.
//
// Common use case: rate-limit a save-on-keystroke callback such that the user
// always sees their FINAL keystroke applied even if it landed inside a window.

export function throttle(fn, ms) {
  let last = 0;
  return function (...args) {
    const now = Date.now();
    if (now - last >= ms) {
      last = now;
      fn.apply(this, args);
    }
    // BUG: nothing schedules a trailing call for the latest args.
  };
}
EOF

# ----------------------------------------------------------------------------
# lib/csv-parse.js — bug: doesn't handle quoted fields containing commas
# ----------------------------------------------------------------------------
cat > lib/csv-parse.js <<'EOF'
// parseLine(line): parses a single CSV line into an array of fields.
//
// Contract: supports double-quoted fields. Within a quoted field, commas are
// literal (NOT field separators), and a doubled quote ("") is a literal
// quote. Empty fields are preserved.
//
// Examples:
//   parseLine('a,b,c')           => ['a', 'b', 'c']
//   parseLine('"a,b",c')         => ['a,b', 'c']      // quoted comma is literal
//   parseLine('a,"b ""c"" d",e') => ['a', 'b "c" d', 'e']
//   parseLine('a,,b')            => ['a', '', 'b']

export function parseLine(line) {
  // BUG: naive split on comma; doesn't honor quotes.
  return line.split(',');
}
EOF

# ----------------------------------------------------------------------------
# lib/flatten.js — bug: preserves holes in sparse arrays as `undefined`
# ----------------------------------------------------------------------------
cat > lib/flatten.js <<'EOF'
// flatten(arr): deeply flattens nested arrays.
//
// Contract: holes in sparse arrays are SKIPPED, not emitted as undefined.
// (Matches Array.prototype.flat behavior.)
//
// Examples:
//   flatten([1, [2, 3]])         => [1, 2, 3]
//   flatten([1, [2, [3, [4]]]])  => [1, 2, 3, 4]
//   flatten([1, [2, , 3]])       => [1, 2, 3]   // hole skipped, NOT undefined
//   flatten([1, [2, undefined]]) => [1, 2, undefined]  // explicit undefined preserved
//
// Hint: Array.prototype.forEach skips holes; for-of and spread do not.

export function flatten(arr) {
  const out = [];
  // BUG: `for (const item of arr)` includes holes as `undefined`.
  for (const item of arr) {
    if (Array.isArray(item)) {
      out.push(...flatten(item));
    } else {
      out.push(item);
    }
  }
  return out;
}
EOF

# ----------------------------------------------------------------------------
# lib/format.js — bug: substitution values containing {} mis-align later ones
# ----------------------------------------------------------------------------
cat > lib/format.js <<'EOF'
// format(template, ...args): substitutes `{}` placeholders left-to-right with
// args, stringified.
//
// Contract: a substitution VALUE that itself contains `{}` must NOT consume
// later placeholders. I.e., substitution is a single pass over the template,
// not iterative.
//
// Examples:
//   format('hello {}', 'world')        => 'hello world'
//   format('{} + {} = {}', 1, 2, 3)    => '1 + 2 = 3'
//   format('user said {}, then {}', '{}', '!')  => 'user said {}, then !'
//                                                  ^^^^^^^^^^^^^^^^^^^^^^
//   The `{}` from the first arg must NOT be re-substituted with '!'.

export function format(template, ...args) {
  // BUG: replaceAll replaces ALL occurrences each iteration, including ones
  // introduced by the substitution itself. Subsequent args find nothing to
  // replace OR misalign onto an earlier-substituted `{}`.
  let out = template;
  for (const arg of args) {
    out = out.replace('{}', String(arg));
  }
  return out;
}
EOF

# ----------------------------------------------------------------------------
# Tests: pin the contracts. Some pass against the buggy code (basic cases),
# others fail (edge cases that surface the bug). Each module gets its own
# test file so per-task test execution is clean.
# ----------------------------------------------------------------------------
cat > test/throttle.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { throttle } from '../lib/throttle.js';

test('throttle: leading call fires immediately', (_, done) => {
  const calls = [];
  const t = throttle((x) => calls.push(x), 50);
  t('a');
  setImmediate(() => {
    assert.deepEqual(calls, ['a']);
    done();
  });
});

test('throttle: trailing call eventually fires after the window', async () => {
  const calls = [];
  const t = throttle((x) => calls.push(x), 50);
  t('a');           // leading -> fires immediately
  t('b');           // trailing-1 (dropped or queued)
  t('c');           // trailing-2 (must be the eventual trailing fire)
  await new Promise((r) => setTimeout(r, 150));
  // Contract: the LATEST trailing call must fire after the window.
  assert.deepEqual(calls, ['a', 'c']);
});
EOF

cat > test/csv-parse.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseLine } from '../lib/csv-parse.js';

test('csv-parse: simple comma-separated', () => {
  assert.deepEqual(parseLine('a,b,c'), ['a', 'b', 'c']);
});

test('csv-parse: empty fields preserved', () => {
  assert.deepEqual(parseLine('a,,b'), ['a', '', 'b']);
});

test('csv-parse: quoted field with comma is one field', () => {
  assert.deepEqual(parseLine('"a,b",c'), ['a,b', 'c']);
});

test('csv-parse: quoted field with doubled-quote is literal quote', () => {
  assert.deepEqual(parseLine('a,"b ""c"" d",e'), ['a', 'b "c" d', 'e']);
});
EOF

cat > test/flatten.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { flatten } from '../lib/flatten.js';

test('flatten: simple nesting', () => {
  assert.deepEqual(flatten([1, [2, 3]]), [1, 2, 3]);
});

test('flatten: deep nesting', () => {
  assert.deepEqual(flatten([1, [2, [3, [4]]]]), [1, 2, 3, 4]);
});

test('flatten: holes in sparse arrays are skipped (not undefined)', () => {
  // eslint-disable-next-line no-sparse-arrays
  const sparse = [1, [2, , 3]];
  assert.deepEqual(flatten(sparse), [1, 2, 3]);
});

test('flatten: explicit undefined IS preserved', () => {
  assert.deepEqual(flatten([1, [2, undefined]]), [1, 2, undefined]);
});
EOF

cat > test/format.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { format } from '../lib/format.js';

test('format: basic substitution', () => {
  assert.equal(format('hello {}', 'world'), 'hello world');
});

test('format: multiple substitutions in order', () => {
  assert.equal(format('{} + {} = {}', 1, 2, 3), '1 + 2 = 3');
});

test('format: substitution value containing {} does not consume later placeholders', () => {
  assert.equal(format('user said {}, then {}', '{}', '!'), 'user said {}, then !');
});
EOF

# ----------------------------------------------------------------------------
# package.json scripts
# ----------------------------------------------------------------------------
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json'));
pkg.scripts = pkg.scripts || {};
pkg.scripts.test = 'node --test';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"

git add .
git commit -qm "initial: 4 utility modules with undisclosed bugs + test suite (some tests fail)"

echo "Scaffolded audit-undisclosed-bugs project at $sandbox"
