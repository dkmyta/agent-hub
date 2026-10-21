# Baseline: public v1 foundation

The state of the agent hub at the end of v1 (Jira), recorded when it was
tagged — to compare later releases, costs and behaviour against. It describes
the tagged commit; this file was added after it.

| | |
|---|---|
| Commit | `ae03b55c8c06d9d191fd7a6a8e6d7b6b47589bea` (merge of #107) |
| Tags | `v2.28.4`, `public-v1-foundation` — both on that commit, created after the evals below passed on it |
| Date | 2026-10-21 |
| Tracker | Jira (the only supported tracker) |
| Claude Code | 2.1.301 (pinned: `AGENT_HUB_CLAUDE_CODE_VERSION`), self-hosted runner with a Claude subscription login |

## What v1 covers

Every stage, end to end: the work order (with send-back for details and
`/revise`), the implementation plan (with questions back to the work order,
`/revise`, an attached plan file), and the build — a draft pull request from
the approved plan, its review and one fix pass with a fresh fix check, the
CI gate and a CI-fix attempt, the hand-off to a person, reconciling people's
commits and a moved target branch (mechanical and semantic drift, conflicts
left to a person), the item commands `/skip` and `/apply` (items and review
threads), the closed-pull-request handler (Done only after a completed
hand-off and a merge), per-ticket Claude caps, and the pause and kill
switches. The design and its known gaps:
[architecture.md](../../.github/agent-hub/docs/architecture.md),
[build.md](../../.github/agent-hub/docs/workflows/build.md),
[build-design.md](../../.github/agent-hub/docs/workflows/build-design.md).

## Evidence

**Tests (no Claude):** 585 cases. CI runs the whole suite on every pull
request: Linux with jq 1.7.1 and 1.8.2 (about 8½ minutes each) and macOS
with Bash 3.2 (about 17 minutes); the required checks are bound to the app
that posts them. On #107: all green.

**Live acceptance** ([`tools/live-tests/`](../live-tests/), on 2.28.1, one
Jira ticket through all three journeys, 2026-10-18 to 10-21): every step
passed. Measured Claude use, API-equivalent: journey 1 (work order and plan,
with a send-back and revisions) $2.67; journey 2 (build to hand-off) $0.62;
journey 3 (a person's commits, commands, target moves, a conflict) $1.06 —
$4.35 in all, including steps a normal ticket doesn't take. The follow-ups it
found are fixed in 2.28.2.

**Reviews:** two independent full reviews of the whole codebase (at 2.28.0
and 2.28.2, each by two reviewers, findings checked against the code), their
fixes in 2.28.1 and 2.28.3, and two further rounds of independent checking
of those fixes.

**Sandbox check** (`agent-hub-sandbox-check.yml`, on the 2.28.3 code, run
39674427641): every check passed in all three tool profiles (read-only,
build, review), $0.23.

**Evals on the tagged commit** — one case per stage, each the stage's key
decision ([evals.md](../../.github/agent-hub/docs/evals.md)):

| Stage | Case | Expected | Result | Model | Duration | Turns | Cost | Run |
|---|---|---|---|---|---|---|---|---|
| Work order | `too-vague` | needs-details | needs-details | claude-sonnet-5-5 | 17s | 2 | $0.05 | 39686889157 |
| Implementation plan | `open-product-decision` | needs-clarification | needs-clarification | claude-opus-5-5 | 26s | 8 | $0.27 | 39687016382 |
| Build | `missed-criterion` | the review finds the missed criterion, the fix pass fixes it, the fix check confirms it | 2 findings (2 fix-eligible), fix kept, both resolved | the defaults: build and review claude-opus-5-5, fix claude-sonnet-5-5 | 53s | — | $0.28 | 39687143222 |

All three on Claude Code 2.1.301, $0.60 in all. The remaining five cases
(`free-text-request`, `prompt-injection`, `npm-dependency`,
`readme-quick-start`, `stale-work-order`) weren't run for this baseline: run
them after a model or Claude Code change.

## Configuration at the baseline

- **Models (defaults):** work order `claude-sonnet-5-5` (fallback
  `claude-opus-5-5`); implementation plan and build `claude-opus-5-5`
  (fallback `claude-sonnet-5-5`); the expert review and the code review
  `claude-opus-5-5`; the build's fix pass `claude-sonnet-5-5`.
- **Budgets per pass (defaults):** work order $2.00 (review $2.00, revision
  $1.00); plan $5.00 (review $5.00, revision $2.00); build $10.00, code
  review $5.00, fix $3.00, fix check $1.00. Each pass may go over by $1.00
  (`AGENT_HUB_PASS_OVERSHOOT_USD`).
- **Per-ticket caps:** 10 runs and $60.00, across every stage, until a
  person lifts them.
- **CI-fix attempts:** 2 per reviewed head.
- **Setup checker** (`check-setup.sh --no-jira`, on this repository): 12
  verified, 0 blocked; 2 unverified by design (no install record in the
  hub's own repository; Claude Code's version is checked on the runner).

## Before real tickets

- **A runner of its own** — a dedicated macOS or Linux user, a dedicated
  machine, or GitHub-hosted runners with the Claude API — not a personal
  account ([runners.md](../../.github/agent-hub/docs/runners.md#before-running-the-build-on-real-tickets)).
  The baseline was taken on a personal machine, which is fine for testing
  the hub only.
- The build's [production checklist](../../.github/agent-hub/docs/workflows/build-design.md#production-checklist).
- While it isn't in use, [pause the hub](../../.github/agent-hub/docs/runners.md#pausing-the-hub).

## Known limits at the baseline

As documented: everyone with write access can run code on a self-hosted
runner; a build token that's a person's own (approvals by that person, their
edits to the pull request's record) — a separate identity is after v1; a
person's edit to the pull request's description in the instant the hub
writes its record is detected, not prevented; the tracker's automation
rules can't be read by the setup checker; a failed build stage's ❌ comment
stays after a later success (the work order and plan stages resolve theirs).
