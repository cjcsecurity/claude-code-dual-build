/dual-build Run an audit-and-fix pass on this Node project's `lib/` directory. There are four utility modules — `throttle.js`, `csv-parse.js`, `flatten.js`, `format.js` — and a corresponding test file under `test/` for each. Some tests already pass; some fail. **The bugs are not enumerated; you must read the modules and the failing tests to identify them.**

For each module:
1. Read the source and the test file.
2. Identify the bug(s).
3. Apply a minimal fix that makes the failing tests pass.
4. Add a regression test if the existing tests don't fully pin the contract documented in the module's header comment.

Constraints:
- Stdlib only — no npm installs.
- Each module's contract is documented in its source header. Honor those contracts.
- All four modules must pass `node --test` after your fixes.

Read the four `lib/*.js` files plus their tests, decompose into four file-disjoint subtasks (one per module), propose the split.
