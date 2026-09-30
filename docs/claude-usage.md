# When Claude is used

Claude is only used when a ticket or a person asks for it. Tests, git hooks
and CI never use it. This page explains how usage happens, what triggers it,
and how the evals fit in.

## How usage happens

- **The runner** is the machine that runs the agent workflows' jobs — by
  default a self-hosted runner (see [runners.md](runners.md)).
- **Claude Code** is installed on the runner and signed in to a Claude account
  (a subscription login, or an API key).
- **One step per agent workflow calls Claude.** In Agent — Work Order that's
  *Generate work order*: it runs `claude` with the ticket and the agent's
  instructions, and Claude reads the repository, researches, and returns its
  answer. That's the only point where Claude is used — it counts against the
  account's plan limits (subscription) or is billed (API), like any other
  Claude Code session.
- **Everything else is plain scripts**: fetching the ticket, writing the work
  order to Jira, posting and resolving comments. None of it uses Claude.

## What triggers it

| Trigger | Uses Claude? |
|---|---|
| A Jira rule sends a ticket to a stage (e.g. Work Order) | **Yes** — one run per request |
| **Run workflow** on an agent workflow in the Actions tab | **Yes** |
| Running the evals — **Agent Evals** in the Actions tab, or `npm run evals --prefix tests` | **Yes**, deliberately |
| Committing or pushing (pre-commit / pre-push hooks) | No |
| Opening or updating a pull request, or pushing to `main` (CI) | No |
| Running the tests (`npm test --prefix tests`) | No |

Each run's summary (in the Actions run page) shows the models used, the
Claude Code version, turns and **API-equivalent cost**. `CLAUDE_MAX_BUDGET_USD`
caps a single run.

**Typical usage** (API-equivalent; the single source for these figures — other
docs link here):

| | Typical | Notes |
|---|---|---|
| One work order | $0.10–0.80 | Clear requests cost more (research); bounced tickets $0.10 or less |
| One eval case | $0.10–0.70 | |
| A full eval run (5 cases) | $1.00–1.50 | A few minutes |

## Tests vs evals

- **Tests** check the *plumbing*: given an answer from Claude, does the
  workflow update the ticket correctly? They use a stand-in `claude` that
  replays recorded answers, so they never reach Claude.
- **Evals** check the *decisions*: they give the real Claude sample tickets
  (a clear request, a plain-prose request, an all-"TBD" ticket, a vague one,
  and one that tries to trick Claude) and check it responds correctly. See
  [tests/README.md](../tests/README.md#live-evals).

**When to run the evals:** after changing a prompt, an output schema, or a
Claude setting (model, fallback, budget, fetch domains, allowed tools), and
after upgrading Claude Code on the runner. They only run when started by hand.
Why they matter, when to run them and how to read the results:
**[evals.md](evals.md)**.

## The eval reminder

When a pull request changes a prompt, schema or Claude setting, CI adds a
**"Run Agent Evals before merging"** warning to the pull request, listing
what changed (`.github/scripts/agent-behaviour-changes.sh`). It's a reminder
only — it doesn't run the evals or block merging.

## Safeguards

- A test step **refuses to run** if `claude` would resolve to the real Claude
  Code rather than the stand-in, so a test can never reach a real login.
- The evals **skip themselves** unless `RUN_EVALS=1` is set, which only
  `npm run evals` and the Agent Evals workflow do — a stray `bats -r tests`
  won't run them.
- A test checks that **every workflow that uses Claude** only runs on Jira
  requests (`repository_dispatch`) or manual runs (`workflow_dispatch`) —
  never on pushes, pull requests or schedules.

These live in `tests/shared/claude-usage.bats` and `tests/lib/helpers.bash`.
