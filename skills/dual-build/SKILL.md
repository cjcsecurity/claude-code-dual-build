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

If any of these hold, decline the dual-build approach and offer a normal single-agent build instead:

- Single-file or <50 LOC changes
- Tightly coupled work where every subtask depends on every other
- Exploratory/interactive work where the user is steering turn-by-turn
- Time-sensitive fixes (this workflow takes minutes, not seconds)
- The decomposition produces overlapping file scopes that can't be made disjoint

State the bail reason explicitly to the user. Don't force-fit the workflow to make it look applicable.

## Required prerequisites

- Working directory must be a git repo (`git rev-parse --is-inside-work-tree`)
- Codex plugin healthy — `mcp__codex__codex` available and authenticated. If you're unsure, run `/codex:setup` to verify before starting.
- Worktrees feature available — standard git, but check `git worktree list` doesn't error.

If any prerequisite is missing, report it and stop before decomposing.

## Pipeline

### Stage 0 — Decompose

Read enough code (Glob, Grep, targeted Reads) to understand the module boundaries the task touches. Then produce a task split with these properties:

- **2–6 subtasks total.** Fewer is fine; more than 6 means the task is probably too granular and overhead will dominate.
- **File-disjoint.** No two subtasks may touch the same file. If two pieces of work touch the same file, merge them into one subtask. If you cannot achieve disjoint scopes, bail out — the workflow doesn't work without isolation.
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

### Stage 1 — Parallel build

Once the user confirms the split, dispatch all builders in a SINGLE message with N parallel `Agent` tool calls:

For each subtask assigned to Claude:
```
Agent(
  subagent_type: "claude-builder",
  isolation: "worktree",
  description: "Build T<id>: <one-line goal>",
  prompt: "<full structured brief — Task ID, Goal, Brief, File scope, Acceptance, Project notes>"
)
```

For each subtask assigned to Codex:
```
Agent(
  subagent_type: "codex-builder",
  isolation: "worktree",
  description: "Build T<id> via Codex: <one-line goal>",
  prompt: "<same structured brief>"
)
```

Wait for all to return. Each response includes the worktree path, branch name, files changed, and a structured report. Save these into a per-task record:

```
T1: { assigned: claude, worktree: /path/to/wt-T1, branch: agent/T1-foo, status: Done, ... }
T2: { assigned: codex,  worktree: /path/to/wt-T2, branch: agent/T2-bar, status: Done, ... }
…
```

Handle failures per-task:
- If a builder returns Blocked or errored, do NOT cancel the others. Report the failure to the user after all builders finish, and ask whether to abort, retry that subtask, or proceed with the remaining tasks.
- If a Codex builder reports `❌ Codex handoff failed`, the worktree may still exist but be empty. Note this and ask the user.

### Stage 2 — Parallel cross-review

Dispatch all reviewers in a SINGLE message with N parallel `Agent` calls. **Critical: each task is reviewed by the OPPOSITE model.** Claude-built tasks go to `codex-reviewer`; Codex-built tasks go to `claude-reviewer`.

For each Claude-built task (T):
```
Agent(
  subagent_type: "codex-reviewer",
  description: "Cross-review T<id> (Claude-built) via Codex",
  prompt: "<Task ID, Worktree path, Original brief, File scope, Builder's report, Review focus if any>"
)
```

For each Codex-built task (T):
```
Agent(
  subagent_type: "claude-reviewer",
  description: "Cross-review T<id> (Codex-built) via Claude",
  prompt: "<same shape>"
)
```

Reviewers do NOT use `isolation: "worktree"` — they read the existing builder worktree directly via `git -C <path>` and the Read tool with absolute paths.

Wait for all reviews. Each returns severity-tagged findings (Critical / Important / Praise) and a recommendation (Ready / Fix-before-merge / Rework).

### Stage 3 — Consolidate & report

Produce a unified report grouped per task. For each task:

```
## T<id> — <goal>
**Assigned**: claude | codex
**Builder status**: Done | Done with caveats | Blocked
**Reviewer recommendation**: ✅ Ready / ⚠️ Fix Important / ❌ Rework

**Build summary** (from builder report): …
**Cross-review** (from reviewer): …
  - Critical findings: …
  - Important findings: …
  - Praise: …
```

Then a top-level summary:

- Total tasks, ready vs. needs-rework count
- Cross-task issues you noticed (overlapping logic, contradicting assumptions, etc.) — these are things only the orchestrator can see
- Recommended merge order if some tasks depend on others

### Stage 4 — Apply or abandon

**Do NOT auto-merge.** Merging into the main checkout is a destructive operation that needs user confirmation. Present the consolidated report and ask for per-task decisions:

- **Merge**: `git merge --no-ff <branch>` (or `--squash`, per user preference) into the main checkout. Resolve conflicts if any (typically there should be none, since file_scopes were disjoint — if there are conflicts, surface them rather than silently resolving).
- **Rework**: leave the worktree and branch in place; the user may iterate.
- **Abandon**: `git worktree remove <path>` then `git branch -D <branch>`. Confirm with the user before deleting work.

After merges complete, ask whether to clean up remaining worktrees.

## Guardrails

- **File-disjoint enforcement is hard.** If Stage 0 cannot produce disjoint scopes, BAIL. Recommend a single-agent build instead. Don't try to be clever with overlapping scopes — it defeats the parallel-isolation property.
- **No auto-merge** without user confirmation per task.
- **No auto-cleanup** of worktrees or branches without confirmation. The user might want to inspect them.
- **Bail-out is fine, even mid-flight.** If, after reading code in Stage 0, you realize the task is smaller than expected, say so and switch to single-agent mode. Don't run the full pipeline on a 30-line change just because the user invoked /dual-build.
- **The cross-review is mandatory.** If a reviewer fails, retry it once; if it still fails, report the gap to the user — do not skip the review and recommend merge.

## Cost note

A typical run is: N builder invocations (Opus + Codex) + N review invocations (Codex + Opus) + orchestrator overhead. For N=4 that's ~8 model calls plus the orchestrator's planning. Budget several minutes wall time and meaningful token spend. Worth it when the cross-validation catches real bugs; not worth it for a one-file change. Choose accordingly.
