# Changelog

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
