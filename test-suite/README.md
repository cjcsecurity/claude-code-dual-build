# dual-build test suite

Automated A/B harness for the `/dual-build` skill. Each test runs the same coding task twice — once with `/dual-build`, once with a single-agent baseline — captures output, runs acceptance, and (optionally) sends both retros to a separate Claude-as-judge for evaluation.

## Layout

```
test-suite/
├── run-tests.sh            # main orchestrator — runs all tests
├── evaluate.sh             # LLM-judge A/B comparator (run after run-tests.sh)
├── tests/
│   ├── 01-bugfix-trio/     # buggy starter with 3 known bugs to fix
│   │   ├── setup.sh        # scaffolds the test repo into a sandbox dir
│   │   ├── prompt-dual-build.md   # /dual-build invocation
│   │   ├── prompt-baseline.md     # same task, no /dual-build
│   │   └── acceptance.sh   # PASS/FAIL check on the resulting code
│   └── 02-pastebin/        # greenfield app build
│       └── …
└── results/<timestamp>/    # per-run output (gitignored)
    └── <test-name>/
        ├── dual-build.stream.json   # full Claude stream
        ├── dual-build.retro.md      # auto-written retrospective
        ├── dual-build.git-log.txt
        ├── dual-build.diffs/<branch>.patch
        ├── dual-build.acceptance.txt   # PASS/FAIL
        ├── dual-build.elapsed-seconds
        ├── dual-build.exit-code
        ├── baseline.*       # same shape for the baseline run
        ├── eval.md          # written by evaluate.sh
        └── eval.stderr
```

## Prerequisites

- `claude` CLI on `$PATH` (same one that runs Claude Code interactively).
- Codex MCP plugin installed and authenticated. Run `/codex:setup` once interactively to verify before kicking off a long batch.
- `~/.claude/skills/dual-build/SKILL.md` and `~/.claude/agents/{claude,codex}-{builder,reviewer}.md` present (install via `./install.sh` from the repo root, or via the plugin system).
- `permissions.allow` includes `mcp__codex__codex` and `mcp__codex__codex-reply` in `~/.claude/settings.json` (so subagents don't prompt). See repo README's setup notes.
- `bash`, `git`, `node`, `npm` on `$PATH`. Specific tests may need more (`pytest`, `uv`, etc. — gated per fixture).

## Run

```bash
# Run all tests
./run-tests.sh

# Run only tests whose name contains "bugfix"
./run-tests.sh bugfix

# Custom per-run timeout (default 1800s)
DUAL_BUILD_TIMEOUT=900 ./run-tests.sh

# Then evaluate the most recent results
./evaluate.sh results/20260506-120000
```

## What the harness does per test

1. **Sandbox**: creates a fresh `results/<stamp>/<test>/sandbox-dual-build/` directory and runs `tests/<test>/setup.sh` against it. Same for `sandbox-baseline/`.
2. **Dual-build run**: appends a retro template to `prompt-dual-build.md` and invokes `DUAL_BUILD_AUTO_APPROVE=1 claude -p "$prompt" --permission-mode bypassPermissions --output-format stream-json --verbose`. The env var skips Stage 0 user-confirmation (dumps the proposed split to `_dual-build-plan.md` instead).
3. **Baseline run**: same task without `/dual-build` in the prompt, plain Claude single-agent.
4. **Capture**: stream JSON, stderr, RETRO.md, git log/branches/worktrees, per-branch diffs, exit code, wall time.
5. **Acceptance**: runs `tests/<test>/acceptance.sh <sandbox>` to score PASS/FAIL on each side.
6. **Summary table** printed at the end, also written to `results/<stamp>/summary.txt`.

`evaluate.sh` reads each test's outputs and asks a fresh Claude judge to score the A/B on acceptance, cross-review value, quality, and cost. Verdicts aggregate into `results/<stamp>/evaluation.md`.

## Adding a new test

Drop a directory under `tests/` with these four files:

### `setup.sh`

Scaffolds the test repo. Receives the destination sandbox path as `$1`.

```bash
#!/usr/bin/env bash
set -euo pipefail
sandbox="$1"
mkdir -p "$sandbox"
cd "$sandbox"
git init -q -b main
# … create files, install minimum deps, commit initial state …
git add . && git commit -qm "initial"
```

The sandbox should be a self-contained git repo with the initial state committed. The harness will run `claude -p` from inside this directory.

### `prompt-dual-build.md`

The `/dual-build` invocation. Should be a goal-only prompt (let the orchestrator decompose), not a pre-split T1/T2/T3 plan. The harness appends a retro template automatically.

```markdown
/dual-build <goal + context + constraints>
```

### `prompt-baseline.md`

Same task without `/dual-build`. Plain Claude single-agent. Harness still appends the retro template.

```markdown
<same goal + context as the dual-build prompt, but no slash command>
```

The point of the A/B is that both prompts are functionally equivalent — only the workflow differs.

### `acceptance.sh`

Receives the sandbox path as `$1`. Exits 0 for PASS, non-zero for FAIL. Should be deterministic and not require human judgment. Heuristic checks (`git diff` content matches expected patterns, files exist, `npm test` passes) are fine — perfect grading is impossible, but signal is enough.

```bash
#!/usr/bin/env bash
set -e
sandbox="$1"
cd "$sandbox"
# Heuristic: did the build modify the expected files?
git diff main --name-only | grep -qE '<expected file>' || exit 1
# Run the project's tests if they exist
[[ -f package.json ]] && npm test --silent
echo PASS
```

### Then make `setup.sh` and `acceptance.sh` executable

```bash
chmod +x tests/<your-test>/setup.sh tests/<your-test>/acceptance.sh
```

That's it. The harness auto-discovers any directory under `tests/` that contains a `setup.sh`. Realistic effort to add a test: 15-30 minutes once you know what task you want to grade.

## Caveats

- Each run can take 5-15 minutes wall time and meaningful tokens. A full A/B sweep over N tests is ~2N runs at this cost.
- The auto-approve env gate skips Stage 0 user-confirmation; the proposed split is dumped to `_dual-build-plan.md` instead. If the orchestrator picks a bad split, you'll only see it post-hoc.
- Acceptance checks are heuristic by design — perfect grading would require running the project's hidden test suite. The retros + diffs are the qualitative signal; acceptance is the binary one.
- `claude -p` exits when the response stops streaming, not when subagent worktrees are fully cleaned up. Sometimes worktrees linger; re-running setup.sh into the same path will git-init over them which is fine, but check `git worktree prune` if you see stale worktrees accumulating.
