# Setting up the agent workflows in a repository

How to add the agent workflows to a GitHub repository and connect them to a
Jira project. Nothing in the workflow files needs editing: each repository
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
| `CLAUDE_CODE_VERSION` | `latest` | Claude Code version installed on GitHub-hosted runners |
| `CLAUDE_MODEL` | `claude-sonnet-5` | Model for the agents |
| `CLAUDE_FALLBACK_MODEL` | `claude-opus-5-5` | Used when the model is overloaded |
| `CLAUDE_MAX_BUDGET_USD` | `2.00` | Per-run cap, in API-equivalent dollars |
| `CLAUDE_FETCH_DOMAINS` | GitHub, Atlassian, Anthropic, MDN, Node and npm docs | Space-separated sites Claude may fetch pages from |
| `JIRA_WORK_ORDER_STATUS` | `Work Order` | Status a ticket is in while its work order is prepared |
| `JIRA_INTAKE_STATUS` | `Intake` | Status for new tickets and tickets that need more detail |
| `JIRA_NEEDS_DETAILS_LABEL` | `needs-details` | Label for tickets sent back for more detail |
| `JIRA_NOTIFY_USERS` | `true` | `false` silences watcher notifications for description updates (needs Jira admin) |

## 5. Set up Jira

1. **Statuses and transitions**: the project's workflow needs the two statuses
   above, a transition from Intake to Work Order, and one back.
2. **Permissions** for the `JIRA_EMAIL` account: Browse Projects, Edit Issues,
   Transition Issues, Add Comments, Delete Own Comments, Edit All Comments.
3. **A GitHub token for Jira**: a fine-grained personal access token, ideally
   owned by a machine user (see [step 6](#6-plan-for-credential-expiry)), for
   **this repository only**, with **Contents: Read and
   write** — that's what `repository_dispatch` requires.
4. **The automation rule**: build "Work Order Requested" as described in
   [workflows/work-order.md](workflows/work-order.md#jira-setup), with the web
   request pointing at **your** repository:
   `https://api.github.com/repos/<owner>/<repo>/dispatches`. Put the token in
   the `Authorization: Bearer <token>` header and mark the header as hidden.
5. **The intake template**: the ticket type's description template should
   contain only the intake fields the requester fills in.

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
   decisions in this repository (uses Claude).

## 8. Local development (contributors)

See [CONTRIBUTING.md](../CONTRIBUTING.md): `npm ci --prefix tests --ignore-scripts` and
`pre-commit install`. The tests and hooks never use Claude or Jira.

## Several repositories

Each repository that has the workflows is independent: its own runner (or
shared runners at the organisation level with the `claude` label), secrets,
variables and Jira rule. One Jira project can serve several repositories with
one rule per repository, each pointing its web request at its repository.
