<p align="center">
  <img src="assets/dual-build-banner.png" alt="Dual Build — Two models. Two perspectives. Better code." width="100%" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT License"></a>
  <a href="https://github.com/cjcsecurity/claude-code-dual-build/releases"><img src="https://img.shields.io/github/v/release/cjcsecurity/claude-code-dual-build" alt="Release"></a>
  <a href="https://github.com/cjcsecurity/claude-code-dual-build/stargazers"><img src="https://img.shields.io/github/stars/cjcsecurity/claude-code-dual-build?style=social" alt="GitHub stars"></a>
  <img src="https://img.shields.io/badge/Claude%20Code-compatible-D97757?logo=anthropic&logoColor=white" alt="Claude Code compatible">
  <img src="https://img.shields.io/badge/Codex-compatible-10A37F?logo=openai&logoColor=white" alt="Codex compatible">
</p>

# claude-code-dual-build

**Symmetric multi-agent build with mandatory cross-review for Claude Code + Codex.**

Splits a coding task in half between Claude and Codex, runs both in parallel in isolated git worktrees, then has the **opposite model** review each diff before consolidation. Different model families catch different bug classes — a Claude diff reviewed by Codex (and vice versa) surfaces issues neither would catch alone.

## Quick start

```bash
git clone https://github.com/cjcsecurity/claude-code-dual-build.git
cd claude-code-dual-build && ./install.sh
```

Then in any git repo with the [official Codex plugin](https://github.com/openai/codex-plugin-cc) authenticated:

```
/dual-build add a /healthz endpoint, write tests, and update the README
```

The orchestrator proposes a file-disjoint task split, dispatches parallel builders in isolated worktrees, runs the cross-review, and presents a consolidated report for you to merge.

## What real cross-review catches

From the [first entry](EXAMPLES.md) in our worked-examples gallery — Claude reviewing Codex's work on a `mission-control` Stop button:

> **Important: SIGKILL → ESRCH race.** A process can die at t=4.9s during the 5s deadline window while the kernel keeps the port in TIME_WAIT briefly afterward. The poll then "times out" even though the process is gone, and the SIGKILL targets a dead PID — `process.kill()` throws ESRCH, which the calling code surfaces to the user as a "stop failed" error despite the process having actually exited cleanly.

> **Important: `ss` failure paths leak raw error strings.** When the listening port is held by a *different* user's process, `ss -tlnp` doesn't include the `pid=<n>` field (the kernel doesn't expose other users' PIDs to non-root). The code's "no `pid=` found" branch returns "No process found listening on port X" — actively misleading, since the port IS in use, just by an unowned process.

Real bugs that would have shipped under a single-agent flow. The implementing model wrote both happy-path and fallback in one pass; the deadline race and the `ss` permission model are exactly the kind of edge cases that need fresh eyes from a different model family.

## What makes this different

The Claude+Codex multi-agent space already has many tools. They organize roughly into these patterns:

| Pattern | Examples | Why dual-build is different |
|---|---|---|
| Asymmetric (one builds, one reviews) | Codex MCP plugin, `cavekit`, `claude-codex-loop` | Only one model produces code |
| Single-model parallel | `swarms`, `evo` | Not cross-model |
| Sequential pipeline (build → review → fix) | `compound-engineering` | Single builder |
| Consensus drafting (vote on same content) | `Trivium` | Designed for papers, not code |
| Multi-reviewer fan-out | `agent-triforge`, `ktaletsk/council` | No work split, just review |
| Communication bridge | `claude_codex_bridge`, `bernstein` | Infra only, no enforced workflow |

**Dual Build does the combination none of those do**:

- **Both models actively build.** ~50/50 split of subtasks. Neither is "just the reviewer" or "just the builder."
- **Bidirectional cross-review.** Each diff is reviewed by the *opposite* model in parallel — Claude reviews Codex's diffs, Codex reviews Claude's diffs.
- **File-disjoint scopes + worktree isolation.** Subtasks must touch different files; each runs in its own auto-managed git worktree. Safe parallelism, no merge collisions.
- **Lightweight.** One skill + four agents, ~700 lines of markdown. No framework, no MCP server, no daemon.

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

1. **Decompose.** Orchestrator (Claude) splits the prompt into 2–6 file-disjoint subtasks, ~50/50 between models, then **shows the split for confirmation before dispatching anything.**
2. **Build.** All subtasks run in parallel, each in its own worktree on its own branch. Claude subtasks via `claude-builder`; Codex subtasks via `codex-builder` (forwards to `mcp__codex__codex` with `cwd` pinned to the worktree).
3. **Cross-review.** Each diff reviewed by the opposite model in parallel. Confidence-scored severity (Critical / Important), only findings ≥80 confidence reported.
4. **Consolidate.** Unified report per task: builder summary + reviewer findings + recommendation (Ready / Fix / Rework).
5. **Apply.** User decides per task — merge, rework, or abandon. **No auto-merge.**

## Automated test suite

[`test-suite/`](test-suite/) is an A/B harness that runs the same coding task twice — once with `/dual-build`, once as a single-agent baseline — and (optionally) sends both retros to a Claude judge for an automated verdict.

```bash
cd test-suite
./run-tests.sh             # all tests
./evaluate.sh results/<timestamp>
```

Adding a new test is a 4-file drop into `tests/<name>/`: `setup.sh`, `prompt-dual-build.md`, `prompt-baseline.md`, `acceptance.sh`. See [`test-suite/README.md`](test-suite/README.md).

## Install

### Option 1: Claude Code plugin marketplace

```
/plugin marketplace add cjcsecurity/claude-code-dual-build
/plugin install claude-code-dual-build@cjcsecurity/claude-code-dual-build
```

### Option 2: Manual install

```bash
git clone https://github.com/cjcsecurity/claude-code-dual-build.git
cd claude-code-dual-build && ./install.sh
```

Copies four agents into `~/.claude/agents/` and the skill into `~/.claude/skills/dual-build/`. Restart Claude Code if the new pieces don't appear immediately.

### Pre-authorize Codex MCP (recommended)

For unattended runs, add this to `~/.claude/settings.json` so the codex-builder/reviewer agents don't prompt:

```json
{
  "permissions": {
    "allow": [
      "mcp__codex__codex",
      "mcp__codex__codex-reply"
    ]
  }
}
```

## Prerequisites

- **Claude Code** (recent, with custom skills + agents support).
- **[Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc)**, authenticated. Verify with `/codex:setup`.
- A **git repository** with worktree support (standard with modern git).
- A **clean working tree** when you invoke `/dual-build` — worktrees branch from HEAD, so uncommitted changes are invisible to builders.

The skill checks all of these in Stage 0 and bails clearly if anything is missing.

## When NOT to use

The skill explicitly bails to single-agent if any of these hold:

- Total LOC delta is **<50** across all subtasks.
- Any subtask is **<20% of the total LOC delta** (imbalanced split defeats cross-review).
- Decomposition is **docs-heavy** — cross-review on README/setup prose is theatre.
- Decomposition can't be made **file-disjoint** — everything touches one hot file.
- Time-sensitive hotfix — the workflow takes minutes, not seconds.
- Working tree is dirty.

For these, plain Claude Code or the Codex plugin's opportunistic delegation works better. Bailing is a valid output of the skill.

## Cost

A typical 4-subtask run is ~8 model calls (4 builders + 4 reviewers) plus orchestrator overhead. Several minutes of wall time, meaningful token spend. The cross-validation is what justifies it on substantive multi-component work; bail criteria exist to avoid running it on trivial changes.

## Files

```
.claude-plugin/plugin.json
agents/
  claude-builder.md      # Implements one subtask in an isolated worktree (Opus)
  codex-builder.md       # Forwards subtask to Codex via mcp__codex__codex (Sonnet)
  claude-reviewer.md     # Fresh-eyes reviewer of a builder's worktree (Opus)
  codex-reviewer.md      # Forwards review to Codex via mcp__codex__codex (Sonnet)
skills/dual-build/
  SKILL.md               # The orchestrator manual — Stages 0–4
test-suite/              # A/B harness for grading vs single-agent baseline
EXAMPLES.md              # Gallery of real cross-review catches
CHANGELOG.md             # Version history
install.sh               # Manual install for non-plugin users
SECURITY.md              # Vulnerability reporting policy
LICENSE                  # MIT
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Recent releases:

- **v0.2.1** — Automated A/B test harness + Stage 0 auto-approve env gate.
- **v0.2.0** — Improvements from four real test-run retrospectives (Stage 1.5 worktree base verification, Codex commit recovery, tighter bail criteria, reviewer hallucination guards).
- **v0.1.0** — Initial release.

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure policy.

## Contributing

Issues and PRs welcome. Keep PRs focused — one improvement per PR. The skill intentionally stays small; please discuss before adding new stages or agents.

## License

MIT — see [LICENSE](LICENSE).
