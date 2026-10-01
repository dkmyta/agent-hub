# Setting up the agent workflows in a repository

How to add the agent workflows to a GitHub repository and connect them to a
tracker — Jira, or GitHub Projects ([choosing one](trackers.md)). Nothing in the workflow files needs editing: each repository
supplies its own **runner**, **secrets**, optional **variables**, and **Jira
rule**.

## 1. Add the files

Copy these into the repository:

| Path | What it is |
|---|---|
| `.github/workflows/agent-*.yml` | The agent workflows and the evals workflow |
| `.github/workflows/tests.yml` | CI: lint and tests on every pull request |
| `.github/agents/` | Prompts, output schemas, ticket layouts, shared Jira/ADF code |
| `.github/scripts/` | CI helper scripts |
| `.github/actionlint.yaml`, `.pre-commit-config.yaml`, `.editorconfig` | Lint config |
| `tests/` | The test suite and evals |
| `docs/`, `CONTRIBUTING.md`, `.github/pull_request_template.md` | Docs and conventions |

## 2. Set up a runner

The agent workflows run where Claude Code can run. By default that's a
**self-hosted runner labelled `claude`**, with Claude Code logged in to a
Claude account. Follow [runners.md](runners.md) to set one up, or to use the
Claude API on GitHub-hosted runners instead.

## 3. Add secrets

Settings → Secrets and variables → Actions → **Secrets**:

| Secret | Required | Value |
|---|---|---|
| `JIRA_DOMAIN` | Yes | Your Jira site, e.g. `your-team.atlassian.net` |
| `JIRA_EMAIL` | Yes | The Jira account the automation acts as — ideally a dedicated service account |
| `JIRA_API_TOKEN` | Yes | An [API token](https://id.atlassian.com/manage-profile/security/api-tokens) for that account |
| `ANTHROPIC_API_KEY` | Only for the Claude API | See [runners.md](runners.md#using-the-claude-api) |

## 4. Set variables (only what differs from the defaults)

Settings → Secrets and variables → Actions → **Variables**. Leave any unset to
use its default.

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_RUNS_ON` | `["self-hosted", "claude"]` | Runner labels, as JSON. `["ubuntu-latest"]` for GitHub-hosted runners |
| `AGENT_EVALS_MAX_COST_USD` | `10` | Total spend cap for one Agent Evals run; remaining cases are skipped once reached |
| `CLAUDE_CODE_VERSION` | `latest` | Claude Code version installed on GitHub-hosted runners |
| `CLAUDE_MODEL` | `claude-sonnet-5` | Model for the agents |
| `CLAUDE_FALLBACK_MODEL` | `claude-opus-5-5` | Used when the model is overloaded |
| `CLAUDE_MAX_BUDGET_USD` | `2.00` | Per-run cap, in API-equivalent dollars |
| `CLAUDE_FETCH_DOMAINS` | GitHub, Atlassian, Anthropic, MDN, Node and npm docs | Space-separated sites Claude may fetch pages from |
| `JIRA_WORK_ORDER_STATUS` | `Work Order` | Status a ticket is in while its work order is prepared |
| `JIRA_INTAKE_STATUS` | `Intake` | Status for new tickets and tickets that need more detail |
| `JIRA_NEEDS_DETAILS_LABEL` | `needs-details` | Label for tickets sent back for more detail |
| `JIRA_WORK_ORDER_APPROVED_STATUS` | `Work Order Approved` | Status that requests an implementation plan |
| `JIRA_IMPLEMENTATION_PLAN_STATUS` | `Implementation Plan` | Status of tickets with a plan waiting for approval |
| `JIRA_NEEDS_HUMAN_LABEL` | `needs-human` | Label for tickets waiting for a person |
| `JIRA_NEEDS_CLARIFICATION_LABEL` | `needs-clarification` | Label for tickets the plan stage sent back with questions |
| `JIRA_REVISE_COMMAND` | `/revise` | Comments starting with this word ask an agent to revise (or retry); must match the Revision Requested rule |
| `REVIEW_CLAUDE_MODEL` | `claude-opus-5-5` | Model for the expert review of every draft (needs Claude Code 2.1.280+) |
| `REVIEW_CLAUDE_FALLBACK_MODEL` | `claude-sonnet-5` | Used when the review model is overloaded or unsupported |
| `REVIEW_CLAUDE_MAX_BUDGET_USD` | `2.00` / `5.00` | Per-review cap (work orders / plans), API-equivalent dollars |
| `PLAN_CLAUDE_MODEL` | `claude-opus-5-5` | Model for implementation plans (needs Claude Code 2.1.280+) |
| `PLAN_CLAUDE_FALLBACK_MODEL` | `claude-sonnet-5` | Used when the plan model is overloaded or unsupported |
| `PLAN_CLAUDE_MAX_BUDGET_USD` | `5.00` | Per-plan cap, in API-equivalent dollars |
| `REVISION_MAX_BUDGET_USD` | `1.00` | Per-pass cap for work-order revisions (draft and review each) |
| `PLAN_REVISION_MAX_BUDGET_USD` | `2.00` | Per-pass cap for plan revisions (draft and review each) |
| `JIRA_NOTIFY_USERS` | `true` | `false` silences watcher notifications for description updates (needs Jira admin) |

## 5. Set up your tracker

Pick one per repository — see [trackers.md](trackers.md). The stages work the
same way with either.

**GitHub Projects:** follow **[github-projects.md](github-projects.md)** and
its checklist (the board, views, labels, intake template and access) — the
foundations only: its agent stages aren't connected yet, so for the full
pipeline today, use Jira.

**Jira:** follow **[jira.md](jira.md)** — the single reference for the Jira side — and
tick off its [installation checklist](jira.md#checklist-for-a-new-installation):
the Task work type and intake template, statuses and transitions,
permissions for the `JIRA_EMAIL` account, and the three automation rules
(Work Order Requested, Implementation Plan Requested, Revision Requested),
each with its web request pointing at **your** repository.

Those web requests need **a GitHub token for Jira**: a fine-grained token for
**this repository only**, with **Contents: Read and write** (what
`repository_dispatch` requires), ideally owned by a machine user — see
[step 6](#6-plan-for-credential-expiry).

## 6. Plan for credential expiry

Two credentials expire, and when they do the workflows stop — quietly, from
Jira's side:

| Credential | Lives in | Expires | When it expires | To renew |
|---|---|---|---|---|
| Jira API token | `JIRA_API_TOKEN` secret | On the date set when it was created | Every run fails, and the failure comment can't be posted either (it uses the same token): tickets sit in Work Order | Create a new token for the same Jira account and update the secret |
| GitHub token | The Jira rule's `Authorization` header | On the date set when it was created | Jira's web request fails, so no run starts | Create a new token with the same access and paste it into the rule |
| Claude login | The runner machine | Occasionally | Runs fail with the failure comment | Run `claude` on the runner and log in |
| `ANTHROPIC_API_KEY` | Secret (API setup only) | When revoked | Runs fail with the failure comment | Create a new key and update the secret |

**Own them with accounts that aren't a person's**, so they don't break when
someone leaves or changes role:
- **Jira**: a dedicated service account for `JIRA_EMAIL` / `JIRA_API_TOKEN`.
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

## 7. Check it

1. **Actions → Agent — Work Order → Run workflow** with the key of a test
   ticket in the Work Order status. The ticket should get a work order.
2. Create a ticket through Jira and confirm the rule triggers a run.
3. Optionally, **Actions → Agent Evals → Run workflow** to check the agent's
   decisions in this repository (uses Claude; type `use-claude` to confirm).
   Recommended: add required reviewers to the `agent-evals` environment so
   every eval run needs approval ([evals.md](evals.md#how-to-run-them)).

## 8. Local development (contributors)

See [CONTRIBUTING.md](../CONTRIBUTING.md): `npm ci --prefix tests --ignore-scripts` and
`pre-commit install`. The tests and hooks never use Claude or Jira.

## Several repositories

Each repository that has the workflows is independent: its own runner (or
shared runners at the organisation level with the `claude` label), secrets,
variables and Jira rule. One Jira project can serve several repositories with
one rule per repository, each pointing its web request at its repository.
