# When Claude is used

Claude is only used when a ticket or a person asks for it. Tests, git hooks
and CI never use it. This page explains how usage happens, what triggers it,
and how the evals fit in.

## How usage happens

- **The runner** is the machine that runs the agent hub pipeline's jobs — by
  default a self-hosted runner (see [runners.md](runners.md)).
- **Claude Code** is installed on the runner and signed in to a Claude account
  (a subscription login, or an API key).
- **One step per stage uses Claude** — *Agent (draft and review)*. The
  document stages (work order, plan) run it in two passes: a **draft**, then
  an **expert review** that checks and improves it (see
  [architecture.md](architecture.md#expert-review-every-stage)); both read the
  repository and research. The build (a development preview) runs **one
  pass** that edits the checkout and runs the repository's checks in the
  sandbox; its review pass comes later. That step is the only point where
  Claude is used — it counts against the account's plan limits
  (subscription) or is billed (API), like any other Claude Code session.
- **Everything else is plain scripts**: fetching the ticket, writing results
  to the ticket, committing, pushing and opening the pull request, posting and
  resolving comments. None of it uses Claude.

## What triggers it

| Trigger | Uses Claude? |
|---|---|
| A tracker rule sends a ticket to a stage (Work Order, Work Order Approved, Implementation Plan Approved) | **Yes** — one run per request. A build starts only where the preview is enabled, with the pinned Claude Code version; otherwise it stops before any Claude usage |
| A `/revise` comment on a ticket in Intake, Work Order, Work Order Approved or Implementation Plan (Revision Requested rule) | **Yes** — one run per comment. A revision is scoped to the requested changes, so it's usually well under a new run's cost; a retry or resubmission costs a normal run |
| **Run workflow** on an agent workflow in the Actions tab | **Yes** |
| Running the evals — **Agent hub: Evals** in the Actions tab, or `npm run evals --prefix .github/agent-hub/tests -- <stage>`, confirmed by typing `use-claude` | **Yes**, deliberately |
| Checking the sandbox (`.github/agent-hub/scripts/check-sandbox.sh`, on a new runner and after Claude Code upgrades; confirmed by typing `use-claude`) | **Yes**, deliberately — two short sessions |
| Committing (the pre-commit lint hooks) | No |
| Opening or updating a pull request, or pushing to `main` (CI) | No |
| Running the tests (`npm test --prefix .github/agent-hub/tests`) | No |

Each run's summary (in the Actions run page) shows the models used, the
Claude Code version, and the turns and **API-equivalent cost** of each pass —
the draft and the expert review — so you can see which one costs what. Each
pass has a cap, set per stage: `AGENT_HUB_<STAGE>_MAX_BUDGET_USD` for the
draft, `AGENT_HUB_<STAGE>_REVIEW_MAX_BUDGET_USD` for the review, and a lower
`AGENT_HUB_<STAGE>_REVISION_MAX_BUDGET_USD` for both passes of a revision,
which is scoped to the requested changes; the build's single pass is capped
by `AGENT_HUB_BUILD_MAX_BUDGET_USD`
([setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)).
These are API-equivalent caps per pass, not a billing ledger: nothing limits
the total across repeated requests or re-runs of a ticket yet (per-ticket caps
are planned for the build).

**When a pass reaches its cap**, Claude Code stops it and the run fails with
the reason on the ticket ("Claude reached its budget cap before finishing").
Nothing from that run is applied — no work order, plan or build half-written
— and nothing already on the ticket or in the repository is lost: the
existing work order, the attached plan and the approval all stay as they
were. The partial work isn't kept (sessions aren't saved, so no run can read
another's), so a retry starts the pass again:

| Stage | Retry | Starts from |
|---|---|---|
| Work order | Comment `/revise` (or re-run the workflow) | The ticket; a revision, if a work order is already there |
| Implementation plan | Comment `/revise` (or re-run the workflow) | The work order; a revision of the attached plan, if one is there |
| A revision (either) | Comment `/revise` again | The current work order or attached plan |
| Build | Move the ticket back to Implementation Plan and approve it again, or re-run **Agent hub: Build** | The approved plan, from scratch (nothing was pushed) |

If a stage keeps reaching its cap, raise that pass's variable (above) before
retrying. The review pass has its own cap: if it's reached, the draft isn't
applied either — nothing unreviewed reaches the ticket.

**Typical usage** (API-equivalent; the single source for these figures — other
docs link here):

| | Typical | Notes |
|---|---|---|
| One work order (draft + review) | $0.30–1.50 | Clear requests cost more (research); a ticket sent back for details costs only its draft (no review), well under $0.50 |
| One implementation plan (draft + review) | $1.50–7 | Several minutes; scales with the change. Opus costs more than Sonnet |
| One build (one pass) | Not measured yet — capped at $10 | To confirm in the pipeline test ([build.md](workflows/build.md#cost-estimates-to-confirm-in-the-pipeline-test)); scales with the change and the repository's checks |
| One eval case | As one real run of its stage | Each case runs the draft and the review |
| Work order evals (3 cases) | $1–3 | A few minutes |
| Implementation plan evals (3 cases) | $3–10 | 20–40 minutes |
| The sandbox check | About $0.20 | Two short sessions, each capped (under $1 together) |
| Every stage (**all**) | The sum; up to $4–13, over the $10 default cap: raise it for that run | Only after a model or Claude Code change |

## Tests vs evals

**Tests** check the plumbing with a stand-in `claude` that replays recorded
answers, so they never reach Claude. **Evals** check the decisions with the
real Claude, only when started by hand, for the stages you name. When
they're worth running, their guards, and the PR notice that suggests them:
**[evals.md](evals.md)**.

## Safeguards

- A test step **refuses to run** if `claude` would resolve to the real Claude
  Code rather than the stand-in, so a test can never reach a real login —
  even with `REAL_CLAUDE` or `RUN_EVALS` exported in the shell (only an eval
  run the eval runner started can use the real CLI).
- The evals **skip themselves** unless `RUN_EVALS=1` is set, which only the
  eval runner sets, after a stage is named and `use-claude` is typed — see
  [evals.md](evals.md) for all their guards. They run one case at a time, and
  stop once the run's cap is reached or a case's cost can't be read. Set
  `EVALS_CONFIRM=use-claude` only for the one command, never in a shell
  profile or a runner's environment: that would remove the per-run check.
- The kill switch (`AGENT_HUB_ENABLED=false`) stops runs **before they start**;
  a run already going finishes — cancel it in the Actions tab to stop it now.
- A test checks that **every workflow that uses Claude** only runs on tracker
  requests (`repository_dispatch`) or manual runs (`workflow_dispatch`) —
  never on pushes, pull requests or schedules.
- Runs from GitHub (agent stages and evals) only use the runner in
  `AGENT_HUB_RUNS_ON`; with it offline nothing runs, but a run started meanwhile
  **waits in the queue** (up to 24 hours) and starts when the runner comes
  back — cancel it in the Actions tab if you no longer want it.

These live in `tests/shared/claude-usage.bats` and `tests/lib/helpers.bash`.
