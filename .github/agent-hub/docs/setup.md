# Setting up the agent hub in a repository

How to add the agent hub to a GitHub repository and connect it to a
tracker — Jira, or GitHub Projects ([choosing one](trackers.md)). Nothing in
the hub needs editing: each repository supplies its own **runner**,
**secrets**, optional **variables**, and the **tracker's rules**.

## 1. Add the files

Copy these into the repository, unchanged:

| Path | What it is |
|---|---|
| `.github/agent-hub/` | The hub: stages, tracker and runner code, settings, tests, evals, docs, lint config |
| `.github/workflows/agent-hub-*.yml` | The stage workflows, the shared stage workflow, CI (lint and tests, only when the hub changes) and the evals workflow |
| `.github/ISSUE_TEMPLATE/agent-hub-request.yml` | **GitHub Projects only**: the intake form ([github-projects.md](github-projects.md#intake-form)) |

The repository's own issue and pull request templates stay as they are: the
hub's are used only for the pipeline's own issues and pull requests
([architecture.md](architecture.md#templates-only-for-the-pipelines-own-issues-and-pull-requests)).

## 2. Set up a runner

The agent hub pipeline runs where Claude Code can run. By default that's a
**self-hosted runner labelled `claude`**, with Claude Code logged in to a
Claude account. Follow [runners.md](runners.md) to set one up, or to use the
Claude API on GitHub-hosted runners instead.

## 3. Add secrets

Settings → Secrets and variables → Actions → **Secrets**. The tracker's secrets
are for Jira (GitHub Projects will use the workflow's own GitHub token):

| Secret | Required | Value |
|---|---|---|
| `AGENT_HUB_JIRA_DOMAIN` | Yes | Your Jira site, e.g. `your-team.atlassian.net` |
| `AGENT_HUB_JIRA_EMAIL` | Yes | The Jira account the automation acts as — ideally a dedicated service account |
| `AGENT_HUB_JIRA_API_TOKEN` | Yes | An [API token](https://id.atlassian.com/manage-profile/security/api-tokens) for that account |
| `AGENT_HUB_ANTHROPIC_API_KEY` | Only for the Claude API | See [runners.md](runners.md#using-the-claude-api) |

## 4. Set variables (only what differs from the defaults)

Settings → Secrets and variables → Actions → **Variables**. Leave any unset to
use its default. (The defaults are in `lib/settings.sh` and each stage's
`settings.sh`.)

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_HUB_TRACKER` | `jira` | Where tickets live (`trackers/<name>/`). Only `jira` exists so far |
| `AGENT_HUB_RUNNER` | `claude-code` | What runs the agents (`lib/runners/<name>.sh`). Only `claude-code` exists so far |
| `AGENT_HUB_RUNS_ON` | `["self-hosted", "claude"]` | Runner labels, as JSON. `["ubuntu-latest"]` for GitHub-hosted runners |
| `AGENT_HUB_EVALS_MAX_COST_USD` | `10` | Total spend cap for one Agent hub: Evals run; remaining cases are skipped once reached |
| `AGENT_HUB_CLAUDE_CODE_VERSION` | `latest` | Claude Code version installed on GitHub-hosted runners |
| `AGENT_HUB_CLAUDE_MODEL` | `claude-sonnet-5` | Model for the agents |
| `AGENT_HUB_CLAUDE_FALLBACK_MODEL` | `claude-opus-5-5` | Used when the model is overloaded |
| `AGENT_HUB_CLAUDE_MAX_BUDGET_USD` | `2.00` | Per-run cap, in API-equivalent dollars |
| `AGENT_HUB_CLAUDE_FETCH_DOMAINS` | GitHub, Atlassian, Anthropic, MDN, Node and npm docs | Space-separated sites Claude may fetch pages from |
| `AGENT_HUB_WORK_ORDER_STATUS` | `Work Order` | Status a ticket is in while its work order is prepared |
| `AGENT_HUB_INTAKE_STATUS` | `Intake` | Status for new tickets and tickets that need more detail |
| `AGENT_HUB_NEEDS_DETAILS_LABEL` | `needs-details` | Label for tickets sent back for more detail |
| `AGENT_HUB_WORK_ORDER_APPROVED_STATUS` | `Work Order Approved` | Status that requests an implementation plan |
| `AGENT_HUB_IMPLEMENTATION_PLAN_STATUS` | `Implementation Plan` | Status of tickets with a plan waiting for approval |
| `AGENT_HUB_NEEDS_HUMAN_LABEL` | `needs-human` | Label for tickets waiting for a person |
| `AGENT_HUB_NEEDS_CLARIFICATION_LABEL` | `needs-clarification` | Label for tickets the plan stage sent back with questions |
| `AGENT_HUB_REVISE_COMMAND` | `/revise` | Comments starting with this word ask an agent to revise (or retry); must match the Revision Requested rule |
| `AGENT_HUB_REVIEW_CLAUDE_MODEL` | `claude-opus-5-5` | Model for the expert review of every draft (needs Claude Code 2.1.280+) |
| `AGENT_HUB_REVIEW_CLAUDE_FALLBACK_MODEL` | `claude-sonnet-5` | Used when the review model is overloaded or unsupported |
| `AGENT_HUB_REVIEW_CLAUDE_MAX_BUDGET_USD` | `2.00` / `5.00` | Per-review cap (work orders / plans), API-equivalent dollars |
| `AGENT_HUB_PLAN_CLAUDE_MODEL` | `claude-opus-5-5` | Model for implementation plans (needs Claude Code 2.1.280+) |
| `AGENT_HUB_PLAN_CLAUDE_FALLBACK_MODEL` | `claude-sonnet-5` | Used when the plan model is overloaded or unsupported |
| `AGENT_HUB_PLAN_CLAUDE_MAX_BUDGET_USD` | `5.00` | Per-plan cap, in API-equivalent dollars |
| `AGENT_HUB_REVISION_MAX_BUDGET_USD` | `1.00` | Per-pass cap for work-order revisions (draft and review each) |
| `AGENT_HUB_PLAN_REVISION_MAX_BUDGET_USD` | `2.00` | Per-pass cap for plan revisions (draft and review each) |
| `AGENT_HUB_JIRA_NOTIFY_USERS` | `true` | `false` silences watcher notifications for description updates (needs Jira admin) |

## 5. Set up your tracker

Pick one per repository — see [trackers.md](trackers.md). The stages work the
same way with either.

**GitHub Projects:** follow **[github-projects.md](github-projects.md)** and
its checklist (the board, views, labels, intake form and access) — the
foundations only: its agent stages aren't connected yet, so for the full
pipeline today, use Jira.

**Jira:** follow **[jira.md](jira.md)** — the single reference for the Jira side — and
tick off its [installation checklist](jira.md#checklist-for-a-new-installation):
the Task work type and intake template, statuses and transitions,
permissions for the `AGENT_HUB_JIRA_EMAIL` account, and the three automation rules
(Work Order Requested, Implementation Plan Requested, Revision Requested),
each with its web request pointing at **your** repository.

Those web requests need **a GitHub token for Jira**: a fine-grained token for
**this repository only**, with **Contents: Read and write** (what
`repository_dispatch` requires), ideally owned by a machine user — see
[step 6](#6-plan-for-credential-expiry).

## 6. Plan for credential expiry

Two credentials expire, and when they do the workflows stop — quietly, from
the tracker's side (the Jira setup shown):

| Credential | Lives in | Expires | When it expires | To renew |
|---|---|---|---|---|
| Jira API token | `AGENT_HUB_JIRA_API_TOKEN` secret | On the date set when it was created | Every run fails, and the failure comment can't be posted either (it uses the same token): tickets sit in Work Order | Create a new token for the same Jira account and update the secret |
| GitHub token | The Jira rule's `Authorization` header | On the date set when it was created | Jira's web request fails, so no run starts | Create a new token with the same access and paste it into the rule |
| Claude login | The runner machine | Occasionally | Runs fail with the failure comment | Run `claude` on the runner and log in |
| `AGENT_HUB_ANTHROPIC_API_KEY` | Secret (API setup only) | When revoked | Runs fail with the failure comment | Create a new key and update the secret |

**Own them with accounts that aren't a person's**, so they don't break when
someone leaves or changes role:
- **Jira**: a dedicated service account for `AGENT_HUB_JIRA_EMAIL` / `AGENT_HUB_JIRA_API_TOKEN`.
- **GitHub**: a machine user (a GitHub account for automation) that owns the
  fine-grained token in the Jira rule, limited to the repository with
  **Contents: Read and write**. (A GitHub App can't be used here: its tokens
  must be minted by signing a JWT, which Jira automation can't do.)

**Know when something fails:**
- **Jira**: the rule's *Notify on error* setting emails the rule owner when the
  web request fails — keep it on.
- **GitHub**: failed runs notify the account that triggered them — for Jira
  requests, the owner of the GitHub token. Make sure that account's
  notifications for failed workflow runs (Settings → Notifications → Actions)
  go somewhere someone reads.
- **Put the expiry dates in a calendar** with a reminder a few weeks ahead.

## 7. Optionally, extend the stages for your codebase

Give the agents your repository's conventions, review checks and expert
agents per stage, in `.github/agent-hub-extensions/` — see
[extending.md](extending.md). Start without, and add what real tickets show
is missing.

## 8. Check it

1. **Actions → Agent hub: Work order → Run workflow** with the key of a test
   ticket in the Work Order status. The ticket should get a work order.
2. Create a ticket through the tracker and confirm its rule triggers a run.
3. Optionally, **Actions → Agent hub: Evals → Run workflow** to check the agent's
   decisions in this repository (uses Claude; type `use-claude` to confirm).
   Recommended: add required reviewers to the `agent-hub-evals` environment so
   every eval run needs approval ([evals.md](evals.md#how-to-run-them)).

## 9. Local development (contributors)

See [CONTRIBUTING.md](../CONTRIBUTING.md): `npm ci --prefix .github/agent-hub/tests --ignore-scripts`
and `pre-commit install --config .github/agent-hub/.pre-commit-config.yaml`.
The tests and hooks never use Claude or a tracker.

## Several repositories

Each repository that has the workflows is independent: its own runner (or
shared runners at the organisation level with the `claude` label), secrets,
variables and tracker rules. One Jira project can serve several repositories with
one rule per repository, each pointing its web request at its repository.
