#!/usr/bin/env bash
# run-tests.sh — orchestrate /dual-build A/B test runs.
#
# For each test under tests/<name>/, runs:
#   1. The dual-build version (DUAL_BUILD_AUTO_APPROVE=1 + /dual-build prompt)
#   2. The baseline version (same task, no /dual-build, single-agent)
# in fresh sandboxes, captures all output, runs acceptance.sh on each.
#
# Usage:
#   ./run-tests.sh             # run all tests
#   ./run-tests.sh bugfix      # run tests whose name contains "bugfix"
#   DUAL_BUILD_TIMEOUT=900 ./run-tests.sh   # override per-run timeout (default 1800s)
#
# Results land in results/<timestamp>/<test>/ with stream JSON, retros, git logs,
# and acceptance pass/fail. Run evaluate.sh on the timestamp dir afterward to
# get an LLM-judge A/B comparison.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="$ROOT/tests"
RESULTS_BASE="$ROOT/results"
TIMEOUT="${DUAL_BUILD_TIMEOUT:-1800}"

filter="${1:-}"

stamp=$(date +%Y%m%d-%H%M%S)
RESULTS="$RESULTS_BASE/$stamp"
mkdir -p "$RESULTS"

echo "Results: $RESULTS"
echo "Per-run timeout: ${TIMEOUT}s"
echo

# Retro instructions appended to every prompt so the run produces an evaluable doc.
read -r -d '' RETRO_TEMPLATE <<'EOF' || true

---

After completing this task (whether you finished, bailed early, or hit a blocker), write a candid retrospective to a file named RETRO.md in your working directory. Format:

## Run summary
- Date / time
- Branch
- Outcome (completed / bailed / blocked)
- If /dual-build was used: Stage where it ended (Stage 0 / Stage 1 / Stage 1.5 / Stage 2 / Stage 3 / Stage 4)
- Cross-review findings caught (Critical / Important / Praise per task) — if applicable

## What worked
- Specific things that went well, with file:line references where possible

## What broke / friction
- Bugs in the workflow, the harness, or the scaffolded code
- Things that were unclear or ambiguous

## Quality of result
- Did it produce working code? Did acceptance pass?
- Did cross-review (if used) catch anything real? Cite the finding verbatim.

## Time / cost
- Approximate wall time
- Number of subagent dispatches (if /dual-build was used)

## Verdict
- Would you reach for this approach again on this kind of task? Yes/no, why.

Be honest. If the workflow was overhead for this task, say so. If it produced real value, cite the specific finding.
EOF

run_one() {
  local test_dir="$1"
  local mode="$2"          # "dual-build" or "baseline"
  local prompt_file="$test_dir/prompt-${mode}.md"
  local out="$3"
  local sandbox="$out/sandbox-${mode}"

  if [[ ! -f "$prompt_file" ]]; then
    echo "  [${mode}] no prompt-${mode}.md, skipping"
    return 0
  fi

  echo "  [${mode}] setup -> $sandbox"
  bash "$test_dir/setup.sh" "$sandbox" > "$out/${mode}.setup.log" 2>&1

  local prompt
  prompt="$(cat "$prompt_file")"
  prompt+=$'\n'"$RETRO_TEMPLATE"

  local env_prefix=""
  if [[ "$mode" == "dual-build" ]]; then
    env_prefix="DUAL_BUILD_AUTO_APPROVE=1"
  fi

  echo "  [${mode}] running claude -p (timeout ${TIMEOUT}s)..."
  local start_ts=$(date +%s)
  local exit_code=0
  (
    cd "$sandbox"
    timeout "${TIMEOUT}" env $env_prefix claude -p "$prompt" \
      --permission-mode bypassPermissions \
      --output-format stream-json \
      --verbose
  ) > "$out/${mode}.stream.json" 2> "$out/${mode}.stderr" || exit_code=$?
  local end_ts=$(date +%s)
  local elapsed=$((end_ts - start_ts))

  echo "$exit_code" > "$out/${mode}.exit-code"
  echo "${elapsed}" > "$out/${mode}.elapsed-seconds"
  echo "  [${mode}] done in ${elapsed}s (exit ${exit_code})"

  # Capture artifacts
  if [[ -f "$sandbox/RETRO.md" ]]; then
    cp "$sandbox/RETRO.md" "$out/${mode}.retro.md"
  else
    echo "(no RETRO.md produced)" > "$out/${mode}.retro.md"
  fi
  if [[ -f "$sandbox/_dual-build-plan.md" ]]; then
    cp "$sandbox/_dual-build-plan.md" "$out/${mode}.plan.md"
  fi

  # Git state
  if [[ -d "$sandbox/.git" ]]; then
    git -C "$sandbox" log --all --oneline -100 > "$out/${mode}.git-log.txt" 2>/dev/null || true
    git -C "$sandbox" branch -a > "$out/${mode}.git-branches.txt" 2>/dev/null || true
    git -C "$sandbox" worktree list > "$out/${mode}.git-worktrees.txt" 2>/dev/null || true
    # Capture diffs per branch (anything not main)
    mkdir -p "$out/${mode}.diffs"
    while read -r br; do
      [[ -z "$br" ]] && continue
      [[ "$br" == "main" || "$br" == "master" ]] && continue
      [[ "$br" == "*"* ]] && br="${br#\* }"
      br="$(echo "$br" | tr -d ' ')"
      [[ "$br" == "remotes/"* ]] && continue
      git -C "$sandbox" diff "main...$br" > "$out/${mode}.diffs/${br//\//-}.patch" 2>/dev/null || true
    done < <(git -C "$sandbox" branch | sed 's/^[* ]*//')
  fi

  # Acceptance check
  if [[ -x "$test_dir/acceptance.sh" ]]; then
    echo "  [${mode}] acceptance"
    if bash "$test_dir/acceptance.sh" "$sandbox" > "$out/${mode}.acceptance.log" 2>&1; then
      echo PASS > "$out/${mode}.acceptance.txt"
    else
      echo FAIL > "$out/${mode}.acceptance.txt"
    fi
    echo "  [${mode}] acceptance: $(cat "$out/${mode}.acceptance.txt")"
  fi
}

run_test() {
  local test_dir="$1"
  local test_name
  test_name="$(basename "$test_dir")"
  local out="$RESULTS/$test_name"
  mkdir -p "$out"

  echo "=== $test_name ==="

  run_one "$test_dir" "dual-build" "$out"
  run_one "$test_dir" "baseline"   "$out"

  echo
}

found=0
for test_dir in "$TESTS"/*/; do
  test_name="$(basename "$test_dir")"
  if [[ -n "$filter" && "$test_name" != *"$filter"* ]]; then
    continue
  fi
  if [[ ! -f "$test_dir/setup.sh" ]]; then
    echo "Skipping $test_name: no setup.sh"
    continue
  fi
  found=$((found+1))
  run_test "$test_dir"
done

if [[ $found -eq 0 ]]; then
  echo "No tests matched filter: '$filter'"
  exit 1
fi

# Summary
echo "=== Summary ==="
{
  printf '%-32s %-12s %-12s %-10s %-10s\n' TEST DUAL-BUILD BASELINE D-TIME B-TIME
  for test_out in "$RESULTS"/*/; do
    name="$(basename "$test_out")"
    d_acc="$(cat "$test_out/dual-build.acceptance.txt" 2>/dev/null || echo n/a)"
    b_acc="$(cat "$test_out/baseline.acceptance.txt"   2>/dev/null || echo n/a)"
    d_t="$(cat   "$test_out/dual-build.elapsed-seconds" 2>/dev/null || echo n/a)s"
    b_t="$(cat   "$test_out/baseline.elapsed-seconds"   2>/dev/null || echo n/a)s"
    printf '%-32s %-12s %-12s %-10s %-10s\n' "$name" "$d_acc" "$b_acc" "$d_t" "$b_t"
  done
} | tee "$RESULTS/summary.txt"

echo
echo "Done. Results: $RESULTS"
echo "Run evaluate.sh '$RESULTS' for an LLM-judge A/B verdict."
