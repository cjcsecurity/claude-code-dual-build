---
name: dual-build
description: Orchestrate a parallel multi-agent build with mandatory cross-review across Claude and Codex. Splits a multi-component coding task into ~equal Claude and Codex subtasks, runs them in parallel in isolated git worktrees, then has the OPPOSITE model review each diff before consolidation. Use for multi-file features, refactors with parallel slices, batch fixes, or audit-and-fix passes — bail to a single-agent build for trivial changes. The cross-review is the value: different model families catch different bug classes.
---

# /dual-build — parallel build with mandatory cross-review

This skill orchestrates a structured workflow that:

1. Splits a coding task into file-disjoint subtasks
2. Assigns roughly half to Claude and half to Codex
3. Runs all builders in parallel in isolated git worktrees
4. Has the OPPOSITE model review each diff (Claude reviews Codex's work; Codex reviews Claude's work)
5. Consolidates results and asks the user what to merge

The cross-review is the load-bearing piece. Different model families surface different classes of bug. The 50/50 split is a means to that end — you need both models to have produced something for both to be reviewable.

## When to use

Use when the prompt has 2+ independently-scopable components AND quality matters more than raw speed:

- Multi-file feature spanning ≥3 files with clean module boundaries
- Batch of unrelated bug fixes
- Refactor with parallel slices (e.g., migrate N files to a new pattern)
- Audit-and-fix passes where cross-validation has real value

## When NOT to use (bail criteria)

Bail (decline the workflow, recommend single-agent) if ANY of these hold. Bailing is a valid output of this skill — state the reason explicitly to the user, don't force-fit:

- **Single-file or <150 LOC total delta** across all subtasks. (Bumped from <50 in v0.2.3 after the 2026-05-06 bugfix-trio test run produced zero actionable cross-review findings on a 111-LOC 3-subtask split. Cross-review on small changes is theatre.)
- **All subtasks are <40 LOC each.** Even when total LOC passes the gate above, cross-review value is low if every individual diff is tiny. Median subtask size matters as much as total.
- **All subtasks are "textbook fixes"** — obvious patterns like adding validation, debouncing, timezone-aware date formatting, basic retry logic, simple encoding, dependency bumps, lint-rule conformance. Cross-review value is highest on subtle interactions and edge cases, not pattern-matching. If a builder could mechanically apply a textbook recipe, the reviewer is unlikely to find anything novel — confirmed by the bugfix-trio test run.
- **Imbalanced split** — any subtask is <20% of the total LOC delta. A 90/10 split passes "file-disjoint" but defeats the cross-review purpose: the reviewer of the trivial subtask has nothing to find, and the substantive subtask gets the same scrutiny as a single-agent run.
- **Code-vs-docs ratio is heavy on docs.** If half or more of the work is README / .env.example / CHANGELOG / setup prose, cross-review on docs is low-signal. Recommend single-agent for docs-heavy work.
- **No file-disjoint decomposition possible** — everything touches the same hot file. Worktree isolation can't help.
- **Tightly-coupled work** where every subtask needs every other subtask's output to test (cross-task dependencies > 1).
- **Tightly-coupled-by-design** components — even when file-disjoint, if the design decisions span all subtasks (e.g., "the renderer's behavior depends on the API's input-validation choices," "all three layers share an error-shape contract that's invented during the build"), single-agent context produces *better* cross-cutting decisions than coordinated agents working from a pre-written contract. Cross-review can catch decomposition damage but doesn't restore the cross-cutting design insight that was lost in the split. Pastebin's 2026-05-06 test run made this concrete: baseline shipped a generic JSON error handler, language-hint auto-fencing, a slug-shape guard, WAL journal mode, and a strict expires-in-hours allowlist — all cross-cutting decisions a single head naturally produced. Dual-build, working from a contract, missed those.
- **Time-sensitive fixes** — the workflow takes minutes, not seconds.
- **Exploratory or interactive work** — user is steering turn-by-turn.
- **Working tree is dirty** — uncommitted changes won't be visible to the worktrees (see prerequisites). Either commit/stash first or bail.

## Required prerequisites

Run all of these checks before decomposing. If any fail, report and stop.

- **Git repo**: `git rev-parse --is-inside-work-tree`.
- **Codex MCP healthy**: `mcp__codex__codex` available and authenticated. Run `/codex:setup` if unsure.
- **Worktrees feature available**: `git worktree list` doesn't error.
- **Clean working tree**: `git diff --quiet && git diff --cached --quiet`. Worktrees branch from HEAD, so any uncommitted changes are invisible to the builders. If dirty:
  - Surface the situation to the user.
  - Ask them to either commit the WIP as a checkpoint commit (`git commit -am "wip: pre-dual-build checkpoint"`) or explicitly acknowledge the WIP won't be in the worktrees.
  - Do **not** silently `git stash` and pop — that introduces a parallel failure mode if subtasks touch the same files.
- **Capture parent HEAD SHA**: before any worktree dispatch, run `git rev-parse HEAD` and save the output. This is the expected base for every worktree (verified in Stage 1.5).

## Pipeline

### Stage 0 — Decompose

Read enough code (Glob, Grep, targeted Reads) to understand the module boundaries the task touches. Then produce a task split with these properties:

- **2–6 subtasks total.** Fewer is fine; more than 6 means the task is probably too granular and overhead will dominate.
- **File-disjoint.** No two subtasks may touch the same file. If two pieces of work touch the same file, merge them into one subtask. If you cannot achieve disjoint scopes, bail out.
- **Balanced.** No subtask should be <20% of the total estimated LOC delta. If your decomposition is lopsided (e.g., 3 bugs in one file + 1 line in another), the right answer is single-agent — bail.
- **~50/50 assignment** between Claude and Codex. Don't agonize over the split; roughly even is fine. Slight preferences:
  - Codex tends to be strong at scaffolding, boilerplate, and well-specified mechanical changes
  - Claude tends to be strong at nuanced refactors and reasoning-heavy changes
  - But these are weak heuristics; if in doubt, alternate assignments

Each subtask must specify:

- `id` — short identifier (T1, T2, T3, …)
- `assigned_to` — `"claude"` or `"codex"`
- `goal` — one sentence
- `brief` — 2–4 sentences of implementation guidance
- `file_scope` — explicit list of paths the subtask may touch
- `acceptance` — how to verify (tests, build, behavior)

**Show the split to the user and wait for confirmation before dispatching builders.** If they redirect (reassign tasks, adjust scope, add/remove a subtask), accept and re-plan. Do not proceed without explicit go-ahead — the parallel build phase will spawn N agents and is non-trivial to abort cleanly.

**Auto-approve mode (unattended runs):** if the env var `DUAL_BUILD_AUTO_APPROVE=1` is set (check with `Bash(echo "${DUAL_BUILD_AUTO_APPROVE:-0}")`), skip the user-confirmation pause. Write the proposed split to `_dual-build-plan.md` in the working directory for asynchronous review and proceed directly to Stage 1. Use only for unattended/benchmark runs (e.g., the test harness in the repo's `test-suite/`). Interactive use should keep the pause — the pause exists for a reason.

### Stage 1 — Parallel build

Once the user confirms the split, dispatch all builders in a SINGLE message with N parallel `Agent` tool calls.

For each subtask assigned to Claude:
```
Agent(
  subagent_type: "claude-builder",
  isolation: "worktree",
  description: "Build T<id>: <one-line goal>",
  prompt: "<full structured brief — Task ID, Goal, Brief, File scope, Acceptance, Project notes, plus 'Parent HEAD: <PARENT_HEAD_SHA>. Verify with `git log --oneline -3` and report the output in your final report.'>"
)
```

For each subtask assigned to Codex: same shape, `subagent_type: "codex-builder"`.

**Embed the parent's HEAD SHA in every brief.** This lets builders self-check their base and gives the orchestrator data to detect mismatches in Stage 1.5.

Wait for all to return. Each response includes the worktree path, branch name, files changed, and a structured report.

### Stage 1.5 — Verify worktree bases

**This is the single most important post-dispatch check.** Before proceeding to Stage 2, verify each worktree was rooted at the parent's HEAD. Worktrees occasionally default to `main` / HEAD-of-default rather than the working branch's tip, which silently invalidates the entire run (builders target outdated symbols, diffs don't merge cleanly, reviewers chase phantom conflicts).

For each builder report:

1. Each builder's report includes a `git log --oneline -3` output. Read it.
2. The third commit in that listing (the worktree's base before the builder's commits) should equal the parent HEAD SHA captured in prerequisites.
3. Cross-check: `git -C <worktree_path> merge-base HEAD <parent_head_sha>` must equal `<parent_head_sha>` exactly. (Parent HEAD must be an ancestor of the worktree's HEAD.)

If a base mismatch is detected for subtask T<id>:

- **Do not** proceed to cross-review for that subtask. The reviewer will chase phantom issues.
- Surface to user: "Worktree T<id> was rooted at <stale-sha> instead of expected <parent-head>. Builder may have targeted symbols that don't exist on the working branch. Recommend: re-rebase the worktree onto current HEAD and re-run that builder, OR abandon this subtask."
- Wait for user decision before continuing.

This single check would have prevented the entire FinancialResearch run failure (2026-05-05) where every worktree was rooted at a stale base.

### Stage 1.6 — Orchestrator commits Codex builder's edits (always)

As of v0.2.4, codex-builder agents do NOT attempt `git commit` themselves — the failure mode is reliable enough across runs (SecureCatch, mission-control, bugfix-trio, pastebin all hit it; pastebin had 2/3 builders fail) that preempting the attempt is cleaner than recovering from it. The orchestrator handles the commit step routinely.

For each subtask whose builder is `codex-builder`:

1. The builder's report includes its `git status --porcelain` output and the commit message it would have used (status: "Done — edits applied, awaiting orchestrator commit").
2. Spot-check one changed file with Read to confirm edits match the builder's reported summary.
3. Run the commit:
   ```
   git -C <worktree_path> add -A
   git -C <worktree_path> commit -m "<message from builder report>"
   ```
4. Continue to cross-review.

For `claude-builder` agents, the builder commits itself — no orchestrator commit step needed.

If a codex-builder somehow returns a successful `git commit -h <sha>` reference (rare, but possible if the sandbox ever permits writes), skip step 3 — the commit already exists.

### Stage 1.7 — Run tests in each worktree (pre-review verification)

Before dispatching reviewers, run the project's test command in each worktree from the orchestrator. This gives every reviewer the same verified ground truth and catches builder acceptance-claims that don't survive the test suite.

For each subtask's worktree:

1. Detect the test command. Heuristic order: `npm test` if `package.json` has a non-default `test` script; else `node --test` if `*.test.{js,mjs}` files exist; else `pytest` if `pyproject.toml`/`pytest.ini`/`tests/`; else skip with a note.
2. Run from the orchestrator: `git -C <worktree_path> ... ` or `cd <worktree> && <test_cmd>`. Capture pass/fail + last ~30 lines of output.
3. Include the result in the reviewer's brief as `Pre-review test result: PASS/FAIL` plus the captured output.
4. If a worktree's tests FAIL but the builder's report claimed acceptance passed, that's an automatic **Important** finding ("acceptance honesty") — the orchestrator should record it before dispatching the reviewer.

Why centralize test execution in the orchestrator: Codex reviewers run in `read-only` sandbox and cannot execute tests; Claude reviewers can but shouldn't run tests redundantly across N parallel reviewer dispatches. Centralizing gives every reviewer the same verified ground truth and the result is included in their brief.

### Stage 1.8 — Per-task failure handling

- **Builder returns Blocked or errored**: do NOT cancel the others. Report after all builders finish; ask whether to abort, retry that subtask, or proceed without it.
- **Codex 5xx or AnyIO timeout <60s**: retry the builder ONCE before escalating. These are usually transient API issues.
- **`❌ Codex handoff failed`**: the worktree may exist but be empty. Do NOT auto-retry on auth-related errors (401/403/expired token). Report and stop.

### Stage 2 — Parallel cross-review

Dispatch all reviewers in a SINGLE message with N parallel `Agent` calls. **Critical: each task is reviewed by the OPPOSITE model.** Claude-built tasks → `codex-reviewer`; Codex-built tasks → `claude-reviewer`.

Reviewers do NOT use `isolation: "worktree"` — they read the existing builder worktree directly via `git -C <path>` and the Read tool with absolute paths.

Single auto-retry on transient errors (HTTP 5xx, AnyIO timeout <60s with no useful output) before escalating.

Wait for all reviews. Each returns severity-tagged findings (Critical / Important / Praise) and a recommendation (Ready / Fix-before-merge / Rework).

#### Cross-review depth + verification

Reviewer findings can be **confidently wrong** — a past run had a Codex reviewer declare `JIRA_CSIRT_EMAIL` "referenced nowhere in the codebase" when it was actively used in `lib/jira.ts:46-48`. Don't apply findings blindly:

- **Spot-check Critical and Important findings** against ground truth before applying. Especially negative claims ("X is unused", "Y has no callers", "Z is dead code") — a 30-second `grep -r '<symbol>' .` saves applying a hallucinated finding.
- **Note review depth asymmetry**: Codex reviews on past runs have been substantially lighter than Claude reviews (4 praise bullets vs. paragraph-per-finding with file:line citations). If Codex's review of a Claude-built diff produces only "looks good" findings, prompt yourself: did the reviewer actually engage with edge cases? Sometimes the answer is "the diff really is clean"; sometimes the answer is "rerun with explicit edge-case prompting."

### Stage 3 — Consolidate & report

Produce a unified report grouped per task. For each task:

```
## T<id> — <goal>
**Assigned**: claude | codex
**Builder status**: Done | Done with caveats (commit recovered) | Blocked
**Worktree base**: ✅ matches parent HEAD | ❌ stale (T<id> excluded from review)
**Reviewer recommendation**: ✅ Ready / ⚠️ Fix Important / ❌ Rework

**Build summary** (from builder report): …
**Cross-review** (from reviewer): …
  - Critical findings: …
  - Important findings: …
  - Praise: …
**Verification spot-checks** (any reviewer claims you grep-verified): …
```

Then a top-level summary:

- Total tasks, ready vs. needs-rework count, any excluded due to base mismatch
- Cross-task issues you noticed (overlapping logic, contradicting assumptions, etc.) — these are things only the orchestrator can see
- Recommended merge order if some tasks depend on others

### Stage 4 — Apply or abandon

**Do NOT auto-merge.** Merging into the main checkout is a destructive operation that needs user confirmation. Present the consolidated report and ask for per-task decisions:

- **Merge**: `git merge --no-ff <branch>` (or `--squash`, per user preference) into the main checkout. Resolve conflicts if any (typically there should be none, since file_scopes were disjoint — if there are conflicts, surface them rather than silently resolving).
- **Rework**: leave the worktree and branch in place; the user may iterate.
- **Abandon**: `git worktree remove <path>` then `git branch -D <branch>`. Confirm with the user before deleting work.

#### Worktree cleanup gotcha

`git worktree remove` may fail with "cannot remove a locked working tree, lock reason: claude agent agent-… (pid …)". The Agent system locks worktrees while an agent task is "live" and doesn't auto-unlock when the task returns. **Don't reach for `-f -f`** — just unlock first:

```
git worktree unlock <path>
git worktree remove <path>
```

#### Post-merge verification

After merges complete, run the project's test suite (`npm test`, `pytest`, etc.) yourself in the main checkout. Reviewers are read-only and may not have been able to execute the full suite — the orchestrator is the final test-running step. If tests fail post-merge, you have a real signal that the cross-review missed something or the merges interacted unexpectedly.

Then ask whether to clean up remaining worktrees (run the unlock+remove sequence per worktree).

## Guardrails

- **Bail criteria are strict.** Re-read "When NOT to use" if Stage 0 produces an imbalanced or docs-heavy split — single-agent is the right tool more often than the workflow's framing suggests.
- **Worktree base verification is mandatory.** Stage 1.5 catches a real failure mode that has invalidated entire runs. Never skip it.
- **No auto-merge** without user confirmation per task.
- **No auto-cleanup** of worktrees or branches without confirmation. The user might want to inspect them.
- **The cross-review is mandatory.** If a reviewer fails, retry it once; if it still fails, report the gap to the user — do not skip the review and recommend merge.
- **Reviewer findings need spot-checks.** Confidently-wrong findings have shipped. Verify Critical/Important claims with `grep` or `Read` before applying.
- **Orchestrator runs the post-merge tests.** Reviewers can't always execute the suite; you're the final check.

## Cost note

A typical run is: N builder invocations (Opus + Codex) + N review invocations (Codex + Opus) + orchestrator overhead. For N=4 that's ~8 model calls plus the orchestrator's planning. Budget several minutes wall time and meaningful token spend.

The cross-review is what justifies the cost. On runs with substantive findings (e.g., race-condition catches, edge-case discoveries), it earns its keep. On runs with no findings — or with all findings being false positives — it's overhead. Bail criteria exist to avoid those runs.

## Changelog

**v0.2.4** (2026-05-06) — based on the pastebin test-suite run that produced a real cross-review catch (Express default-error-handler stack-leak in dev mode) and surfaced two structural improvements:
- **Reviewers must NOT assert on cross-task wiring.** A reviewer only sees one task's isolated worktree; sibling tasks aren't merged in. Pastebin's T2 reviewer falsely claimed `cleanupExpired()` was never called when it actually lives in T1's worktree. Reviewer prompts now explicitly forbid this — surface as "Cross-task contract — orchestrator spot-check on merge" instead of Critical/Important.
- **codex-builder no longer attempts `git commit` at all.** The read-only-fs failure has now hit 4+ runs reliably (SecureCatch, mission-control, bugfix-trio, pastebin). Codex builders stop after edits, include their intended commit message in the report, and the orchestrator commits on their behalf as a routine step (not a "recovery path"). Stage 1.6 reframed accordingly.

**v0.2.3** (2026-05-06) — based on the bugfix-trio test-suite run that completed acceptance with zero actionable cross-review findings:
- Bail threshold: <50 LOC bumped to <150 LOC total. Three textbook bugs at 111 LOC total passed all checks but the run produced no Critical/Important findings — the threshold was too generous.
- Added per-subtask floor: <40 LOC per subtask → bail. Median size matters as much as total.
- Added "textbook fixes" criterion: even at sufficient LOC, cross-review value is low when bugs follow obvious recipes.
- Added Stage 1.7: orchestrator runs the project's test command in each worktree before dispatching reviewers and includes the result in every reviewer's brief. Codex reviewers run in `read-only` sandbox and can't execute tests; this centralizes the verification step. Builder-claims-pass + pre-review-fails is automatically Important.

**v0.2.0** (2026-05-06) — based on four real test-run retrospectives across user projects (OSINT-Extension, FinancialResearch, SecureCatch, mission-control):
- Add Stage 1.5: post-dispatch worktree base verification (FinancialResearch run had every builder rooted at a stale commit, invalidating the whole pipeline).
- Add Stage 1.6: documented Codex-builder partial-success recovery (recurring "files-on-disk-but-uncommitted" mode in SecureCatch + mission-control runs).
- Add `git worktree unlock` cleanup step (mission-control run hit this).
- Add clean-tree precondition (worktrees-branch-from-HEAD invariant).
- Tighten bail criteria: balance check (<20% subtask), code-vs-docs threshold, hard <50 LOC threshold (OSINT-Extension run correctly bailed; criteria now codify why).
- Add single auto-retry on transient builder/reviewer errors.
- Embed parent HEAD SHA in builder briefs so builders can self-check base.
- Add cross-review depth + spot-check guidance (SecureCatch run had a Codex reviewer hallucinate a negative claim about `JIRA_CSIRT_EMAIL`).

**v0.1.0** (2026-05-05) — initial release.
