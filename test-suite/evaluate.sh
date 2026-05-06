#!/usr/bin/env bash
# evaluate.sh — LLM-judge A/B comparison of a results directory.
#
# Usage:
#   ./evaluate.sh results/20260506-120000
#
# For each test under the results dir, spawns a fresh `claude -p` call with
# the dual-build retro + baseline retro + diffs + acceptance results, asks
# the judge to score on (acceptance, cross-review value, fix quality, cost),
# and writes eval.md alongside the test outputs.
#
# Then aggregates verdicts into a top-level evaluation.md.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <results-dir>" >&2
  exit 1
fi

results="$1"
[[ -d "$results" ]] || { echo "not a directory: $results" >&2; exit 1; }

aggregate="$results/evaluation.md"
{
  echo "# A/B evaluation — $(basename "$results")"
  echo
  echo "Generated: $(date -Iseconds)"
  echo
} > "$aggregate"

for test_out in "$results"/*/; do
  [[ -d "$test_out" ]] || continue
  test_name="$(basename "$test_out")"
  [[ "$test_name" == "evaluation.md" ]] && continue

  echo "=== Evaluating $test_name ==="

  d_retro="$(cat "$test_out/dual-build.retro.md" 2>/dev/null || echo "(no dual-build retro)")"
  b_retro="$(cat "$test_out/baseline.retro.md"   2>/dev/null || echo "(no baseline retro)")"
  d_acc="$(cat   "$test_out/dual-build.acceptance.txt" 2>/dev/null || echo "n/a")"
  b_acc="$(cat   "$test_out/baseline.acceptance.txt"   2>/dev/null || echo "n/a")"
  d_log="$(head -50 "$test_out/dual-build.git-log.txt" 2>/dev/null || echo "(no git log)")"
  b_log="$(head -50 "$test_out/baseline.git-log.txt"   2>/dev/null || echo "(no git log)")"
  d_diffs="$(ls "$test_out/dual-build.diffs/" 2>/dev/null | head -10 || echo "(none)")"
  b_diffs="$(ls "$test_out/baseline.diffs/"   2>/dev/null | head -10 || echo "(none)")"
  d_t="$(cat "$test_out/dual-build.elapsed-seconds" 2>/dev/null || echo "n/a")"
  b_t="$(cat "$test_out/baseline.elapsed-seconds"   2>/dev/null || echo "n/a")"

  prompt=$(cat <<EOF
You are evaluating an A/B test of a /dual-build skill (Claude+Codex bidirectional cross-review) vs. a single-agent baseline on the same coding task.

Test name: $test_name

== Acceptance results ==
- Dual-build: $d_acc (elapsed: ${d_t}s)
- Baseline:   $b_acc (elapsed: ${b_t}s)

== Dual-build branches/diffs produced ==
$d_diffs

== Baseline branches/diffs produced ==
$b_diffs

== Dual-build git log (last 50) ==
$d_log

== Baseline git log (last 50) ==
$b_log

== Dual-build retrospective (written by the run itself) ==
$d_retro

== Baseline retrospective (written by the run itself) ==
$b_retro

Score on these dimensions, citing file:line where possible:

1. **Acceptance**: did each pass the test's acceptance check? (PASS/FAIL above is authoritative; restate.)
2. **Cross-review value**: did /dual-build's cross-reviewers catch anything real that the baseline missed (or the baseline catch something dual-build missed)? Quote the finding verbatim. If neither found anything substantive, say so.
3. **Quality of result**: how thorough was each? Did either introduce regressions or scope violations? Was the fix minimal-and-correct or sprawling?
4. **Cost vs. value**: was dual-build's overhead (~2-3x wall time, ~8 model calls vs. ~1) worth it for this specific task? Or did baseline produce equivalent output at a fraction of the cost?

End with a one-line verdict using EXACTLY one of these labels:
- VERDICT: dual-build clearly better
- VERDICT: comparable
- VERDICT: baseline better
- VERDICT: inconclusive — bad test design

Be specific. Cite. Don't pull punches.
EOF
)

  cd "$test_out"
  if claude -p "$prompt" --permission-mode bypassPermissions > eval.md 2> eval.stderr; then
    verdict="$(grep -E '^VERDICT:' eval.md | tail -1 || echo 'VERDICT: (no line found)')"
  else
    verdict="VERDICT: judge call failed"
    echo "(judge errored — see eval.stderr)" > eval.md
  fi
  cd - >/dev/null

  echo "  $verdict"

  {
    echo "## $test_name"
    echo
    echo "- Acceptance: dual-build=$d_acc, baseline=$b_acc"
    echo "- Wall time: dual-build=${d_t}s, baseline=${b_t}s"
    echo "- $verdict"
    echo
    echo "Full evaluation: \`$test_name/eval.md\`"
    echo
  } >> "$aggregate"
done

echo
echo "Aggregate: $aggregate"
