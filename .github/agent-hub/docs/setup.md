# Setting up the agent hub in a repository

How to add the agent hub to a GitHub repository and connect it to a
tracker — Jira, or GitHub Projects ([choosing one](trackers.md)). Nothing in
the hub needs editing: each repository supplies its own **runner**,
**secrets**, optional **variables**, and the **tracker's rules**.

## 1. Add the files

Install the hub with its script — see
[updating.md](updating.md#installing) (one clone and one command). It adds
these, which you don't edit (changes go in extensions, or to the hub itself):

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
Claude API on GitHub-hosted runners instead. Then run the sandbox check on it
([runners.md](runners.md#checking-the-sandbox)) — needed before the build
stage, which runs commands; on a personal machine, read
[Before running the build on real tickets](runners.md#before-running-the-build-on-real-tickets)
too.

## 3. Add secrets

**In the `agent-hub` environment, limited to your default branch** (since
2.20.0): Settings → Environments → **New environment** `agent-hub` (or open
it, if a run already created it) → Deployment branches and tags → **Selected
branches and tags** → add your default branch (e.g. `main`) → then add the
secrets below under its **Environment secrets**. Every stage's job uses this
environment, so a run someone with write access starts on another branch —
whose copy of the hub's scripts could do anything with a secret — is refused
before it gets one. Secrets at the repository level (Settings → Secrets and
variables → Actions) still work, but any branch's run can read them: move
them into the environment, and delete the repository-level copies. The
evals' `agent-hub-evals` environment needs its own copy of
`AGENT_HUB_ANTHROPIC_API_KEY` if you use the evals with the API. (Runs appear
under the repository's **Deployments**: that's the environment, not a
deployment.) It protects GitHub's secrets, not what's on a self-hosted
runner: a Claude login there is reachable by everyone with write access
([runners.md](runners.md#self-hosted-runner-with-a-claude-subscription)).

The tracker's secrets are for Jira (GitHub Projects will use the workflow's
own GitHub token):

| Secret | Required | Value |
|---|---|---|
| `AGENT_HUB_JIRA_DOMAIN` | Yes | Your Jira site, e.g. `your-team.atlassian.net` |
| `AGENT_HUB_JIRA_EMAIL` | Yes | The Jira account the automation acts as — a dedicated service account ([adding it](jira.md#adding-the-service-account)), barred from approving ([how](jira.md#restrict-approvals-to-people)) |
| `AGENT_HUB_JIRA_API_TOKEN` | Yes | An [API token](https://id.atlassian.com/manage-profile/security/api-tokens) for that account |
| `AGENT_HUB_ANTHROPIC_API_KEY` | Only for the Claude API | See [runners.md](runners.md#using-the-claude-api) |
| `AGENT_HUB_GITHUB_TOKEN` | For the build stage | The **build token**, named `agent-hub-build-<repo>` in GitHub (not the Jira rules' dispatch token — [the two GitHub tokens](#the-two-github-tokens)): a **machine user's** fine-grained token for this repository only, with Contents and Pull requests read/write — no Workflows, no Administration. The build pushes and opens pull requests with it (a workflow's own token wouldn't start your CI), and commits as its account, with that account's GitHub noreply address; branch protection keeps that user from merging. Only the build's fetch and apply steps get it — never an agent step, nor any step that runs the repository's code. **For development**, your own fine-grained token (same scope) works: the build's commits and pull requests are then yours, and branch protection can't stop you merging them — use a machine user before the build runs real tickets |

## 4. Set variables (only what differs from the defaults)

Settings → Secrets and variables → Actions → **Variables**. Leave any unset to
use its default. (The defaults are in `lib/settings.sh` and each stage's
`settings.sh`.)

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_HUB_ENABLED` | `true` | The kill switch: `false` stops every hub workflow (stages and evals) before it reaches a runner — e.g. while investigating a problem. A run already going finishes (cancel it in the Actions tab). Only admins can change repository variables |
| `AGENT_HUB_TRACKER` | `jira` | Where tickets live (`trackers/<name>/`). Only `jira` exists so far |
| `AGENT_HUB_RUNNER` | `claude-code` | What runs the agents (`lib/runners/<name>.sh`). Only `claude-code` exists so far |
| `AGENT_HUB_RUNS_ON` | `["self-hosted", "claude"]` | Runner labels, as JSON. `["ubuntu-latest"]` for GitHub-hosted runners |
| `AGENT_HUB_EVALS_MAX_COST_USD` | `10` | Total spend cap for one Agent hub: Evals run; remaining cases are skipped once reached |
| `AGENT_HUB_CLAUDE_CODE_VERSION` | `latest` | Claude Code version installed on GitHub-hosted runners. **The build requires an exact version** (e.g. `2.1.280`) matching the runner's `claude --version` ([runners.md](runners.md#claude-code-version)) |
| `AGENT_HUB_CLAUDE_FETCH_DOMAINS` | GitHub, Atlassian, Anthropic, MDN, Node and npm docs | Space-separated sites Claude may fetch pages from |
| `AGENT_HUB_WORK_ORDER_STATUS` | `Work Order` | Status a ticket is in while its work order is prepared |
| `AGENT_HUB_INTAKE_STATUS` | `Intake` | Status for new tickets and tickets that need more detail |
| `AGENT_HUB_NEEDS_DETAILS_LABEL` | `needs-details` | Label for tickets sent back for more detail |
| `AGENT_HUB_WORK_ORDER_APPROVED_STATUS` | `Work Order Approved` | Status that requests an implementation plan |
| `AGENT_HUB_IMPLEMENTATION_PLAN_STATUS` | `Implementation Plan` | Status of tickets with a plan waiting for approval |
| `AGENT_HUB_IMPLEMENTATION_PLAN_APPROVED_STATUS` | `Implementation Plan Approved` | Status that requests a build |
| `AGENT_HUB_READY_FOR_REVIEW_STATUS` | `Ready for Review` | Status the build moves a ticket to when its pull request is handed off |
| `AGENT_HUB_APPROVED_STATUS` | `Approved` | Optional status a person moves a ticket to after approving its pull request; a merge moves it to Done from there too |
| `AGENT_HUB_DONE_STATUS` | `Done` | Status the build moves a ticket to when the pull request it handed off is merged |
| `AGENT_HUB_APPROVERS_GROUP` | *(none)* | The tracker group of the people who approve. Set, the hub checks it itself (since 2.18.0): a work order or plan approved by someone outside it isn't an approval, and only its members can act on a build's items with `/skip` and `/apply` on the ticket. Unset: approvals rest on the tracker's own workflow conditions, and every item command is refused. Optional while trying the document stages; **required before the build runs real tickets** (the [production checklist](workflows/build-design.md#production-checklist)). The Jira service account needs Browse users and groups to check it ([jira.md](jira.md#rule-build-command)) |
| `AGENT_HUB_PUBLISH_TICKET_CONTENT` | `false` | `true` lets the build put ticket text (the title, criteria, Claude's summary and decision log) in a **public** repository's pull requests and commits; private repositories always get it ([build.md](workflows/build.md#publication-policy)) |
| `AGENT_HUB_NEEDS_HUMAN_LABEL` | `needs-human` | Label for tickets waiting for a person |
| `AGENT_HUB_NEEDS_CLARIFICATION_LABEL` | `needs-clarification` | Label for tickets the plan stage sent back with questions |
| `AGENT_HUB_TICKET_MAX_RUNS` | `10` | Runs that used Claude, per ticket across every stage, before a person must lift the cap ([claude-usage.md](claude-usage.md#per-ticket-caps)) |
| `AGENT_HUB_TICKET_MAX_COST_USD` | `60.00` | API-equivalent dollars per ticket across every stage, likewise |
| `AGENT_HUB_PASS_OVERSHOOT_USD` | `1.00` | Dollars allowed per Claude pass on top of its budget, since a pass stops only after the turn that crosses it: added when a run is admitted against the cap, and to the estimate for a pass that had no report ([claude-usage.md](claude-usage.md#per-ticket-caps)) |
| `AGENT_HUB_OVER_CAP_LABEL` | `agent-hub-over-cap` | Label on a ticket at its caps; removing it lifts them |
| `AGENT_HUB_REVISE_COMMAND` | `/revise` | Comments starting with this word ask an agent to revise (or retry); must match the Revision Requested rule |
| `AGENT_HUB_REVIEW_MODEL` | `claude-opus-5-5` | Model for the expert review of every draft (needs Claude Code 2.1.280+) |
| `AGENT_HUB_REVIEW_FALLBACK_MODEL` | `claude-sonnet-5-5` | Used when the review model is overloaded or unsupported |
| `AGENT_HUB_JIRA_NOTIFY_USERS` | `true` | `false` silences watcher notifications for description updates (needs Jira admin) |

**Per stage**, named `AGENT_HUB_<STAGE>_<setting>`, where `<STAGE>` is the
stage's folder name in capitals with `_` — e.g. `AGENT_HUB_WORK_ORDER_MODEL`,
`AGENT_HUB_IMPLEMENTATION_PLAN_MAX_BUDGET_USD`. Budgets are caps in
API-equivalent dollars ([claude-usage.md](claude-usage.md)):

| Setting | Work order (`WORK_ORDER`) | Implementation plan (`IMPLEMENTATION_PLAN`) | Purpose |
|---|---|---|---|
| `MODEL` | `claude-sonnet-5-5` | `claude-opus-5-5` | Model for the draft (Opus needs Claude Code 2.1.280+) |
| `FALLBACK_MODEL` | `claude-opus-5-5` | `claude-sonnet-5-5` | Used when the model is overloaded or unsupported |
| `MAX_BUDGET_USD` | `2.00` | `5.00` | Cap for the draft |
| `REVIEW_MAX_BUDGET_USD` | `2.00` | `5.00` | Cap for the expert review |
| `REVISION_MAX_BUDGET_USD` | `1.00` | `2.00` | Cap for each pass of a revision, which is scoped to the requested changes |

The build (`BUILD`) is **in preview**: the whole flow is built, but it runs
only with `AGENT_HUB_BUILD_PREVIEW=true` until its manual test and the
runner requirements are done ([build.md](workflows/build.md#status); the
production checklist in [build-design.md](workflows/build-design.md)). A Node
project must declare its Node version (an `.nvmrc`, for example: see
[build.md](workflows/build.md#toolchain)); its dependencies are installed
from its lockfile, and the hub runs its checks on every build's commit
([extending.md](extending.md#the-builds-checks) to choose them). Its
settings: `MODEL` (`claude-opus-5-5`), `FALLBACK_MODEL`
(`claude-sonnet-5-5`) and `MAX_BUDGET_USD` (`10.00`, one pass: it validates and
builds), `REVIEW_MAX_BUDGET_USD` (`5.00`, the code review, on the shared
review model), and for the fix pass `FIX_MODEL` (`claude-sonnet-5-5`),
`FIX_FALLBACK_MODEL` (`claude-opus-5-5`), `FIX_MAX_BUDGET_USD` (`3.00`) and
`FIX_CHECK_MAX_BUDGET_USD` (`1.00`), plus:

| Setting | Default | Purpose |
|---|---|---|
| `TARGET_BRANCH` | the repository's default branch | The branch pull requests go into. The build checks it out, so set it only together with the build workflow's checkout (it builds from the branch the run checked out, and stops if that isn't the target's head) |
| `LABEL` | `agent-hub` | Marks the hub's own pull requests; one from `agent-hub/<KEY>` without it isn't touched |
| `PAUSED_LABEL` | `agent-hub-paused` | On a hub pull request, tells the hub to leave it alone: a build run for the ticket changes nothing until it's removed |
| `MAX_FILES`, `MAX_LINES` | `50`, `2000` | Over either, the pull request gets a decision item for a person |
| `MAX_FILE_LINES` | `1000` | A single file changing more lines than this is a decision item |
| `INSTALL_MINUTES` | `10` | Time limit for installing the dependencies (each install: in the checkout, and in the verify step's copy); over it, nothing is built |
| `CHECK_MINUTES` | `10` | Time limit for each of the repository's checks in the verify step; over it, the check counts as failed and nothing is pushed |
| `CI_FIX_ATTEMPTS` | `2` | CI fixes the hub pushes for one hand-off, counted from the last full review (a person's commits, reviewed again, start a new count); past it, a failed check goes to a person |
| `CI_WAIT_MINUTES` | `120` | How long the CI gate waits for the required checks to report on a pull request's head (from when the hub recorded it) before asking a person — a path-filtered required check never runs |
| `MIN_RELEASE_AGE_DAYS` | `3` | The dependency step's minimum release age: every package version it adds or changes, direct and transitive, must have been published on or before now − N × 24 hours, by the registry's own times (`0` for none); otherwise nothing is built, before Claude ([build.md](workflows/build.md#dependencies-planned-changes-only)) |
| `ALLOWED_LICENSES` | permissive licences (MIT, ISC, BSD, Apache-2.0, …) | SPDX ids, comma-separated: a package the dependency step adds (direct or transitive) with any other licence, or none, is a decision item for a person — this list replaces the default |
| `BASELINE` | `stop` | The repository's checks on the base commit before the agent: `stop` builds nothing (and uses no Claude) when one already fails there; `warn` builds anyway, for a plan that fixes a failing check; `off` skips them ([build.md](workflows/build.md#baseline)) |

The workflow's steps have their own limits, which these settings can't
raise: 15 minutes for **Install dependencies**, 30 for **Verify** (the
verify copy's install and every check together), 30 for **Review**, 40 for
**Fix** (the fix pass and its check) and 30 for **Verify fix**. They're part of the hub's
workflow (`agent-hub-stage.yml`, which updates replace), so a repository
whose install and checks need longer than that isn't supported yet. The
settings above are per command, and a step runs several: **Install
dependencies** also installs the verify copy and runs the baseline checks
(a failing one twice), so with four checks the defaults can add up to more
than the step allows. Size `INSTALL_MINUTES` and `CHECK_MINUTES` to your
repository's real times. If GitHub does stop a step at its own limit, the
ticket's failure comment says what was running (since 2.19.0).

**The build's CI gate** (since 2.13.0) needs the target branch to **require
your CI's checks** — branch protection or a ruleset (Settings → Branches or
Rules): the hub hands a pull request off only once every required check has
passed on its head, so with none required it never hands off. It reads them
with the workflow's own token (read-only), and the **Agent hub: CI sweep**
workflow wakes it every 10 minutes; nothing to set up, except that GitHub
turns schedules off in a repository with no activity for 60 days (turn it
back on under Actions). Your Jira workflow must allow Implementation Plan
Approved → Ready for Review ([jira.md](jira.md#transitions)).

**Two repository settings make what the CI gate reads trustworthy** — the
checks run the build's code, and code that can post a check could pass
itself:
- **Workflow permissions: read-only by default** (Settings → Actions →
  General → Workflow permissions → *Read repository contents and packages
  permissions*). A workflow then can't post statuses or check runs unless it
  asks for that permission itself; the hub's own workflows ask only for what
  they need. (A new repository in an organisation already defaults to this.)
- **Required checks bound to the app that posts them:** in branch protection
  or a ruleset, pick each required check with its source — **GitHub
  Actions** for checks from your workflows — rather than any source. A check
  with no source can be satisfied by a status anyone with write access (or
  any token that can write statuses) posts under that name; the hub then
  counts it, and so does GitHub's merge protection. The CI gate warns in its
  run log about each required check that isn't bound (since 2.20.0).

**Self-hosted runners:** every stage job starts by emptying its work folder
(since 2.18.0), so nothing an earlier job's agent left — git hooks or config
included — reaches a later job. Nothing to set up; it means a full clone
each job. Use a runner only for this repository, or for repositories you
trust as much, and know that **everyone with write access can run code on
it** — the Claude login included ([runners.md](runners.md#self-hosted-runner-with-a-claude-subscription)).

**Your CI runs the build's code before a person reviews it.** The hub
pushes the agent's commits to `agent-hub/<KEY>` in this repository, so your
`pull_request` and `push` workflows run them — with whatever those workflows
can reach. Before the build runs real tickets:
- pull request CI holds **no secrets** beyond read-only ones (no deploy keys,
  no cloud credentials), with read-only default workflow permissions (above);
- CI doesn't run on the hub's `claude` runner (its own runner labels, or
  GitHub-hosted runners);
- `push` workflows that deploy or publish ignore `agent-hub/**`
  (`branches-ignore`).

**Before the build's first run** — required, or it stops at its first step,
saying which:
- `AGENT_HUB_BUILD_PREVIEW` set to `true` (the build is in preview);
- `AGENT_HUB_CLAUDE_CODE_VERSION` set to an exact version (`2.1.285`, not
  `latest`), matching the runner's Claude Code on a self-hosted runner;
- the build token (`AGENT_HUB_GITHUB_TOKEN`) and the machine user below.

**The machine user and branch protection.** The build pushes and opens pull
requests as a GitHub account of its own, which people's review then holds
back from merging:
1. Create a GitHub account for automation (a machine user, e.g.
   `<org>-agent-hub`), with two-factor authentication on.
2. Invite it to this repository with the **Write** role, and accept the
   invitation as it. In an organisation, allow fine-grained tokens for
   members (Settings → Personal access tokens), and approve its token if
   your organisation requires approval.
3. As it, create the build token (fine-grained, this repository only,
   Contents and Pull requests read and write) and put it in the
   `AGENT_HUB_GITHUB_TOKEN` secret, in the `agent-hub` environment.
4. Protect the target branch (branch protection or a ruleset): require a
   pull request before merging with **at least one approval**, **require
   approval of the most recent push** (so the hub's later pushes need a
   fresh approval), the required checks (above), and restrict who can push
   to it directly — not the machine user. GitHub never lets an account
   approve its own pull request, so a person always approves the hub's.

The hub doesn't check these settings itself: the manual test does
([build-design.md](workflows/build-design.md#production-checklist)).

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
permissions for the `AGENT_HUB_JIRA_EMAIL` account, and the five automation rules
(Work Order Requested, Implementation Plan Requested, Revision Requested,
Build Requested and Build Command), each with its web request pointing at
**your** repository's workflow.

Those web requests need **a GitHub token for Jira**: a fine-grained token for
**this repository only**, with **Actions: Read and write** and nothing else
(it starts workflows; it can't push code), ideally owned by a machine user —
see [step 6](#6-plan-for-credential-expiry) and
[what it can do](jira.md#web-requests).

## 6. Plan for credential expiry

Credentials expire, and when they do the workflows stop — quietly, from the
tracker's side (the Jira setup shown). Each lives with the system that uses
it: GitHub's workflows hold what they send (the Jira API token, the build
token), and Jira holds what it sends (the dispatch token).

| Credential | Lives in | Expires | When it expires | To renew |
|---|---|---|---|---|
| Jira API token | `AGENT_HUB_JIRA_API_TOKEN` secret | On the date set when it was created | Every run fails, and the failure comment can't be posted either (it uses the same token): tickets sit in Work Order | Create a new token for the same Jira account and update the secret |
| Dispatch token (`agent-hub-dispatch-<repo>`) | Each Jira rule's `Authorization` header | On the date set when it was created | Jira's web request fails, so no run starts | Regenerate it (same access) and update the header in every web request (seven across the five rules) |
| Claude login | The runner machine | Occasionally | Runs fail with the failure comment | Run `claude` on the runner and log in |
| `AGENT_HUB_ANTHROPIC_API_KEY` | Secret (API setup only) | When revoked | Runs fail with the failure comment | Create a new key and update the secret |
| Build token (`agent-hub-build-<repo>`) | `AGENT_HUB_GITHUB_TOKEN` secret (build stage) | On the date set when it was created | Builds fail at their first step; the failure comment says so | Regenerate it for the same user (same access) and update the secret |

### The two GitHub tokens

Two separate fine-grained tokens, each for this repository only. Name them as
below in GitHub (token names must be unique per account, so the repository
name keeps several installations apart), and put the purpose in the token's
description:

| | Dispatch token | Build token |
|---|---|---|
| Name in GitHub | `agent-hub-dispatch-<repo>` | `agent-hub-build-<repo>` |
| Description | "Jira automation → starts the agent hub's workflows" | "Agent hub build: push agent-hub/* branches, open draft pull requests" |
| Used by | Jira's rules, to start the stages | The build's fetch and apply steps |
| Lives in | Jira only ([jira.md](jira.md#web-requests)) | The `AGENT_HUB_GITHUB_TOKEN` secret only |
| Repository permissions | Actions: read and write (since 2.20.0; Contents before) | Contents: read and write; Pull requests: read and write |
| Never | In GitHub's secrets | In Jira; in an agent step or one running the repository's code |

**Don't share one token between them**: each would then carry the other's
exposure (Jira holding a token that can push code and open pull requests),
and rotating or revoking one would break both.

**Own them with accounts that aren't a person's**, so they don't break when
someone leaves or changes role:
- **Jira**: a dedicated service account for `AGENT_HUB_JIRA_EMAIL` / `AGENT_HUB_JIRA_API_TOKEN` — required, so it can be barred from approving and the hub can tell its own plan files from people's. Your own account works for testing the document stages, not the build ([jira.md](jira.md#permissions-for-the-automation-account)).
- **GitHub**: a machine user (a GitHub account for automation) that owns the
  fine-grained token in the Jira rule, limited to the repository with
  **Actions: Read and write**. (A GitHub App can't be used here: its tokens
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

## GitHub Actions costs (private repositories)

Public repositories run GitHub Actions free. In a private repository, GitHub
bills its hosted runners by the minute beyond each plan's included minutes
(2,000 a month on Free, 3,000 on Pro or Team), and macOS minutes count about
ten times. Self-hosted runners have no GitHub charge (a per-minute fee
GitHub announced for 2026 was postponed). Rates as of October 2026 —
check GitHub's billing page for current ones. Measured on this hub:

| Workflow | Runs on (default) | On GitHub-hosted runners in a private repository |
|---|---|---|
| The stages (work order, plan, build), the closed-pull-request workflow | Your runner (`AGENT_HUB_RUNS_ON`) | About 45–90 minutes per ticket, all stages (~$0.30–0.55 at $0.006 a minute); the Claude API costs far more ([claude-usage.md](claude-usage.md)) |
| The CI sweep (every 10 minutes, while the build preview is on) | Your runner | At least one billed minute per run: about 4,300 minutes a month (~$26) — over the Free plan's minutes on its own |
| The hub's own tests (`agent-hub-tests.yml`) | Always GitHub-hosted (Ubuntu and macOS) | Only when a pull request changes hub files (in a project repository: a hub update): about 17 Linux and 11 macOS minutes per pull request (~$0.80, about 130 included minutes), and about $1 more after it merges |
| Your own CI | As you set it | Runs on every push the build makes (the build, each fix, each `/apply`) |

**To keep costs down:** run the stages and the sweep on a self-hosted
runner (the default) — then GitHub bills nothing for them. Planned: the
hub's own test suite skipped in project repositories, where the hub isn't
being developed (in the v1 roadmap), and a CI sweep that costs nothing on
any runner (after v1:
[build-design.md](workflows/build-design.md#after-v1)).

## Several repositories

Each repository that has the workflows is independent: its own runner (or
shared runners at the organisation level with the `claude` label), secrets,
variables and tracker rules. One Jira project can serve several repositories with
one rule per repository, each pointing its web request at its repository.
