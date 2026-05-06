# /dual-build — when cross-review earns its keep (and when it doesn't)

Real findings from runs of `/dual-build` on actual codebases. Two sections:

1. **Cross-review catches** — when a fresh-eyes reviewer from the opposite model family flagged something the builder missed. These are the load-bearing artifacts for the workflow's value proposition.
2. **Negative results** — when the workflow ran cleanly but produced nothing actionable. These are the honest other half: cross-review on textbook fixes is theatre, and the workflow's bail criteria exist to avoid those runs. Showing both sides is the credible thing to do.

If you're evaluating whether `/dual-build` is the right tool for your task, read both sections — the "when it doesn't" cases are how you calibrate the bail criteria.

---

## Cross-review catches

### #1 — mission-control · Apps Stop button (2026-05-05)

**Project**: a local Next.js 14 dashboard (`mission-control`) for monitoring command-spawned and systemd-managed apps.

**Task**: implement a Stop button that kills command-spawned processes or stops systemd units, parallel to the existing Start button.

**Builder**: Codex (codex-builder)
**Reviewer**: Claude (claude-reviewer)
**LOC**: ~100 across `lib/apps.ts`, `app/apps/page.tsx`, `app/api/apps/[id]/stop/route.ts` (new)

#### Finding 1 — Important: SIGKILL → ESRCH race

The builder's stop logic polled the port for 5 seconds via `waitForPortToClose`, then unconditionally sent SIGKILL on timeout. The reviewer noticed:

> A process can die at t=4.9s while the kernel keeps the port in TIME_WAIT briefly afterward. The poll then "times out" even though the process is gone, and the SIGKILL targets a dead PID — `process.kill()` throws ESRCH, which the calling code surfaces to the user as a "stop failed" error despite the process having actually exited cleanly.

**Why a single-agent flow would have missed it**: the implementing model wrote both the polling logic and the SIGKILL fallback in one pass. The deadline path (poll-times-out-but-process-already-died) is exactly the kind of race that requires fresh eyes to spot. The reviewer came at the diff cold and traced the lifecycle.

#### Finding 2 — Important: `ss` failure paths leak raw error strings

The stop helper used `execFileSync('ss', '-tlnp', ...)`. The reviewer flagged two distinct UX failures:

1. If `ss` is missing on the system or exits non-zero, `execFileSync` throws `Error: Command failed: ss …`. This raw error reaches the API consumer instead of a user-readable "stop helper unavailable" message.
2. When the listening port is held by a *different* user's process, `ss -tlnp` doesn't include the `pid=<n>` field (the kernel doesn't expose other users' PIDs to non-root). The code's "no `pid=` found" branch returns "No process found listening on port X" — actively misleading, since the port IS in use, just by an unowned process.

**Why a single-agent flow would have missed it**: `ss`'s permission model (privilege-gated PID disclosure) is exactly the kind of platform detail that's easy to assume away when implementing. The fresh-eyes reviewer specifically considered "what if the port is held but `ss` doesn't show pid=" as an edge case worth checking.

#### Verifiability

Both findings are reproducible and concrete: a SIGTERM-signaled child that exits during the polling window, and a port held by another user (try `python3 -m http.server 8080` as a different user, then run the stop endpoint as your user). Both bugs would have shipped under a single-agent flow.

---

### #2 — pastebin test-suite run (2026-05-06) — caught a real bug, *with a footnote*

**Test fixture**: greenfield markdown pastebin scaffold (`test-suite/tests/02-pastebin/`). Empty repo with `express`, `better-sqlite3`, `marked` installed; build the whole app from scratch.

**Run**: A/B harness, both modes PASSED acceptance.

| Metric | Dual-build | Baseline |
|---|---|---|
| Acceptance | PASS | PASS |
| Wall time | 1214s (~20 min) | 309s (~5 min) |
| LOC | 362 across 5 files | 309 across 4 files |
| Cross-review findings | **0 Critical, 4 Important (3 real, 1 false positive)** | n/a |

#### What cross-review caught (Codex reviewing Claude's T2 server work)

> "Malformed JSON and body-limit errors will fall through to Express/finalhandler, which under the default `NODE_ENV=development` returns HTML with `err.stack`, violating the API JSON/error-leak expectations."

The dual-build builder shipped this fix: explicit 400/413 JSON responses for `entity.parse.failed` and `entity.too.large` in `src/server.js:18-33`. Real bug, real shippable fix, real production-relevant security/UX issue.

#### The footnote — what the LLM judge noticed

The judge ran `evaluate.sh` on both runs and flagged something the retros missed:

> *"The baseline never had that bug. Look at `sandbox-baseline/src/server.js:80-83`: the baseline ships a generic 4-arg JSON error handler from the start, so malformed JSON / oversized bodies return JSON 500 rather than HTML stack — no leak. The single-agent build naturally avoided the issue because it held the whole API surface in one head; the dual-build introduced it via task decomposition (T2 written against a contract, no body-parser-error pathway considered) and then the cross-review fixed it. Net cross-review value here ≈ recovering from a self-inflicted decomposition bug, not catching something a single agent would have shipped."*

Plus, baseline produced UX polish dual-build missed:

- `language_hint` auto-fences raw code → highlighted block
- Slug-shape regex guard (`^[a-z0-9]{4,16}$`) → `/favicon.ico` doesn't hit the DB
- Custom slug alphabet excluding `l`/`1`/`o`/`0`
- `pragma journal_mode = WAL`
- Strict `expires_in_hours` allowlist (`['1','24','168','never']`)

These are **cross-cutting design decisions** a single head naturally produces while holding the whole API surface in mind. Dual-build's three coordinated agents working from a written contract missed them. The judge's verdict: **baseline better**.

#### What this calibrates

The bail criterion that v0.2.4 added based on this run:

> **Tightly-coupled-by-design components** — even when file-disjoint, if design decisions span all subtasks (renderer behavior depends on API validation; all layers share an error-shape contract invented during the build), single-agent context produces *better* cross-cutting decisions than coordinated agents working from a pre-written contract. Cross-review catches decomposition damage but doesn't restore the cross-cutting design insight that was lost in the split.

The other two skill improvements this run drove (also in v0.2.4):

1. **Reviewers must NOT assert on cross-task wiring.** The Codex reviewer of T2 falsely claimed `cleanupExpired()` was never called when it lives in T1's worktree — structurally inevitable from single-worktree review. Reviewer prompts now explicitly forbid the assertion and route it to "cross-task contract — orchestrator spot-check on merge" instead.
2. **codex-builder no longer attempts `git commit`.** The read-only-fs failure has now hit 4+ runs reliably. Codex builders stop after edits and the orchestrator commits routinely. Stage 1.6 reframed as standard flow, not recovery.

---

## Negative results

### #N1 — bugfix-trio test-suite run (2026-05-06)

**Test fixture**: three intentional bugs in three file-disjoint files (`test-suite/tests/01-bugfix-trio/`):
- `server/index.js`: `POST /api/users` crashes on empty body (missing validation)
- `lib/dates.js`: `dayInPT` returns local-machine day instead of America/Los_Angeles day
- `public/search.js`: input handler fires on every keystroke (missing 250ms debounce)

**Run**: A/B harness in `test-suite/run-tests.sh`. Same task run twice — once with `/dual-build`, once as a single-agent baseline.

| Metric | Dual-build | Baseline |
|---|---|---|
| Acceptance | PASS | PASS |
| Wall time | 978s (~16 min) | 289s (~5 min) |
| Subagent dispatches | 6 + 3 orchestrator commits | 0 |
| Cross-review findings | **0 Critical, 0 Important** across all 3 tasks | n/a |

#### What the cross-reviewers actually said

- **T1 (dates) reviewer**: 0 Critical, 0 Important, 3 Praise. Sub-threshold (~70% confidence) caveat about test cases coincidentally passing the buggy code on a host whose own TZ is `America/Los_Angeles` — chose not to escalate. Real observation about test robustness, but the reviewer correctly judged it sub-threshold.
- **T2 (server validation) reviewer**: 0 Critical, 0 Important, 3 Praise. Reviewer noted it could not run `node --test` inside its sandbox; static review only. (This gap is what motivated v0.2.3's Stage 1.7 — orchestrator now runs tests pre-review and includes results in every reviewer's brief.)
- **T3 (debounce) reviewer**: 0 Critical, 0 Important, 4 Praise.

#### What the dual-build retro itself concluded

> *"No, I would not reach for /dual-build on a task this size again. The cross-review found nothing actionable. The bugs are small enough that the per-task tests gate quality on their own — three passing `node --test` files is a strong signal independent of having a second model read the diff. The workflow's value comes from cross-review catching things that would have shipped otherwise; here it caught zero such things across three subtasks."*

The baseline retro converged on the same verdict independently:

> *"Reaching for /dual-build here would have been overhead for ~no signal."*

#### Why this is an interesting result

1. **The workflow is willing to honestly self-assess.** The orchestrator wrote a verdict against itself. That's good for credibility — the skill isn't a hammer looking for nails.
2. **It surfaced a real shape mismatch.** "Three textbook fixes (validation, timezone, debounce) at 111 LOC total" passed the v0.2.0 bail threshold (`<50 LOC`) but the run made clear that threshold was too generous. v0.2.3 bumps the bail threshold to `<150 LOC` and adds a "textbook fixes" criterion based on this run.
3. **It validated the harness end-to-end.** `claude -p "/dual-build …"`, parallel build dispatch, Stage 1.5 base verification, Stage 1.6 Codex commit recovery (both Codex builders hit the documented "edits applied but commit failed" path and recovery worked), merges, post-merge tests — the whole pipeline ran clean. The pipeline working without producing findings is data; producing findings would have been more informative, but the negative result is still real signal.

#### What the LLM judge added (verdict: baseline better)

`evaluate.sh` runs a separate Claude judge over both retros, diffs, and acceptance results. It surfaced things neither retro caught:

> **Net cross-review value here: negative.** The T1 reviewer noticed (sub-threshold, ~70% confidence) that the dates test would coincidentally pass against the buggy `getDate()` on a host whose timezone is itself `America/Los_Angeles`. The reviewer chose not to escalate that observation. Baseline (single-agent) independently used `TZ=UTC`/`TZ=Asia/Tokyo` subprocess forcing to make the test deterministic regardless of host TZ. **Dual-build's test is weaker than baseline's *because* the reviewer dropped the finding under the confidence threshold.**

> **Code-quality deltas** the judge identified:
> - Baseline: `createApp()` factory (cleaner test seam) vs. dual-build: `export default app` singleton.
> - Baseline: 5 LOC of validation vs. dual-build: ~25 LOC (over-engineered for the spec).
> - Baseline: `*.test.js` (harness-discoverable) vs. dual-build: `*.js` in `test/` (the harness's `acceptance.sh` discovery pattern missed it; PASS was on regex-detection only, not executed tests).

#### Calibration takeaways

1. **Reviewer threshold is too strict for test-reliability findings.** A 70%-confidence "this test passes coincidentally" observation should escalate — the cost of fixing is trivial and the value of robust tests is high. v0.2.3's reviewer prompts add an explicit lower threshold for test-reliability + acceptance-honesty findings.
2. **The acceptance harness's test discovery was too narrow.** `*.test.js` only; `node --test` actually accepts `test/*.js` too. v0.2.3 broadens the discovery pattern.
3. **For "three obvious bugs, three obvious fixes, three obvious tests," reach for the regular Claude Code workflow.** For tasks like the mission-control entry above (concurrency, error paths, platform-specific behavior), reach for `/dual-build`. The bail criteria in `skills/dual-build/SKILL.md` codify the call.

---

*Format conventions: cross-review catches → builder model + reviewer model + LOC + each finding with what was produced, what was caught, and "why a single-agent flow would have missed it." Negative results → metrics + the retro's own verdict + what the result calibrated. Skip "the workflow ran" entries that produced neither real catches nor calibration insight.*
