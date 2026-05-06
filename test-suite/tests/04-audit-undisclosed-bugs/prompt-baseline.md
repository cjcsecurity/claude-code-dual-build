Run an audit-and-fix pass on this Node project's `lib/` directory. There are four utility modules — `throttle.js`, `csv-parse.js`, `flatten.js`, `format.js` — and a corresponding test file under `test/` for each. Some tests already pass; some fail. **The bugs are not enumerated; you must read the modules and the failing tests to identify them.**

For each module:
1. Read the source and the test file.
2. Identify the bug(s).
3. Apply a minimal fix that makes the failing tests pass.
4. Add a regression test if the existing tests don't fully pin the contract documented in the module's header comment.

Constraints:
- Stdlib only — no npm installs.
- Each module's contract is documented in its source header. Honor those contracts.
- All four modules must pass `node --test` after your fixes.

Commit your work on a feature branch.

**Important:** complete this task as a single Claude session using direct file edits. Do NOT invoke the `/dual-build` skill or any parallel-agent orchestration — this is the single-agent A/B control arm.
