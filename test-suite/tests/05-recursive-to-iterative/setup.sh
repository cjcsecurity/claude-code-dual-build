#!/usr/bin/env bash
# Scaffolds 4 functions implemented recursively that overflow the stack on
# deep input. Convert each to iterative. Each conversion has its own
# subtle preserve-this gotcha that mechanical "while-loop with explicit
# stack" can break.
#
# - lib/tree-sum.js: recursive tree-sum. Node = { value, children: [] }.
#   Bug surface for naive iterative: pre-order traversal order matters
#   for some downstream consumers (one of the tests pins traversal order).
# - lib/json-clone.js: recursive deep clone. Naive iterative loses the
#   parent-link reconstruction; gotcha is preserving identity of repeated
#   subtrees? No — simpler: handle cyclic references (rejection contract).
#   The test pins that cyclic input throws a documented error rather than
#   stack-overflowing.
# - lib/list-reverse.js: linked-list reverse via head recursion. Naive
#   iterative is straightforward. Gotcha: the function returns the new
#   HEAD; the OLD list's mutability state must be preserved (or not — the
#   contract is "pure: returns new head, leaves input untouched"). Tests
#   pin this.
# - lib/expr-eval.js: recursive descent evaluator for ((1+2)*3) style
#   expressions. Iterative version needs an explicit operator+operand
#   stack. Gotcha: precedence preservation (+/- vs */). Tests pin
#   precedence + parens.
#
# All 4 must avoid stack overflow at depth ~50000. Tests assert that
# (a) deep input doesn't throw RangeError, and (b) standard-input behavior
# is unchanged.
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
# lib/tree-sum.js — recursive sum of a tree
# ----------------------------------------------------------------------------
cat > lib/tree-sum.js <<'EOF'
// Sum the values in a tree where each node is { value: number, children: Node[] }.
//
// Contract:
// - Returns the sum of all node `value` fields.
// - Empty children array is a leaf; sum is just the node's value.
// - Must NOT throw RangeError on a 50000-deep linear chain (i.e., must be
//   converted to an iterative form for deep inputs).
// - When the test in test/tree-sum.test.js exercises a 50000-deep chain,
//   the recursive version below stack-overflows. The migrated iterative
//   version must complete it.
//
// Migrate to an iterative implementation that preserves the contract.

export function treeSum(node) {
  let total = node.value;
  for (const child of node.children) {
    total += treeSum(child);
  }
  return total;
}
EOF

# ----------------------------------------------------------------------------
# lib/json-clone.js — recursive deep clone, must reject cycles
# ----------------------------------------------------------------------------
cat > lib/json-clone.js <<'EOF'
// Deep-clone a JSON-compatible value (object, array, string, number, boolean,
// null). Functions/Symbols/undefined are not supported.
//
// Contract:
// - Returns a structural clone — no shared references with the input.
// - Cyclic input MUST throw `Error('cyclic reference')`. (NOT silently
//   stack-overflow.)
// - Must complete on a 10000-deep nested object/array without RangeError.
//
// The recursive version below does NOT detect cycles — a cyclic input
// stack-overflows. The migrated iterative version must (a) detect cycles
// and throw the documented error, and (b) handle deep input.

export function jsonClone(value) {
  if (value === null) return null;
  if (typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(jsonClone);
  const out = {};
  for (const k of Object.keys(value)) out[k] = jsonClone(value[k]);
  return out;
}
EOF

# ----------------------------------------------------------------------------
# lib/list-reverse.js — recursive linked-list reverse
# ----------------------------------------------------------------------------
cat > lib/list-reverse.js <<'EOF'
// Reverse a singly-linked list and return the new head.
//
// Node shape: { value: any, next: Node | null }.
//
// Contract:
// - Returns a new head pointing at the last node of the input list.
// - Pure: the input list is NOT mutated. (i.e., after calling reverse(head),
//   walking from `head` still produces the original sequence.)
// - reverse(null) returns null; reverse(single-node-list) returns that node
//   unchanged.
// - Must complete on a 50000-long list without RangeError.
//
// The recursive version below mutates the input (sets node.next during
// recursion) AND stack-overflows on long lists. The migrated iterative
// version must preserve purity AND handle 50000-long input.

export function reverse(head) {
  if (head === null || head.next === null) return head;
  const newHead = reverse(head.next);
  head.next.next = head;
  head.next = null;
  return newHead;
}
EOF

# ----------------------------------------------------------------------------
# lib/expr-eval.js — recursive descent expression evaluator
# ----------------------------------------------------------------------------
cat > lib/expr-eval.js <<'EOF'
// Evaluate a simple integer expression with +, -, *, / and parentheses.
//
// Grammar:
//   expr   = term ( ('+' | '-') term )*
//   term   = factor ( ('*' | '/') factor )*
//   factor = INT | '(' expr ')'
//
// Contract:
// - Standard arithmetic with operator precedence (* and / before + and -).
// - Integer division (truncating toward zero; only positive divisors tested).
// - No unary minus support; expressions are non-negative integers.
// - Whitespace ignored.
// - Throws Error('parse error') on malformed input.
// - Must complete on `((((((...((1))...))))))` 5000-deep without RangeError.
//
// The recursive descent below works for shallow inputs but stack-overflows
// at depth. Migrate to a non-recursive evaluator (e.g., shunting-yard,
// or explicit operand+operator stacks) that preserves all contracts.

let pos = 0;
let src = '';

function skip() { while (pos < src.length && src[pos] === ' ') pos++; }
function peek() { skip(); return src[pos]; }
function eat(ch) {
  skip();
  if (src[pos] !== ch) throw new Error('parse error');
  pos++;
}

function parseFactor() {
  skip();
  if (src[pos] === '(') {
    pos++;
    const v = parseExpr();
    eat(')');
    return v;
  }
  let n = '';
  while (pos < src.length && src[pos] >= '0' && src[pos] <= '9') {
    n += src[pos++];
  }
  if (!n) throw new Error('parse error');
  return parseInt(n, 10);
}

function parseTerm() {
  let v = parseFactor();
  while (true) {
    const c = peek();
    if (c === '*') { pos++; v = v * parseFactor(); }
    else if (c === '/') { pos++; v = Math.trunc(v / parseFactor()); }
    else break;
  }
  return v;
}

function parseExpr() {
  let v = parseTerm();
  while (true) {
    const c = peek();
    if (c === '+') { pos++; v = v + parseTerm(); }
    else if (c === '-') { pos++; v = v - parseTerm(); }
    else break;
  }
  return v;
}

export function evaluate(input) {
  pos = 0;
  src = input;
  const v = parseExpr();
  skip();
  if (pos !== src.length) throw new Error('parse error');
  return v;
}
EOF

# ----------------------------------------------------------------------------
# Tests pinning standard-input behavior PLUS deep-input no-stack-overflow.
# ----------------------------------------------------------------------------
cat > test/tree-sum.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { treeSum } from '../lib/tree-sum.js';

test('treeSum: leaf', () => {
  assert.equal(treeSum({ value: 5, children: [] }), 5);
});

test('treeSum: balanced tree', () => {
  const t = { value: 1, children: [
    { value: 2, children: [{ value: 4, children: [] }] },
    { value: 3, children: [] },
  ]};
  assert.equal(treeSum(t), 10);
});

test('treeSum: deep linear chain (50000 deep) does not stack-overflow', () => {
  // Build a 50000-deep chain.
  let leaf = { value: 1, children: [] };
  for (let i = 0; i < 50000; i++) {
    leaf = { value: 1, children: [leaf] };
  }
  assert.equal(treeSum(leaf), 50001);
});
EOF

cat > test/json-clone.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { jsonClone } from '../lib/json-clone.js';

test('jsonClone: primitive passthrough', () => {
  assert.equal(jsonClone(42), 42);
  assert.equal(jsonClone('hi'), 'hi');
  assert.equal(jsonClone(null), null);
  assert.equal(jsonClone(true), true);
});

test('jsonClone: nested object is structural copy (no shared refs)', () => {
  const o = { a: { b: { c: 1 } }, d: [1, 2, { e: 3 }] };
  const c = jsonClone(o);
  assert.deepEqual(c, o);
  assert.notEqual(c, o);
  assert.notEqual(c.a, o.a);
  assert.notEqual(c.a.b, o.a.b);
  assert.notEqual(c.d, o.d);
  assert.notEqual(c.d[2], o.d[2]);
});

test('jsonClone: cyclic reference throws Error("cyclic reference")', () => {
  const o = { a: 1 };
  o.self = o;
  assert.throws(() => jsonClone(o), { message: 'cyclic reference' });
});

test('jsonClone: deep nested object (10000 deep) does not stack-overflow', () => {
  let cur = { v: 1 };
  for (let i = 0; i < 10000; i++) cur = { next: cur };
  const cloned = jsonClone(cur);
  // Spot-check: walk to the bottom and confirm v=1.
  let node = cloned;
  while (node.next) node = node.next;
  assert.equal(node.v, 1);
});
EOF

cat > test/list-reverse.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { reverse } from '../lib/list-reverse.js';

function toArray(head) {
  const out = [];
  while (head) { out.push(head.value); head = head.next; }
  return out;
}
function fromArray(arr) {
  let head = null;
  for (let i = arr.length - 1; i >= 0; i--) head = { value: arr[i], next: head };
  return head;
}

test('reverse: null and single-node passthrough', () => {
  assert.equal(reverse(null), null);
  const single = { value: 1, next: null };
  assert.equal(reverse(single), single);
});

test('reverse: 3-node list', () => {
  const head = fromArray([1, 2, 3]);
  const newHead = reverse(head);
  assert.deepEqual(toArray(newHead), [3, 2, 1]);
});

test('reverse: input list is NOT mutated (purity)', () => {
  const head = fromArray([1, 2, 3]);
  reverse(head);
  // Walking from `head` should still produce [1, 2, 3].
  assert.deepEqual(toArray(head), [1, 2, 3]);
});

test('reverse: 50000-long list does not stack-overflow', () => {
  const arr = Array.from({ length: 50000 }, (_, i) => i);
  const head = fromArray(arr);
  const newHead = reverse(head);
  // Spot-check first and last.
  assert.equal(newHead.value, 49999);
  let last = newHead;
  while (last.next) last = last.next;
  assert.equal(last.value, 0);
});
EOF

cat > test/expr-eval.test.js <<'EOF'
import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluate } from '../lib/expr-eval.js';

test('expr-eval: addition', () => {
  assert.equal(evaluate('1 + 2'), 3);
});

test('expr-eval: precedence', () => {
  assert.equal(evaluate('2 + 3 * 4'), 14);
  assert.equal(evaluate('(2 + 3) * 4'), 20);
});

test('expr-eval: division is integer-truncating', () => {
  assert.equal(evaluate('7 / 2'), 3);
  assert.equal(evaluate('9 / 4'), 2);
});

test('expr-eval: malformed input throws "parse error"', () => {
  assert.throws(() => evaluate('1 +'),  { message: 'parse error' });
  assert.throws(() => evaluate('(1+2'), { message: 'parse error' });
  assert.throws(() => evaluate(''),     { message: 'parse error' });
});

test('expr-eval: 5000-deep parens does not stack-overflow', () => {
  const open = '('.repeat(5000);
  const close = ')'.repeat(5000);
  assert.equal(evaluate(`${open}1${close}`), 1);
});
EOF

# ----------------------------------------------------------------------------
# Note: sub-7 tests use Math.trunc semantic for negative division. -7/2 with
# Math.trunc is -3 (round toward zero), with Math.floor is -4. Contract picks
# Math.trunc.
#
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
git commit -qm "initial: 4 recursive functions + tests pinning correctness AND deep-input stack survival"

echo "Scaffolded recursive-to-iterative project at $sandbox"
