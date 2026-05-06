Migrate four recursive functions in `lib/` to iterative implementations that survive deep input. The four modules are file-disjoint and roughly equal-sized:

- `lib/tree-sum.js` — recursive tree sum
- `lib/json-clone.js` — recursive deep clone (must add cycle detection)
- `lib/list-reverse.js` — recursive linked-list reverse (must preserve purity — input list not mutated)
- `lib/expr-eval.js` — recursive descent expression evaluator (with precedence and parens)

Each module's source has a header comment documenting its **contract** — preserve those exactly. The contracts include:
- Pure-input semantics (`list-reverse` must not mutate the input)
- Cycle handling (`json-clone` must throw `Error('cyclic reference')` rather than stack-overflow)
- Operator precedence (`expr-eval` must keep `*`/`/` before `+`/`-`)
- Standard-input results unchanged

Tests under `test/` pin both standard-input behavior AND a deep-input case (~50000 nodes / 10000 depth / 5000-deep parens) that the recursive version overflows on. The migrated iterative version must pass all tests including the deep cases.

Constraints:
- Stdlib only.
- Tests run via `node --test`. They must pass.
- Each `lib/*.js` must export the same public function it currently does.

Commit your work on a feature branch.

**Important:** complete this task as a single Claude session using direct file edits. Do NOT invoke the `/dual-build` skill or any parallel-agent orchestration — this is the single-agent A/B control arm. The prior phrasing about file-disjoint modules describes the codebase shape, not a workflow request.
