# Changelog

## v0.2.8 — 2026-05-06

Corrections + v0.2.7 rerun findings.

### Corrected: test-04 is a clean dual-build win, not a self-inflicted catch

The v0.2.4 analysis classified test-04 as "self-inflicted" because a 2-call probe (`t('a'); block; t('b')`) showed the baseline producing `[a, b]` correctly. That probe was wrong — the throttle bug only manifests on the 3-call sequence (`t('a'); t('b'); block; t('c')`). The v0.2.7 rerun's LLM judge ran the dual-build's regression test against baseline and produced `[a, c, b]` instead of `[a, b, c]`, confirming the bug ships under the contract's documented use case ("user always sees their FINAL keystroke applied"). Both v0.2.4 and v0.2.7 baselines have the bug.

Re-verified independently: v0.2.4 baseline gives `[a, c]` (drops `b`); v0.2.7 baseline gives `[a, c, b]` (fires `b` after `c`); v0.2.7 dual-build gives `[a, b, c]` (cross-review fix). Test-04 is now correctly classified as a clean dual-build win alongside test-03 (NaN validation).

### Self-inflicted-decomposition pattern: 2 of 5 fixtures, not 3 of 5

Pattern now reproduces in:
- `#2 pastebin` (Express default-error-handler stack-leak — baseline avoided via cross-cutting design)
- `#N3 recursive-to-iterative` (json-clone sparse-array densification — baseline used `Object.keys`)

And clean wins in:
- `#3 callback-async-migration` (NaN validation — both baselines shipped the bug)
- `#N2 audit-undisclosed-bugs` (throttle stale-timer — both baselines shipped the bug)

Plus `#N1 bugfix-trio` no findings (textbook fixes), and `#1 mission-control` real-world catch.

### Hard constraint added to Stage 0.5 alignment doc

The v0.2.7 rerun of test-05 surfaced a new failure mode: the orchestrator's alignment doc can encode opinionated cross-cutting choices that propagate as consistent regressions to all builders. Specifically, `_dual-build-decisions.md §6` said "treats shared-reference DAGs as cycles too. That's acceptable: the contract says 'no shared references in the output'." But the contract said "throw on cycles", not "throw on DAGs". The recursive baseline naturally cloned DAGs correctly; the v0.2.7 dual-build threw `Error('cyclic reference')` on every DAG input. Cross-review caught the regression — and then the orchestrator failed to apply the fix and shipped the bug.

**Rule**: the alignment doc must encode ONLY decisions strictly required by:
1. The contracts (forced error messages, forced exports)
2. Existing project code (forced module type, forced test runner)
3. Explicit user instructions

NOT opinionated choices that diverge from natural single-agent behavior. "When in doubt, leave the decision OUT." Empty-but-present (`(no cross-cutting concerns identified)`) is strictly better than encoding speculative cross-cutting decisions.

### v0.2.7 rerun cost-vs-value summary

| Test | v0.2.4 | v0.2.7 rerun | Net |
|---|---|---|---|
| 04 audit | dual-build wins (650s) | dual-build wins (895s) | same outcome, +37% wall time |
| 05 recursive→iter | baseline better, sparse-array fix applied (605s) | baseline better, alignment doc caused DAG regression + sparse-array bug also shipped (765s) | strictly worse |

v0.2.7's alignment doc + sibling-diff injection neither helped nor hurt test-04 (other than cost), and made test-05 worse. v0.2.8's hard constraint on the alignment doc tries to recover that.

## v0.2.7 — 2026-05-06

Two structural changes targeting the "self-inflicted decomposition catch" pattern from v0.2.6's findings. Both try to prevent the divergence between isolated builders at source, rather than catching it late via cross-review.

### New Stage 0.5: cross-cutting alignment doc

After Stage 0's task split is confirmed, the orchestrator writes a short `_dual-build-decisions.md` listing cross-cutting choices that all builders converge on:

- Validation patterns (e.g., `Number.isFinite()` not `typeof === 'number'`)
- Error shapes
- Iteration / data-structure conventions (e.g., `Object.keys()` for sparse arrays)
- Cleanup conventions (try/finally, AbortController)
- Naming and import conventions

Builders read this before implementing. The decisions doc is mandatory and ~5–25 lines; if no cross-cutting concerns exist, the file documents that explicitly. Both `claude-builder` and `codex-builder` agents now require this read step.

### Sibling-diff injection in Stage 2

Reviewers now receive the OTHER tasks' diffs (capped ~500 lines each) as read-only context. New reviewer responsibility: flag cross-cutting asymmetries — e.g., "Sibling T1 uses `Number.isFinite()` here; this T3 uses `typeof === 'number'`, which lets NaN through" — as **Important** findings. Both `claude-reviewer` and `codex-reviewer` agents updated.

The cross-task-wiring rule from v0.2.4 (forbidding "X is unused / Y is missing"-style claims about sibling worktrees) is preserved with a sharpened distinction:
- ✅ pattern asymmetry between two diffs the reviewer can directly read
- ❌ wiring claim about post-merge behavior (still structurally unverifiable)

### What's NOT yet validated

These two changes are skill-doc + agent-prompt updates with no executable code; v0.2.7 is committed without re-running the test suite. The hypothesis is that test-04 and test-05 (small fixture-scale, locally-specifiable contracts) should produce zero asymmetry-class findings post-fix — but whether the added overhead (one extra orchestrator pass + ~1.5x reviewer context) is worth the saved review-then-fix cycles depends on a re-run.

## v0.2.6 — 2026-05-06

Driven by test-04 (audit of utility modules with undisclosed bugs) and test-05 (recursive→iterative migration) A/B runs. Both produced **"baseline better"** LLM-judge verdicts for the same reason as the earlier pastebin run: cross-review caught real, applied bugs, but the bugs only existed because dual-build's decomposition introduced them; single-agent baseline naturally avoided them at first authorship. **Net cross-review value vs. baseline: zero** on both runs.

### Pattern: "self-inflicted decomposition catch" is now reliable

The pattern is reproduced across 3 of 5 fixtures run on 2026-05-06 (pastebin, test-04, test-05). The remaining two:
- `01-bugfix-trio` — no cross-review findings at all (small textbook fixes).
- `03-callback-async-migration` — clean dual-build win (cross-review caught a `NaN` validation bug that baseline ALSO shipped + tested for, but missed).

The dual-build skill's positive value is concentrated in cases where the bug class is something a single agent would *also* miss. For everything else at fixture scale, expect the workflow to fix bugs it created.

### New bail criterion + positive-signal carve-outs (SKILL.md)

- **Bail**: small fixture-scale (~200 LOC) file-disjoint refactors where each module's contract is locally specifiable. Expect self-inflicted decomposition catches rather than real lift.
- **Carve-outs that override the bail**: concurrency/timing/state-machine code (throttle, debounce, retry, locks); validation logic with known blind spots (NaN-style); real-world large codebases where single-agent context can't hold the whole problem.

### New EXAMPLES.md entries

- Top-level "Pattern observation" section under "Negative results" documenting the self-inflicted decomposition pattern across the 5-fixture sweep.
- `#N2 audit-undisclosed-bugs` — Codex caught a stale-timer bug in Claude-built throttle (Critical, score 92), applied; baseline's first-pass throttle avoided it via a different code shape.
- `#N3 recursive-to-iterative` — Codex caught sparse-array hole densification in Claude-built iterative json-clone (Important, score 82), applied; baseline used `Object.keys` and avoided the failure mode entirely.

### New test fixtures

- `04-audit-undisclosed-bugs` — 4 utility modules with bugs, mixed test pass/fail. Note: source comments give away the explicit bugs (still informative for measuring cross-review value beyond the obvious).
- `05-recursive-to-iterative` — 4 recursive functions migrated to iterative with deep-input contracts (50000 nodes / 10000 depth / 5000-deep parens).

## v0.2.5 — 2026-05-06

Driven by the test-03 callback→async/await migration A/B run — the test suite's first **"dual-build clearly better"** LLM-judge verdict. Cross-review (Codex on T3) caught a `NaN`-validation bug single-agent baseline shipped, with zero NaN tests in baseline's test suite. Verifiable in 2 seconds via a `node -e` one-liner against both sandboxes.

### New EXAMPLES.md entry: #3 callback → async/await migration

First fixture-based clean A/B win. Cross-review caught `typeof opts.timeoutMs !== 'number' || opts.timeoutMs <= 0` letting `NaN` slip through (`typeof NaN === 'number'` is true; `NaN <= 0` is false). Codex reviewer score 86; fix landed pre-merge with `Number.isFinite()`. Baseline (single-agent Claude opus-4-7, 258s, 25 tests) shipped the identical buggy pattern. The 2-line `node -e` exploit makes the divergence directly observable post-deploy.

LLM-judge verdict: **dual-build clearly better** — first such verdict in the test-suite history (prior runs: bugfix-trio "baseline better, no findings"; pastebin "baseline better, with footnote about self-inflicted decomposition wound").

### New test fixture: 03-callback-async-migration

Four file-disjoint callback-style modules (`cache.js`, `file-ops.js`, `http-fetch.js`, `job-queue.js`), ~50 LOC each, with header-comment "contract notes" specifying invariants that mechanical promisify can break (ENOENT→null, at-most-once settlement, tmp cleanup on rename failure, halt-on-error, cancel between iterations). Designed to clear the bail criteria (>150 LOC total, ≥40 LOC per subtask, NOT textbook) AND to live below a single-agent's typical test-coverage instinct so cross-review has surface area to add value.

### Stage 1.7: shared-test-file deletion gotcha

Documented the hang/fail pattern when one subtask owns deletion of a shared test file: N-1 sibling worktrees see hangs or signature mismatches during the full-suite run because the shared test file still imports the OLD API of the modules they migrated. Workaround: run only the per-task test file and pass that into the reviewer brief, noting the cross-task isolation artifact. Surfaced by test-03 where T1 owned the deletion of `test/baseline.test.js`.

### Calibration findings codified

- **Baseline prompts auto-invoke `/dual-build` when the task description matches the skill's "use when" criteria.** First baseline run on test-03 silently no-op'd because `claude -p` exited cleanly during Stage 0's confirmation pause. Test fixture's `prompt-baseline.md` now closes with explicit `/dual-build` suppression. Pattern is now documented for future fixture authors.
- **Cross-review depth asymmetry continues** (Codex reviews lighter than Claude reviews on average) — but the model with the lighter review on a given run might be the one that catches the bug. test-03's only Important finding came from a Codex reviewer.

## v0.2.4 — 2026-05-06

Driven by the pastebin test-suite run + LLM judge verdict ("baseline better, *with footnote*"). The pastebin's cross-review caught a real Express-default-error-handler stack-leak bug — but the judge surfaced that the baseline never had the bug because single-agent context produced a generic JSON error handler naturally. Net cross-review value: recovering from a self-inflicted decomposition wound, not catching a bug a single agent would have shipped.

### New bail criterion: tightly-coupled-by-design

> Even when file-disjoint, if design decisions span all subtasks (renderer behavior depends on API validation; all layers share an error-shape contract invented during the build), single-agent context produces better cross-cutting decisions than coordinated agents working from a pre-written contract.

The pastebin baseline shipped UX polish dual-build missed: language-hint auto-fencing, slug-shape guard for favicon avoidance, custom slug alphabet, WAL journal mode, strict `expires_in_hours` allowlist — all cross-cutting decisions a single head naturally produces.

### Reviewers must not assert on cross-task wiring

Pastebin's T2 reviewer falsely claimed `cleanupExpired()` was never called — but it lives in T1's worktree, which the reviewer can't see. Structurally inevitable from single-worktree review. Reviewer prompts now explicitly forbid asserting "X is unused" / "Y is never defined" for cross-task references; route to "Cross-task contract — orchestrator spot-check on merge" instead (NOT a Critical/Important finding).

### codex-builder no longer attempts `git commit`

The read-only-fs failure on `.git/worktrees/<id>/index.lock` has now hit 4+ runs reliably (SecureCatch, mission-control, bugfix-trio, pastebin had 2/3). v0.2.4 codex-builders stop after edits, include their intended commit message in the report, and the orchestrator commits routinely. Stage 1.6 reframed from "partial-success recovery" to "orchestrator commits Codex builder's edits (always)."

### EXAMPLES.md updated

- New Section 1 entry: `#2 — pastebin test-suite run` with the real cross-review catch + the judge's footnote about decomposition self-wounding + the cross-cutting-design polish baseline produced.

## v0.2.3 — 2026-05-06

Improvements driven by the first end-to-end harness run (bugfix-trio A/B) — the LLM judge verdict came in as **"baseline better"**, surfacing real signal that neither retro caught.

### Bail criteria tightened (again)

- **<150 LOC total** (was <50). The bugfix-trio run was 111 LOC across 3 file-disjoint subtasks — passed the v0.2.0 gate but produced zero actionable cross-review findings. The threshold was too generous.
- **Per-subtask floor: <40 LOC each**. Even when total LOC is fine, cross-review value is low if every individual diff is tiny.
- **"Textbook fixes" criterion**. Validation, debounce, timezone formatting, retry, encoding, dependency bumps — obvious patterns where cross-review predictably finds nothing. If a builder could mechanically apply a textbook recipe, bail.

### Stage 1.7: orchestrator pre-review test run

- New mandatory step. Before dispatching reviewers, the orchestrator runs the project's test command in each worktree (`npm test` / `node --test` / `pytest` per heuristic) and includes the result in every reviewer's brief as `Pre-review test result`. Reviewers compare against the builder's claimed acceptance — mismatches are automatic **Critical** findings.
- Why: the bugfix-trio run had a Codex reviewer report it could not run `node --test` in its `read-only` sandbox (static review only). Centralizing test execution in the orchestrator gives every reviewer the same verified ground truth and closes the "builder claims pass + reviewer can't verify" gap.

### Reviewer thresholds — exception classes

Reviewers (claude-reviewer, codex-reviewer) had a hard ≥80 confidence threshold. The bugfix-trio judge surfaced that this was too strict for a specific class: a T1 reviewer noticed (sub-threshold, ~70%) that the dates test coincidentally passed against buggy `getDate()` on a PT-timezone host. The reviewer dropped it. The single-agent baseline independently fixed the same issue with subprocess `TZ=UTC`/`TZ=Asia/Tokyo` forcing — producing a more robust test than the cross-reviewed version.

v0.2.3 reviewer prompts now explicitly require surfacing **even sub-80 findings** in these classes:
- **Test reliability**: passes on builder's host but may fail on others (TZ, locale, ports, mocked state)
- **Coincidence-passing negative tests**: the test that should fail before the fix actually passes on the buggy code
- **Acceptance honesty**: builder claimed pass but pre-review test result is fail — automatic Critical regardless of confidence

### Test-suite acceptance fix

- `tests/01-bugfix-trio/acceptance.sh` was discovering only `*.test.js` files. `node --test` also accepts `test/*.js`, which is what the dual-build run produced — harness reported PASS on regex-fix-detection only, not actual test execution. Fixed: discovery now covers `*.test.js`, `*.test.mjs`, `test/*.js`, `test/*.mjs`, `tests/*.js`, `tests/*.mjs`.

### EXAMPLES.md restructured

Now has two sections: **Cross-review catches** (mission-control entry) and **Negative results** (bugfix-trio entry with the LLM judge's verdict). The honest two-sided view is the credible one.

## v0.2.2 — 2026-05-06

Visual + landing-page polish.

- **Banner image** at `assets/dual-build-banner.png`, used as the README hero. 3840×1920 — also suitable for GitHub social-preview upload (Settings → Social preview → Upload image).
- **README rebuilt** as a landing page: hero → tagline → quick start → real-bug-catch quotes from EXAMPLES.md → comparison table → workflow → install → prereqs → bail criteria. Optimized for 5-second value-prop comprehension on first scroll.
- **Badges**: license, latest release, GitHub stars, "Claude Code compatible," "Codex compatible."
- **Test-suite acceptance fix** (carried forward from a post-v0.2.1 commit): `tests/01-bugfix-trio/acceptance.sh` no longer false-FAILs on the default `npm init -y` no-op test script. Prefers `node --test` when test files exist.

## v0.2.1 — 2026-05-06

Added an automated A/B test harness for the skill itself.

### Test suite

- New `test-suite/` directory with `run-tests.sh` orchestrator and `evaluate.sh` LLM-judge.
- Auto-discovers tests under `test-suite/tests/<name>/` — drop in 4 files (`setup.sh`, `prompt-dual-build.md`, `prompt-baseline.md`, `acceptance.sh`) to add a test. ~15-30 min per fixture.
- Per test: runs the same task with `/dual-build` and again as a single-agent baseline in fresh sandboxes; captures stream JSON, RETRO.md, git logs, per-branch diffs, acceptance PASS/FAIL, wall time. `evaluate.sh` then sends both retros + diffs to a separate Claude judge for an A/B verdict.
- Two starter fixtures: `01-bugfix-trio` (Express app with 3 known bugs — validation crash, timezone, debounce) and `02-pastebin` (greenfield markdown pastebin from empty scaffold).
- `test-suite/README.md` documents the harness layout, prerequisites, and the four-file convention for adding tests.

### Skill

- **Stage 0 auto-approve mode** (`DUAL_BUILD_AUTO_APPROVE=1` env var). When set, the orchestrator skips the user-confirmation pause, dumps the proposed split to `_dual-build-plan.md`, and proceeds directly to Stage 1. Required for the unattended test harness; not recommended for interactive use.

## v0.2.0 — 2026-05-06

Improvements based on four real test-run retrospectives across user projects (OSINT-Extension, FinancialResearch, SecureCatch, mission-control). The retrospectives surfaced one critical workflow bug, two recurring failure modes, and a class of false-positive findings that needed explicit guardrails.

### Workflow correctness

- **Stage 1.5 added: post-dispatch worktree base verification.** The `Agent(isolation: "worktree")` mechanism occasionally roots worktrees at `main` / HEAD-of-default rather than the working branch's tip, silently invalidating builds (this killed the FinancialResearch run — every builder targeted symbols that didn't exist on the worktree's stale base). The orchestrator now compares each worktree's base against the parent HEAD captured at prerequisites time and aborts the affected task on mismatch.
- **Builder briefs now embed parent HEAD SHA** so builders can self-check their base before editing.
- **Builders now report `git log --oneline -3`** in their final report so the orchestrator has the data needed for Stage 1.5.

### Bail criteria tightened

- **Hard <50 LOC threshold** (was a soft "consider").
- **Balance check**: any subtask <20% of total LOC delta → bail (prevents the 90/10 splits OSINT-Extension run correctly bailed on but the skill didn't formally codify before).
- **Code-vs-docs check**: docs-heavy decompositions → recommend single-agent.
- **Clean-tree precondition**: dirty trees won't be visible to worktrees; gate on `git diff --quiet && git diff --cached --quiet` and surface to user.

### Failure mode handling

- **Codex-builder partial-success recovery documented.** Codex's sandbox sometimes fails `git add` even though file edits are correct — recurring in SecureCatch + mission-control runs. The codex-builder agent now reports `git status --porcelain` + the original commit message it would have used, and the orchestrator commits on Codex's behalf in Stage 1.6. Treat as routine recovery, not a workflow failure.
- **Worktree unlock step documented.** `git worktree remove` fails after agent dispatch with "cannot remove a locked working tree" — mission-control run hit this. Stage 4 now documents `git worktree unlock <path>` as the prerequisite to cleanup.
- **Single auto-retry on transient errors** (HTTP 5xx, AnyIO timeout <60s with no useful output) before escalating. Auth errors (401/403) explicitly excluded from retry.
- **Reviewer hallucination warning.** SecureCatch run had a Codex reviewer declare `JIRA_CSIRT_EMAIL` "referenced nowhere" when it was actively used in `lib/jira.ts:46-48`. New guidance: spot-check Critical/Important findings — especially negative claims like "X is unused" — against ground truth via grep before applying.

### Agent prompt improvements

- **codex-builder**: explicit handling of "edits applied but commit failed" path, with `git status --porcelain` + `git log --oneline -3` outputs in every structured report.
- **codex-reviewer**: stronger demand for substantive review depth (mandatory second pass if first pass produces no findings, mandatory grep verification before negative claims, mandatory file:line citations on every finding). Addresses the cross-review depth asymmetry observed across runs (Codex reviews tended to be lighter than Claude reviews).
- **claude-builder**: now captures and reports `git log --oneline -3` for Stage 1.5 base verification.
- **claude-reviewer**: explicit grep-before-negative-claims rule (defensive against the same false-positive failure mode that hit Codex reviewer).

### Documentation

- Added `EXAMPLES.md` — gallery of real cross-review catches from runs (the artifact that demonstrates the workflow's value proposition vs. self-reported numbers).

## v0.1.0 — 2026-05-05

Initial release. Symmetric multi-agent build with mandatory cross-review for Claude Code + Codex.

- `skills/dual-build/SKILL.md` — orchestrator workflow (stages 0-4)
- `agents/claude-builder.md`, `agents/codex-builder.md` — parallel implementers
- `agents/claude-reviewer.md`, `agents/codex-reviewer.md` — fresh-eyes cross-reviewers
- `.claude-plugin/plugin.json` — Claude Code plugin manifest
- `install.sh` — manual install fallback
- `README.md`, `LICENSE`, `SECURITY.md`, `.github/CODEOWNERS`
