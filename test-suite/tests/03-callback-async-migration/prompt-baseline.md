Migrate four callback-style helper modules in `lib/` to async/await. The four modules are file-disjoint and roughly equal-sized:

- `lib/cache.js` — in-memory TTL cache (~45 LOC)
- `lib/file-ops.js` — JSON file I/O with atomic-write (~55 LOC)
- `lib/http-fetch.js` — HTTP JSON GET with timeout (~50 LOC)
- `lib/job-queue.js` — sequential job runner with cancel (~50 LOC)

Each module's source has a header comment documenting its **contract notes** — preserve those exactly. They include things like "missing key returns null, not error", "ENOENT returns defaults", "callback invoked at most once", "halt on first error", etc. The contracts are what callers rely on; mechanical promisify can break them.

For each module, also update `test/baseline.test.js` (or replace it with per-module test files) to exercise the migrated async API. The migrated tests must still cover the contracts the existing baseline tests cover, plus any additional contracts spelled out in the source comments that the baseline tests don't currently exercise.

Constraints:
- No external dependencies beyond what's in `package.json` and the Node stdlib (`util.promisify`, `fs/promises`, `AbortController` are fair game).
- After migration, no exported function in `lib/` should accept a callback. They should be `async` functions or return Promises.
- Tests run via `node --test`. They must pass.

Commit your work on a feature branch.

**Important:** complete this task as a single Claude session using direct file edits. Do NOT invoke the `/dual-build` skill or any parallel-agent orchestration — this is the single-agent A/B control arm. The prior phrasing about file-disjoint modules describes the codebase shape, not a workflow request.
