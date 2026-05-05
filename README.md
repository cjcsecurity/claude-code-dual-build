# claude-code-dual-build

Symmetric multi-agent build with mandatory cross-review for Claude Code + Codex.

Splits a coding task in half between **Claude** and **Codex**, runs both in parallel in isolated git worktrees, then has the **opposite model** review each diff before consolidation. The cross-review is the load-bearing piece — different model families catch different bug classes, so a Claude diff reviewed by Codex (and vice versa) surfaces issues neither would catch alone.

## What makes this different

The Claude+Codex multi-agent space already has many tools. They organize roughly into these patterns:

- **Asymmetric** — one model builds, the other reviews. The official Codex plugin for Claude Code does this opportunistically.
- **Single-model parallel** — one orchestrator + N same-model workers in parallel.
- **Sequential pipeline** — build → review → fix, with one builder.
- **Consensus drafting** — all models produce the same output and vote on differences (works well for papers, less so for code).
- **Multi-reviewer fan-out** — N models review the *same* diff in parallel.
- **Communication bridge** — messaging infrastructure between agents, with no enforced workflow.

Dual-build is **none of those**. It does the combination they don't:

- **Both models actively build.** ~50/50 split of subtasks between Claude and Codex. Neither is "just the reviewer" or "just the builder."
- **Bidirectional cross-review.** Each diff is reviewed by the **opposite** model in parallel — Claude reviews Codex's diffs, Codex reviews Claude's diffs.
- **File-disjoint scopes + worktree isolation.** Subtasks are required to touch different files; each runs in its own auto-managed git worktree on its own branch. No merge collisions during parallel work.
- **Lightweight.** One skill + four agents, ~700 lines of markdown total. No framework, no MCP server, no daemon.

## Workflow

```
                          ┌─ Claude builder T1 ┐    ┌─ Codex reviewer T1 ┐
              ┌─ Claude ──┤                    │    │                    │
              │           └─ Claude builder T3 ┤    ├─ Codex reviewer T3 ┤
  /dual-build ┤                                │    │                    │
              │           ┌─ Codex builder T2 ─┤    ├─ Claude reviewer T2┤
              └─ Codex  ──┤                    │    │                    │
                          └─ Codex builder T4 ─┘    └─ Claude reviewer T4┘
                          (parallel, in isolated worktrees)   (parallel)
                                       │
                                       ▼
                         Consolidated report → user merges per task
```

1. **Decompose.** Orchestrator (Claude) splits the prompt into 2–6 file-disjoint subtasks, ~50/50 between the two models, then **shows the split for confirmation before dispatching anything.**
2. **Build.** All subtasks run in parallel, each in its own worktree on its own branch. Claude subtasks run via the `claude-builder` agent; Codex subtasks via the `codex-builder` agent (which forwards to `mcp__codex__codex` with `cwd` pinned to the worktree).
3. **Cross-review.** Each diff is reviewed by the opposite model in parallel. Claude-built tasks → `codex-reviewer`; Codex-built tasks → `claude-reviewer`. Reviewers use confidence-scored severity (Critical / Important) and only report findings ≥80 confidence.
4. **Consolidate.** Unified report per task: builder summary + reviewer findings + recommendation (Ready / Fix / Rework).
5. **Apply.** User decides per task — merge, rework, or abandon. **No auto-merge.** Worktrees and branches remain until the user cleans them up.

## Install

### Option 1: Claude Code plugin (recommended)

```
/plugin marketplace add cjcsecurity/claude-code-dual-build
/plugin install claude-code-dual-build@cjcsecurity/claude-code-dual-build
```

### Option 2: Manual install

```bash
git clone https://github.com/cjcsecurity/claude-code-dual-build.git
cd claude-code-dual-build
./install.sh
```

This copies four agents into `~/.claude/agents/` and the skill into `~/.claude/skills/dual-build/`. Restart Claude Code if the new agents/skill don't appear immediately.

## Prerequisites

- **Claude Code** (any recent version with skills + custom agents support).
- **Codex plugin** for Claude Code, installed and authenticated, so `mcp__codex__codex` is available. Install: https://github.com/openai/codex-plugin-cc. Verify: run `/codex:setup` in Claude Code.
- A **git repository** with `git worktree` support (standard with modern git).

The skill checks these prerequisites in Stage 0 and bails clearly if anything is missing.

## Usage

```
/dual-build add a /healthz endpoint, write tests for it, and update the README
```

The orchestrator will:

1. Read the relevant code, propose a task split (e.g., T1 endpoint → Claude, T2 tests → Codex, T3 README → Claude).
2. Show you the split and wait for confirmation.
3. Dispatch all builders in parallel, each in its own worktree.
4. Cross-review each diff with the opposite model, in parallel.
5. Present a consolidated report with severity-tagged findings.
6. Ask you per task: merge, rework, or abandon.

## When NOT to use it

The skill explicitly bails to single-agent mode when:

- The change is single-file or under ~50 LOC. Overhead exceeds value.
- Subtasks can't be made file-disjoint (everything touches one core file).
- The task is exploratory / interactive — you're steering turn-by-turn.
- A fast hotfix is needed. The full pipeline takes minutes.

For these cases, plain Claude Code or the official Codex plugin's opportunistic delegation works better.

## Cost

A typical 4-subtask run is ~8 model calls (4 builds + 4 reviews) plus orchestrator overhead. Expect several minutes of wall time and meaningful token spend. The cross-validation is what justifies it; for trivial work, skip this skill.

## Files

```
.claude-plugin/plugin.json
agents/
  claude-builder.md      # Implements one subtask in an isolated worktree (Opus)
  codex-builder.md       # Forwards subtask to Codex via mcp__codex__codex (Sonnet)
  claude-reviewer.md     # Fresh-eyes reviewer of a builder's worktree (Opus)
  codex-reviewer.md      # Forwards review to Codex via mcp__codex__codex (Sonnet)
skills/dual-build/
  SKILL.md               # The orchestrator manual — Stages 0–4 of the workflow
install.sh               # Manual install helper for non-plugin users
SECURITY.md              # Vulnerability reporting policy
LICENSE                  # MIT
```

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure policy.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Keep PRs focused — one improvement per PR. The skill intentionally stays small; please discuss before adding new stages or agents.
