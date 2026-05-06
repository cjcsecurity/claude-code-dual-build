# /dual-build — when cross-review earns its keep (and when it doesn't)

Real findings from runs of `/dual-build` on actual codebases. Two sections:

1. **Cross-review catches** — when a fresh-eyes reviewer from the opposite model family flagged something the builder missed. These are the load-bearing artifacts for the workflow's value proposition.
2. **Negative results** — when the workflow ran cleanly but produced nothing actionable. These are the honest other half: cross-review on textbook fixes is theatre, and the workflow's bail criteria exist to avoid those runs. Showing both sides is the credible thing to do.

If you're evaluating whether `/dual-build` is the right tool for your task, read both sections — the "when it doesn't" cases are how you calibrate the bail criteria.

---

## Cross-review catches

### #1 — mission-control · Apps Stop button (2026-05-05)

**Project**: a local Next.js 14 dashboard (`mission-control`) for monitoring command-spawned and systemd-managed apps.

**Task**: implement a Stop button that kills command-spawned processes or stops systemd units, parallel to the existing Start button.

**Builder**: Codex (codex-builder)
**Reviewer**: Claude (claude-reviewer)
**LOC**: ~100 across `lib/apps.ts`, `app/apps/page.tsx`, `app/api/apps/[id]/stop/route.ts` (new)

#### Finding 1 — Important: SIGKILL → ESRCH race

The builder's stop logic polled the port for 5 seconds via `waitForPortToClose`, then unconditionally sent SIGKILL on timeout. The reviewer noticed:

> A process can die at t=4.9s while the kernel keeps the port in TIME_WAIT briefly afterward. The poll then "times out" even though the process is gone, and the SIGKILL targets a dead PID — `process.kill()` throws ESRCH, which the calling code surfaces to the user as a "stop failed" error despite the process having actually exited cleanly.

**Why a single-agent flow would have missed it**: the implementing model wrote both the polling logic and the SIGKILL fallback in one pass. The deadline path (poll-times-out-but-process-already-died) is exactly the kind of race that requires fresh eyes to spot. The reviewer came at the diff cold and traced the lifecycle.

#### Finding 2 — Important: `ss` failure paths leak raw error strings

The stop helper used `execFileSync('ss', '-tlnp', ...)`. The reviewer flagged two distinct UX failures:

1. If `ss` is missing on the system or exits non-zero, `execFileSync` throws `Error: Command failed: ss …`. This raw error reaches the API consumer instead of a user-readable "stop helper unavailable" message.
2. When the listening port is held by a *different* user's process, `ss -tlnp` doesn't include the `pid=<n>` field (the kernel doesn't expose other users' PIDs to non-root). The code's "no `pid=` found" branch returns "No process found listening on port X" — actively misleading, since the port IS in use, just by an unowned process.

**Why a single-agent flow would have missed it**: `ss`'s permission model (privilege-gated PID disclosure) is exactly the kind of platform detail that's easy to assume away when implementing. The fresh-eyes reviewer specifically considered "what if the port is held but `ss` doesn't show pid=" as an edge case worth checking.

#### Verifiability

Both findings are reproducible and concrete: a SIGTERM-signaled child that exits during the polling window, and a port held by another user (try `python3 -m http.server 8080` as a different user, then run the stop endpoint as your user). Both bugs would have shipped under a single-agent flow.

---

### #2 — pastebin test-suite run (2026-05-06) — caught a real bug, *with a footnote*

**Test fixture**: greenfield markdown pastebin scaffold (`test-suite/tests/02-pastebin/`). Empty repo with `express`, `better-sqlite3`, `marked` installed; build the whole app from scratch.

**Run**: A/B harness, both modes PASSED acceptance.

| Metric | Dual-build | Baseline |
|---|---|---|
| Acceptance | PASS | PASS |
| Wall time | 1214s (~20 min) | 309s (~5 min) |
| LOC | 362 across 5 files | 309 across 4 files |
| Cross-review findings | **0 Critical, 4 Important (3 real, 1 false positive)** | n/a |

#### What cross-review caught (Codex reviewing Claude's T2 server work)

> "Malformed JSON and body-limit errors will fall through to Express/finalhandler, which under the default `NODE_ENV=development` returns HTML with `err.stack`, violating the API JSON/error-leak expectations."

The dual-build builder shipped this fix: explicit 400/413 JSON responses for `entity.parse.failed` and `entity.too.large` in `src/server.js:18-33`. Real bug, real shippable fix, real production-relevant security/UX issue.

#### The footnote — what the LLM judge noticed

The judge ran `evaluate.sh` on both runs and flagged something the retros missed:

> *"The baseline never had that bug. Look at `sandbox-baseline/src/server.js:80-83`: the baseline ships a generic 4-arg JSON error handler from the start, so malformed JSON / oversized bodies return JSON 500 rather than HTML stack — no leak. The single-agent build naturally avoided the issue because it held the whole API surface in one head; the dual-build introduced it via task decomposition (T2 written against a contract, no body-parser-error pathway considered) and then the cross-review fixed it. Net cross-review value here ≈ recovering from a self-inflicted decomposition bug, not catching something a single agent would have shipped."*

Plus, baseline produced UX polish dual-build missed:

- `language_hint` auto-fences raw code → highlighted block
- Slug-shape regex guard (`^[a-z0-9]{4,16}$`) → `/favicon.ico` doesn't hit the DB
- Custom slug alphabet excluding `l`/`1`/`o`/`0`
- `pragma journal_mode = WAL`
- Strict `expires_in_hours` allowlist (`['1','24','168','never']`)

These are **cross-cutting design decisions** a single head naturally produces while holding the whole API surface in mind. Dual-build's three coordinated agents working from a written contract missed them. The judge's verdict: **baseline better**.

#### What this calibrates

The bail criterion that v0.2.4 added based on this run:

> **Tightly-coupled-by-design components** — even when file-disjoint, if design decisions span all subtasks (renderer behavior depends on API validation; all layers share an error-shape contract invented during the build), single-agent context produces *better* cross-cutting decisions than coordinated agents working from a pre-written contract. Cross-review catches decomposition damage but doesn't restore the cross-cutting design insight that was lost in the split.

The other two skill improvements this run drove (also in v0.2.4):

1. **Reviewers must NOT assert on cross-task wiring.** The Codex reviewer of T2 falsely claimed `cleanupExpired()` was never called when it lives in T1's worktree — structurally inevitable from single-worktree review. Reviewer prompts now explicitly forbid the assertion and route it to "cross-task contract — orchestrator spot-check on merge" instead.
2. **codex-builder no longer attempts `git commit`.** The read-only-fs failure has now hit 4+ runs reliably. Codex builders stop after edits and the orchestrator commits routinely. Stage 1.6 reframed as standard flow, not recovery.

---

### #3 — callback → async/await migration test fixture (2026-05-06) — clean A/B win, demonstrable post-deploy

**Test fixture**: greenfield Node project with four callback-style helper modules in `lib/` (`cache.js`, `file-ops.js`, `http-fetch.js`, `job-queue.js`), each ~50 LOC, ~200 LOC total. Each module's source has header-comment "contract notes" specifying invariants that mechanical promisify can break (ENOENT→null, at-most-once settlement, tmp cleanup on rename failure, halt-on-error in the queue, cancel between iterations). See `test-suite/tests/03-callback-async-migration/`.

**Run shape**: A/B harness, both arms produced working code. Baseline rerun was needed because the original baseline auto-invoked `/dual-build` from the description match — the baseline prompt now explicitly forbids skill invocation. (See "What this run also calibrated" below.)

| Metric | Dual-build | Baseline (rerun) |
|---|---|---|
| Acceptance | PASS (35/35 tests) | FAIL (24/25; flaky timeout test, see below) |
| Wall time | ~25 min wall (harness reported 2400s, hit timeout flush after work was on disk) | 258s |
| Subagent dispatches | 8 (4 builders + 4 reviewers) | 0 |
| Cross-review findings | **0 Critical, 1 Important across 4 tasks** | n/a |
| LLM-judge verdict | **dual-build clearly better** (`evaluate.sh` run on the consolidated results dir) | n/a |

#### Finding 1 — Important: NaN slips past `typeof === 'number'` validation (T3 / `http-fetch.js`)

The Claude builder for T3 wrote (verbatim):

```js
if (!opts || typeof opts.timeoutMs !== 'number' || opts.timeoutMs <= 0) {
  throw new Error('opts.timeoutMs must be positive number');
}
```

The Codex reviewer flagged this with score 86:

> "`NaN` passes validation even though it is not `> 0`, violating the documented contract `opts.timeoutMs required and > 0 — otherwise reject with Error('opts.timeoutMs must be positive number')`. For `NaN`, both checks are false (`typeof NaN === 'number'` is true, and `NaN <= 0` is false), so the function proceeds into `setTimeout` instead of rejecting with the documented validation error. Suggested fix: use `!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0`, and add a `NaN` test."

The fix landed in the worktree before merge (`lib/http-fetch.js:24`):

```js
if (!opts || !Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) {
  throw new Error('opts.timeoutMs must be positive number');
}
```

Plus a NaN/Infinity test at `test/http-fetch.test.js:117`.

**Why a single-agent flow would have missed it**: the baseline rerun (single-agent Claude opus-4-7) shipped the **identical buggy pattern** at `baseline/sandbox/lib/http-fetch.js:18`, *and* its test suite contains zero `NaN` or `isFinite` references. Verified directly:

```
$ node -e "import('./lib/http-fetch.js').then(m => m.fetchJSON('http://127.0.0.1:1', { timeoutMs: NaN }).then(v=>console.log('OK:',v), e=>console.log('REJ:',e.message)))"
# baseline:    REJ: timeout                        ← silently treats NaN as ~1ms, contract violated
# dual-build:  REJ: opts.timeoutMs must be positive number   ← contract honored
```

Same starter, same prompt, same model class on both sides — the only difference is the cross-review pass. Single-agent didn't catch it. Cross-review did. The test the single-agent wrote wouldn't have caught it post-deploy either; this would have shipped.

#### Finding 2 — bonus: dual-build wrote a more rigorous timeout test

Not a Critical/Important finding per the framework, but worth noting because it shows up in the acceptance asymmetry.

- **Baseline timeout test** (`test/http-fetch.test.js:75-87`): connects to `http://127.0.0.1:1/x` with `timeoutMs: 1` and asserts the rejection matches `/timeout/`. This is racy: on a fast host, `connect ECONNREFUSED` returns before 1ms elapses and the assertion fails with `'connect ECONNREFUSED 127.0.0.1:1'` instead. The test passed on the migration host but fails on this host on subsequent runs — the acceptance check on the consolidated results dir flipped to FAIL because of it.
- **Dual-build timeout test** (`test/http-fetch.test.js:59-87`): spins up a real `http.createServer` whose handler sleeps past `timeoutMs` before responding, then asserts the rejection. No race against transport timing.

Same task, same prompt, same model, but dual-build's rigor on the test path was higher. Plausible mechanism: T3's reviewer specifically flagged "add a NaN test", which lifted the bar on the whole `test/http-fetch.test.js` quality.

The LLM judge surfaced a related symmetric observation worth pinning: the baseline retro confidently described its own port-1 timeout test as *"deterministically triggers the timeout-then-error race."* It does not — that's the kind of confidently-wrong self-assessment cross-review exists to backstop. Single-agent's blind spot is also "didn't notice it had a blind spot."

Honesty cuts both ways: the judge noted the baseline's `job-queue.js` `while(true)` rewrite is slightly *cleaner* than dual-build's equivalent. The win is on contract correctness and test rigor, not across-the-board code quality.

#### Verifiability

Reproducible from `test-suite/tests/03-callback-async-migration/setup.sh`. Run the A/B with `DUAL_BUILD_TIMEOUT=2400 ./run-tests.sh callback-async-migration` and inspect both `sandbox-dual-build/lib/http-fetch.js` and `sandbox-baseline/lib/http-fetch.js`. The NaN exploit one-liner above runs against both directly and shows the divergence in 2 seconds.

#### What this run also calibrated

1. **Baseline prompts must explicitly suppress `/dual-build` auto-invocation when the task description matches the skill's "use when" criteria.** The first baseline run in this fixture auto-invoked `/dual-build` from the description match (multi-file file-disjoint refactor with parallel slices), then `claude -p` exited cleanly during the Stage 0 confirmation pause without doing any work — a non-interactive session can't satisfy the pause. Fixture's `prompt-baseline.md` now closes with: *"Important: complete this task as a single Claude session using direct file edits. Do NOT invoke the `/dual-build` skill or any parallel-agent orchestration — this is the single-agent A/B control arm. The prior phrasing about file-disjoint modules describes the codebase shape, not a workflow request."* Without this, baseline runs on shapes that match the skill description silently no-op.
2. **The "T1 owns the deletion of a shared baseline test file" pattern leaves sibling worktrees in a state where the full suite hangs.** When T1's worktree deletes `test/baseline.test.js` (which imports the *callback* APIs of all four modules), the other three worktrees have callback-imports against modules they migrated to async — so `await ... done()` never fires, the suite hangs. The orchestrator worked around it by running per-task test files directly. Worth a Stage 1.7 note in the skill: "if any subtask owns a deletion of a shared test file, fall back to per-task tests for the other worktrees".
3. **Cross-review depth asymmetry continues.** Codex's review of T4 was lighter than the Claude reviews of T1/T2 (paragraph-per-finding), but on T3 it was Codex that produced the only Important finding of the run. The asymmetry doesn't reduce to "Codex reviews are useless" — the model that reviews on a given run might be the one that catches the bug.

---

## Negative results

### Pattern observation — "self-inflicted decomposition catch"

Across the 5 fixtures run on 2026-05-06, **two runs** (`#2 pastebin`, `#N3 recursive-to-iterative`) reproduce the pattern: dual-build's decomposed builders introduce a bug that single-agent context naturally avoids; cross-review catches the bug; net value vs. baseline is zero. Two runs produce **clean dual-build wins** (`#3 callback-async-migration`, `#N2 audit-undisclosed-bugs`) where the bug class was something a single agent would *also* miss — e.g., NaN slipping through `typeof === 'number'` validation (test-03), or a stale-trailing-timer firing after a newer leading call (test-04). One run produced no findings (`#N1 bugfix-trio`, all textbook fixes).

**Correction note (post-v0.2.7 rerun)**: an earlier draft of this section claimed 3 of 5 fixtures reproduced the self-inflicted pattern. That count was wrong — the test-04 misclassification came from a too-shallow probe of the baseline's throttle behavior (only 2 calls instead of the 3-call sequence that triggers the bug). The v0.2.7 rerun's LLM judge ran the dual-build's regression test against the baseline and produced `[a, c, b]` instead of `[a, b, c]`, confirming the baseline ships the same bug. See #N2's "Correction" section.

So the workflow's positive value cluster after the corrected analysis: (a) tasks where the bug class is something a single agent would *also* miss (test-03 NaN, test-04 throttle), (b) real-world large codebases where one model can't hold the whole problem in head (`#1 mission-control`), (c) concurrency/timing/state-machine code where blind spots are common. The pure-mechanical-fix scenarios (test-01, parts of pastebin, parts of test-05) remain bail-worthy.

### #N2 — audit of utility modules with undisclosed bugs (2026-05-06)

**Note (correction post-v0.2.7 rerun)**: this entry was originally classified as "self-inflicted decomposition catch" because the v0.2.4 sandbox baseline appeared to handle the throttle case correctly. That was wrong — my probe used only 2 calls (`t('a'); block; t('b')`), which doesn't trigger the bug. The 3-call sequence (`t('a'); t('b'); block; t('c')`) reveals the bug in BOTH baselines (v0.2.4 and v0.2.7). This entry is now classified as a **clean dual-build win** alongside `#3` and `#4` above. The "Correction" section at the bottom has the verified-against-3-call-probe results.

**Test fixture**: 4 utility modules in `lib/` (`throttle`, `csv-parse`, `flatten`, `format`), each with a real bug. Some tests already pass; others fail. Builder must read source + failing tests, identify each bug, and fix. See `test-suite/tests/04-audit-undisclosed-bugs/`.

**Note on fixture quality**: the four module sources contained `// BUG:` comments that gave away the explicit bugs. Both runs used those as hints rather than auditing from scratch. The cross-review finding below was an *additional* bug the comments did NOT mark, so it's still a fair test of cross-review's adversarial-eyes value beyond what the test suite + comments gave away. Future revision should strip the `// BUG:` comments.

| Metric | Dual-build (v0.2.4) | Baseline (v0.2.4) | Dual-build (v0.2.7 rerun) | Baseline (v0.2.7 rerun) |
|---|---|---|---|---|
| Acceptance | PASS (17/17 tests) | PASS (14/14 tests) | PASS | PASS |
| Wall time | 650s | 133s | 895s | 168s |
| Subagent dispatches | 8 | 0 | 8 | 0 |
| Cross-review findings | 1 Critical | n/a | 1 Important | n/a |
| LLM-judge verdict | (originally) baseline better — corrected | n/a | **dual-build clearly better** | n/a |

#### What cross-review caught

Codex's review of T1 (Claude-built throttle) flagged a real bug not pinned by the existing tests:

> **Critical/Important** — [lib/throttle.js]. If a trailing timer is due but has not executed yet, a new call after the window takes the leading path. Repro: `t('a'); t('b');` block synchronously past `ms`; `t('c')` produces `['a', 'c', 'b']`, so stale trailing args fire after a newer leading call.

Both v0.2.4 and v0.2.7 dual-build runs caught and fixed this. The fix flushes the pending trailing args in the leading path before firing the new leading call.

#### Correction — what the LLM judge actually showed (v0.2.7 rerun)

The v0.2.7 rerun's judge ran dual-build's regression test against the baseline:

> "I ran the dual-build's regression test against the baseline implementation:
> ```
> + actual: [ 'a', 'c', 'b' ]
> - expected: [ 'a', 'b', 'c' ]
> ```
> Baseline produces saves out of order. Under the contract's documented use case ("rate-limit a save-on-keystroke callback such that the user always sees their FINAL keystroke applied"), this means the user's `'b'` keystroke gets persisted *after* `'c'` — wrong for save semantics."

Re-verified independently against both baselines:

```
$ node -e "...t('a'); t('b'); block 100ms; t('c')..."
v0.2.4 baseline:    [ 'a', 'c' ]            ← drops 'b' entirely; bug
v0.2.7 baseline:    [ 'a', 'c', 'b' ]       ← fires 'b' after 'c'; bug
v0.2.7 dual-build:  [ 'a', 'b', 'c' ]       ← cross-review fix; correct
```

Both baselines ship a bug. Dual-build's cross-review caught it. **This is a clean win**, mismarked in the original analysis because the v0.2.4 probe used only 2 calls and missed the 3-call manifestation.

#### v0.2.7 alignment doc + sibling-diff impact

The v0.2.7 rerun's dual-build retro reported:

> "Cross-cutting decisions doc (Stage 0.5, v0.2.7) was a wash this run — no asymmetries surfaced because each module's idiom was forced by its problem (state machine for CSV, `forEach` for sparse arrays, `setTimeout` for timing). The doc didn't add value but didn't cost much either (~10 LOC of upfront writing). Sibling-diff injection (v0.2.7) was also a wash — reviewers correctly noted 'no problematic asymmetry' but didn't surface anything actionable from cross-task comparison."

Both v0.2.4 and v0.2.7 caught the same bug; v0.2.7 was just slower (~37% wall time overhead). The improvements neither helped nor hurt this fixture.

#### Why a single-agent flow would have missed it

The bug is a sync-blocking-then-call race: the trailing timer is scheduled but the synchronous block past the window means the leading branch fires before the timer's callback. Both single-agent baselines (v0.2.4 and v0.2.7) failed to handle this — the contract's intent ("user always sees their FINAL keystroke") is subtle enough that without thinking explicitly about the block-past-window case, you write code that drops or reorders args. Cross-review's fresh-eyes pass surfaces exactly this kind of timing edge case.

---

### #N3 — recursive→iterative migration (2026-05-06)

**Test fixture**: 4 recursive functions (`tree-sum`, `json-clone`, `list-reverse`, `expr-eval`) that overflow the stack on deep input. Convert each to iterative form, preserving documented contracts (purity for `list-reverse`, cycle-rejection for `json-clone`, operator precedence for `expr-eval`). Tests pin both standard-input behavior AND deep-input no-overflow. See `test-suite/tests/05-recursive-to-iterative/`.

| Metric | Dual-build | Baseline |
|---|---|---|
| Acceptance | PASS (16/16 tests) | PASS (16/16 tests) |
| Wall time | 605s | 202s |
| Subagent dispatches | 8 (4 builders + 4 reviewers) | 0 |
| Cross-review findings | **0 Critical, 1 Important across 4 tasks** | n/a |
| LLM-judge verdict | **baseline better** | n/a |

#### What cross-review caught

Codex's review of T2 (Claude-built json-clone iterative version):

> "[lib/json-clone.js:48] … Sparse array holes are converted into own `undefined` elements. The previous recursive `value.map(jsonClone)` preserved holes; this loop reads every index and writes `parent[key] = src` for missing slots, so `jsonClone([, 1])` produces a clone where `0 in clone === true`."

Real catch. Fix applied: guard with `if (i in src)` before pushing array work items.

#### What the LLM judge noticed

> "Real bug, real catch — but the baseline never had it. Baseline `lib/json-clone.js:24` uses `Object.keys(src)` uniformly for both arrays and objects, and `Object.keys` skips holes natively. … Dual-build introduced the bug by choosing a different iteration strategy (`for (let i = 0; i < src.length; i++)`) and then paid for cross-review to find it. The baseline avoided the entire failure mode by picking the simpler approach. **Net cross-review lift over baseline: zero.**"

Same shape as #N2 and #2 (pastebin). The dual-build retro doesn't quite acknowledge this — its verdict is "yes, would reach for this approach" — but the LLM judge's outside view sees the pattern: cross-review fixed dual-build's own decomposition damage.

#### What this calibrates

The pastebin run (#2) first surfaced the "tightly-coupled-by-design" bail criterion. Test-05 reproduces a related but distinct pattern: **even on file-disjoint tasks where the contract is well-specified, an isolated builder reading only their own brief makes different (sometimes worse) implementation choices than a single-agent context that holds the whole problem.** The cross-review reliably catches these — but the workflow's overall cost-vs-value math depends on whether single-agent context naturally avoided the same mistake.

For the v0.2.6 skill update, this means the bail criteria should add: *"on small (~200 LOC) fixture-style tasks where each module's contract is locally specifiable, expect cross-review to fix decomposition-introduced bugs rather than catch bugs single-agent would ship. Bail unless the task touches concurrency/timing/state-machine logic or the codebase is large enough that single-agent context can't hold it."*

#### v0.2.7 rerun results — alignment doc caused a NEW regression

Re-ran the same fixture against v0.2.7 (alignment doc + sibling-diff injection). Result: dual-build was **worse** than v0.2.4 because the orchestrator's `_dual-build-decisions.md` Section 6 made an opinionated cross-cutting decision that propagated to all builders:

> ## 6. Cycle detection strategy (`json-clone`)
> - Use a `Map` keyed by source object identity (`map.set(src, clone)`).
> - Before processing a child, check `map.has(child)`. If yes, throw `new Error('cyclic reference')`.
> - **This treats shared-reference DAGs as cycles too.** That's acceptable: the contract says "no shared references with the input" in the output, and the test suite does not exercise DAG inputs.

The cross-reviewer (Codex) caught this as a regression vs. the recursive baseline:

> "[lib/json-clone.js:33] `seen` is global 'ever seen' state, so DAG inputs falsely throw `Error('cyclic reference')`. The recursive implementation would clone both entries independently."

Real, correct catch. **But the dual-build orchestrator failed to apply the fix and merged anyway** — the bug shipped in the merged result. The v0.2.7 LLM judge confirmed:

> "So the cross-review identified the regression, but the dual-build orchestrator merged anyway and only documented the issue in RETRO.md. The retro's own framing ('self-inflicted by Stage 0.5 decisions doc, net cross-review value zero') understates this: cross-review *did* catch a bug that *did* ship. The baseline retro independently noticed the same ambiguity and resolved it correctly."

Verified directly:

```
v0.2.4 baseline:    sparse OK,  DAG OK
v0.2.4 dual-build:  sparse OK (cross-review fix applied),  DAG ERROR (silent regression — not caught)
v0.2.7 baseline:    sparse OK,  DAG OK
v0.2.7 dual-build:  sparse BUG (lost the fix),  DAG ERROR (cross-review caught + flagged but orchestrator didn't apply)
```

v0.2.7 verdict: **baseline better** (LLM judge). This is the second self-inflicted catch from this fixture, but worse: in v0.2.4 cross-review at least applied the sparse-array fix; in v0.2.7 cross-review caught the DAG regression and the orchestrator failed to apply the fix.

**Direct lesson for v0.2.8**: the alignment doc must encode only decisions the contracts strictly require, not opinionated choices that diverge from natural single-agent behavior. §6's "treat DAGs as cycles" had no contract basis — the contract said "throw on cycles", not "throw on DAGs". v0.2.8 SKILL.md adds that constraint to Stage 0.5. This finding alone justifies the test-suite re-run as v0.2.7 was committed without one.

#### v0.2.8 rerun results — constraint works, but bail still applies

Re-ran test-05 against v0.2.8 to validate the alignment-doc hard constraint. Recovered alignment doc explicitly says: *"(Note: the test suite only exercises the simple `o.self = o` case; do not over-broaden cycle detection to reject DAGs.)"* — directly preventing v0.2.7's §6 mistake. Verified post-merge: DAG inputs now correctly cloned (`c2.a.x: 1`, no error).

| Version | Wall | Cross-review findings | Bug status | LLM verdict |
|---|---|---|---|---|
| v0.2.4 | 605s | 1 Important (sparse-array, applied) | sparse fixed, DAG silent regression | baseline better |
| v0.2.7 | 765s | 1 Important (DAG, **not applied**) | sparse bug shipped, DAG regression caught but orchestrator failed to apply fix | baseline better (worse outcome) |
| v0.2.8 | 770s | **0 findings** (clean) | DAG correct ✅, both arms have latent sparse bug not pinned by tests | baseline better (cleaner reason — dual-build just heavier) |

The v0.2.8 LLM judge ran fresh and reported "baseline better" with the cleanest rationale yet:

> "Zero substantive findings on either side. Total across four cross-reviews: 0 Critical, 0 Important, 8 Praise, 2 lower-confidence notes self-flagged as non-issues. The cross-review caught nothing the baseline missed, and the baseline introduced nothing dual-build needed to catch."

> "Both implementations are correct, contract-preserving, and minimal-ish. Differences in shape: dual-build's json-clone is ~85 LOC with parallel `work`/`stack`/`pendingChildren` machinery; baseline's is ~32 LOC with one stack and an exit-frame pattern. Same DAG-vs-cycle semantics in roughly 1/3 the code. Subtlety the contract didn't ask for is a code-smell, not a feature."

Notable additional finding: in v0.2.8, both baseline AND dual-build ship the same latent sparse-array bug (`jsonClone([, 1])` → `keys: ['0', '1']`). v0.2.4's "baseline avoided the sparse-array failure mode" was partly luck — that specific run picked `Object.keys()`-style iteration which skips holes naturally; v0.2.8 baseline picked indexed iteration which doesn't. So the sparse-array bug isn't strictly "self-inflicted by decomposition" — it depends on which iteration pattern the model happens to pick, regardless of arm.

**What v0.2.8 confirms**:
1. The Stage 0.5 hard constraint works — orchestrator now writes "do not over-broaden" guardrails rather than wrong-encoded opinions. The v0.2.7 regression is structurally prevented.
2. Cross-review depth is well-calibrated when there's nothing to catch — 0 findings + 8 praise + 2 self-dismissed sub-threshold notes is the right shape for a clean run.
3. Test-05 remains in bail territory regardless of how well-tuned the alignment doc is. The shape of the task (small file-disjoint refactor with locally-specifiable contracts) doesn't reward the workflow's overhead, even when the workflow runs cleanly. Bail criteria are correct.

---

### #N1 — bugfix-trio test-suite run (2026-05-06)

**Test fixture**: three intentional bugs in three file-disjoint files (`test-suite/tests/01-bugfix-trio/`):
- `server/index.js`: `POST /api/users` crashes on empty body (missing validation)
- `lib/dates.js`: `dayInPT` returns local-machine day instead of America/Los_Angeles day
- `public/search.js`: input handler fires on every keystroke (missing 250ms debounce)

**Run**: A/B harness in `test-suite/run-tests.sh`. Same task run twice — once with `/dual-build`, once as a single-agent baseline.

| Metric | Dual-build | Baseline |
|---|---|---|
| Acceptance | PASS | PASS |
| Wall time | 978s (~16 min) | 289s (~5 min) |
| Subagent dispatches | 6 + 3 orchestrator commits | 0 |
| Cross-review findings | **0 Critical, 0 Important** across all 3 tasks | n/a |

#### What the cross-reviewers actually said

- **T1 (dates) reviewer**: 0 Critical, 0 Important, 3 Praise. Sub-threshold (~70% confidence) caveat about test cases coincidentally passing the buggy code on a host whose own TZ is `America/Los_Angeles` — chose not to escalate. Real observation about test robustness, but the reviewer correctly judged it sub-threshold.
- **T2 (server validation) reviewer**: 0 Critical, 0 Important, 3 Praise. Reviewer noted it could not run `node --test` inside its sandbox; static review only. (This gap is what motivated v0.2.3's Stage 1.7 — orchestrator now runs tests pre-review and includes results in every reviewer's brief.)
- **T3 (debounce) reviewer**: 0 Critical, 0 Important, 4 Praise.

#### What the dual-build retro itself concluded

> *"No, I would not reach for /dual-build on a task this size again. The cross-review found nothing actionable. The bugs are small enough that the per-task tests gate quality on their own — three passing `node --test` files is a strong signal independent of having a second model read the diff. The workflow's value comes from cross-review catching things that would have shipped otherwise; here it caught zero such things across three subtasks."*

The baseline retro converged on the same verdict independently:

> *"Reaching for /dual-build here would have been overhead for ~no signal."*

#### Why this is an interesting result

1. **The workflow is willing to honestly self-assess.** The orchestrator wrote a verdict against itself. That's good for credibility — the skill isn't a hammer looking for nails.
2. **It surfaced a real shape mismatch.** "Three textbook fixes (validation, timezone, debounce) at 111 LOC total" passed the v0.2.0 bail threshold (`<50 LOC`) but the run made clear that threshold was too generous. v0.2.3 bumps the bail threshold to `<150 LOC` and adds a "textbook fixes" criterion based on this run.
3. **It validated the harness end-to-end.** `claude -p "/dual-build …"`, parallel build dispatch, Stage 1.5 base verification, Stage 1.6 Codex commit recovery (both Codex builders hit the documented "edits applied but commit failed" path and recovery worked), merges, post-merge tests — the whole pipeline ran clean. The pipeline working without producing findings is data; producing findings would have been more informative, but the negative result is still real signal.

#### What the LLM judge added (verdict: baseline better)

`evaluate.sh` runs a separate Claude judge over both retros, diffs, and acceptance results. It surfaced things neither retro caught:

> **Net cross-review value here: negative.** The T1 reviewer noticed (sub-threshold, ~70% confidence) that the dates test would coincidentally pass against the buggy `getDate()` on a host whose timezone is itself `America/Los_Angeles`. The reviewer chose not to escalate that observation. Baseline (single-agent) independently used `TZ=UTC`/`TZ=Asia/Tokyo` subprocess forcing to make the test deterministic regardless of host TZ. **Dual-build's test is weaker than baseline's *because* the reviewer dropped the finding under the confidence threshold.**

> **Code-quality deltas** the judge identified:
> - Baseline: `createApp()` factory (cleaner test seam) vs. dual-build: `export default app` singleton.
> - Baseline: 5 LOC of validation vs. dual-build: ~25 LOC (over-engineered for the spec).
> - Baseline: `*.test.js` (harness-discoverable) vs. dual-build: `*.js` in `test/` (the harness's `acceptance.sh` discovery pattern missed it; PASS was on regex-detection only, not executed tests).

#### Calibration takeaways

1. **Reviewer threshold is too strict for test-reliability findings.** A 70%-confidence "this test passes coincidentally" observation should escalate — the cost of fixing is trivial and the value of robust tests is high. v0.2.3's reviewer prompts add an explicit lower threshold for test-reliability + acceptance-honesty findings.
2. **The acceptance harness's test discovery was too narrow.** `*.test.js` only; `node --test` actually accepts `test/*.js` too. v0.2.3 broadens the discovery pattern.
3. **For "three obvious bugs, three obvious fixes, three obvious tests," reach for the regular Claude Code workflow.** For tasks like the mission-control entry above (concurrency, error paths, platform-specific behavior), reach for `/dual-build`. The bail criteria in `skills/dual-build/SKILL.md` codify the call.

---

*Format conventions: cross-review catches → builder model + reviewer model + LOC + each finding with what was produced, what was caught, and "why a single-agent flow would have missed it." Negative results → metrics + the retro's own verdict + what the result calibrated. Skip "the workflow ran" entries that produced neither real catches nor calibration insight.*
