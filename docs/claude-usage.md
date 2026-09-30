# When Claude is used

Claude is only used when a ticket or a person asks for it. Tests, git hooks
and CI never use it. This page explains how usage happens, what triggers it,
and how the evals fit in.

## How usage happens

- **The runner** is the machine that runs the agent workflows' jobs — by
  default a self-hosted runner (see [runners.md](runners.md)).
- **Claude Code** is installed on the runner and signed in to a Claude account
  (a subscription login, or an API key).
- **One step per agent workflow uses Claude** (e.g. *Generate work order*,
  *Write implementation plan*), in two passes: a **draft**, then an **expert
  review** that checks and improves it (see
  [architecture.md](architecture.md#expert-review-every-stage)). Both run
  `claude` with the ticket, read the repository and research; that's the only
  point where Claude is used — it counts against the account's plan limits
  (subscription) or is billed (API), like any other Claude Code session.
- **Everything else is plain scripts**: fetching the ticket, writing the work
  order to Jira, posting and resolving comments. None of it uses Claude.

## What triggers it

| Trigger | Uses Claude? |
|---|---|
| A Jira rule sends a ticket to a stage (Work Order, Work Order Approved) | **Yes** — one run per request |
| A `/revise` comment on a ticket in Intake, Work Order, Work Order Approved or Implementation Plan (Revision Requested rule) | **Yes** — one run per comment. A revision is scoped to the requested changes, so it's usually well under a new run's cost; a retry or resubmission costs a normal run |
| **Run workflow** on an agent workflow in the Actions tab | **Yes** |
| Running the evals — **Agent Evals** in the Actions tab, or `npm run evals --prefix tests -- <stage>`, confirmed by typing `use-claude` | **Yes**, deliberately |
| Committing or pushing (pre-commit / pre-push hooks) | No |
| Opening or updating a pull request, or pushing to `main` (CI) | No |
| Running the tests (`npm test --prefix tests`) | No |

Each run's summary (in the Actions run page) shows the models used, the
Claude Code version, and the turns and **API-equivalent cost** of each pass —
the draft and the expert review — so you can see which one costs what. Each
pass has a cap: `CLAUDE_MAX_BUDGET_USD` / `PLAN_CLAUDE_MAX_BUDGET_USD` for the
draft, `REVIEW_CLAUDE_MAX_BUDGET_USD` for the review, and a lower
`REVISION_MAX_BUDGET_USD` / `PLAN_REVISION_MAX_BUDGET_USD` for both passes of
a revision, which is scoped to the requested changes.

**Typical usage** (API-equivalent; the single source for these figures — other
docs link here):

| | Typical | Notes |
|---|---|---|
| One work order (draft + review) | $0.30–1.50 | Clear requests cost more (research); bounced tickets under $0.50 |
| One implementation plan (draft + review) | $1.50–7 | Several minutes; scales with the change. Opus costs more than Sonnet |
| One eval case | As one real run of its stage | Each case runs the draft and the review |
| Work order evals (3 cases) | $1–3 | A few minutes |
| Implementation plan evals (3 cases) | $3–10 | 20–40 minutes |
| Every stage (**all**) | The sum; up to $4–13, over the $10 default cap: raise it for that run | Only after a model or Claude Code change |

## Tests vs evals

**Tests** check the plumbing with a stand-in `claude` that replays recorded
answers, so they never reach Claude. **Evals** check the decisions with the
real Claude, only when started by hand, for the stages you name. When
they're worth running, their guards, and the PR notice that suggests them:
**[evals.md](evals.md)**.

## Safeguards

- A test step **refuses to run** if `claude` would resolve to the real Claude
  Code rather than the stand-in, so a test can never reach a real login.
- The evals **skip themselves** unless `RUN_EVALS=1` is set, which only the
  eval runner sets, after a stage is named and `use-claude` is typed — see
  [evals.md](evals.md) for all their guards.
- A test checks that **every workflow that uses Claude** only runs on Jira
  requests (`repository_dispatch`) or manual runs (`workflow_dispatch`) —
  never on pushes, pull requests or schedules.
- Runs from GitHub (agent stages and evals) only use the runner in
  `AGENT_RUNS_ON`; with it offline nothing runs, but a run started meanwhile
  **waits in the queue** (up to 24 hours) and starts when the runner comes
  back — cancel it in the Actions tab if you no longer want it.

These live in `tests/shared/claude-usage.bats` and `tests/lib/helpers.bash`.
