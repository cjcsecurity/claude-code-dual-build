# /dual-build — what cross-review caught

Real findings from runs of `/dual-build` on actual codebases. Each entry shows what the builder produced and what the OPPOSITE-model reviewer flagged that the builder missed. These are the load-bearing artifacts for the workflow's value proposition: *"different model families catch different bug classes."*

If `/dual-build` doesn't produce findings of this quality on your work, it's overhead — see [`skills/dual-build/SKILL.md`](skills/dual-build/SKILL.md) "When NOT to use" for the bail criteria.

---

## #1 — mission-control · Apps Stop button (2026-05-05)

**Project**: a local Next.js 14 dashboard (`mission-control`) for monitoring command-spawned and systemd-managed apps.

**Task**: implement a Stop button that kills command-spawned processes or stops systemd units, parallel to the existing Start button.

**Builder**: Codex (codex-builder)
**Reviewer**: Claude (claude-reviewer)
**LOC**: ~100 across `lib/apps.ts`, `app/apps/page.tsx`, `app/api/apps/[id]/stop/route.ts` (new)

### Finding 1 — Important: SIGKILL → ESRCH race

The builder's stop logic polled the port for 5 seconds via `waitForPortToClose`, then unconditionally sent SIGKILL on timeout. The reviewer noticed:

> A process can die at t=4.9s while the kernel keeps the port in TIME_WAIT briefly afterward. The poll then "times out" even though the process is gone, and the SIGKILL targets a dead PID — `process.kill()` throws ESRCH, which the calling code surfaces to the user as a "stop failed" error despite the process having actually exited cleanly.

**Why a single-agent flow would have missed it**: the implementing model wrote both the polling logic and the SIGKILL fallback in one pass. The deadline path (poll-times-out-but-process-already-died) is exactly the kind of race that requires fresh eyes to spot. The reviewer came at the diff cold and traced the lifecycle.

### Finding 2 — Important: `ss` failure paths leak raw error strings

The stop helper used `execFileSync('ss', '-tlnp', ...)`. The reviewer flagged two distinct UX failures:

1. If `ss` is missing on the system or exits non-zero, `execFileSync` throws `Error: Command failed: ss …`. This raw error reaches the API consumer instead of a user-readable "stop helper unavailable" message.
2. When the listening port is held by a *different* user's process, `ss -tlnp` doesn't include the `pid=<n>` field (the kernel doesn't expose other users' PIDs to non-root). The code's "no `pid=` found" branch returns "No process found listening on port X" — actively misleading, since the port IS in use, just by an unowned process.

**Why a single-agent flow would have missed it**: `ss`'s permission model (privilege-gated PID disclosure) is exactly the kind of platform detail that's easy to assume away when implementing. The fresh-eyes reviewer specifically considered "what if the port is held but `ss` doesn't show pid=" as an edge case worth checking.

### Verifiability

Both findings are reproducible and concrete: a SIGTERM-signaled child that exits during the polling window, and a port held by another user (try `python3 -m http.server 8080` as a different user, then run the stop endpoint as your user). Both bugs would have shipped under a single-agent flow.

---

*This is a starter gallery. Add new entries as runs produce real cross-review catches. The format: task summary → builder + reviewer + LOC → each finding with what was produced and what was caught → "why a single-agent flow would have missed it." Skip runs where the cross-review found nothing real — that's a different signal (see "When NOT to use" in the skill doc).*
