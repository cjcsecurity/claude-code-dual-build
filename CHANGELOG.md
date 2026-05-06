# Changelog

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
