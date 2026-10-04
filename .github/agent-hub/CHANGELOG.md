# Changelog

What changed in each release of the agent hub, newest first. Each entry says
what a repository has to do when updating to it, under **Updating**
("Nothing" when it's just a file update). How to update:
[docs/updating.md](docs/updating.md).

## 2.5.0 — 2026-10-04

The build stage, first part: an approved plan becomes a draft pull request
for a person to review. **Not enabled for real tickets yet:** until the
install step (next version), it runs only with `AGENT_HUB_BUILD_PREVIEW=true`,
for development on a project without dependencies (`playground/`).

- **The build** (`agent-hub-build.yml`, `stages/build/`): on the move to
  Implementation Plan Approved, the hub checks the approval is for the exact
  plan file on the ticket (none added or removed since, moved there by a
  person), reads the plan's contract, and runs one agent pass that validates
  the plan against the code and builds it in the sandbox, running the
  repository's tests. It then commits as the machine user, checks the commit
  against the plan (refused paths stop it; anything outside the plan is a
  decision item), scans it for secrets, pushes `agent-hub/<KEY>` and opens a
  labelled draft pull request from the hub's template, with its state block.
  The ticket gets the link and `needs-human`. Questions go into a new plan
  version and the ticket back to Implementation Plan; "no change needed" and
  manual-only plans are flagged for a person. The review, CI gate and
  hand-off come in later versions.
- **Public repositories get no ticket text** in pull requests or commits
  unless `AGENT_HUB_PUBLISH_TICKET_CONTENT` is `true`.
- **Nothing an agent leaves in the checkout runs later**, in every stage:
  each step loads the hub from a copy made before the agent runs. The build's
  git runs from metadata copied before the agent too (its hooks, config and
  commits are ignored), and the checks read the commit, not the working tree.
- **The shared stage workflow** has a `code-stage` input (full history; the
  machine user's token for the fetch and apply steps only — never an agent
  step or one that runs the repository's code), and failure comments can carry
  a stage's own retry instructions.
- **Builds queue per ticket** (`queue: max`): a run is never cancelled
  mid-push and no request is dropped; each run acts on the state it finds.
- **Rebuilding** after a closed pull request needs its branch deleted and a
  new approval of the plan after the close — closing and deleting alone don't
  authorise a new build.
- **`playground/`**: a tiny Node project in this repository, with its own CI,
  to try the build on.

**Updating:**

1. Add the `AGENT_HUB_GITHUB_TOKEN` secret: a new fine-grained token named
   `agent-hub-build-<repo>` (this repository; Contents and Pull requests
   read/write) — not the Jira rules' dispatch token, which stays in Jira
   ([the two GitHub tokens](docs/setup.md#the-two-github-tokens)). Your own
   account's works for development; a machine user's before real tickets.
2. In Jira, turn the *Implementation Plan Approved* rule into
   [Build Requested](docs/jira.md#rule-build-requested): add the web request,
   and allow the Implementation Plan Approved → Implementation Plan
   transition.
3. Use a self-hosted runner with git 2.40 or later for the build
   ([docs/runners.md](docs/runners.md#the-sandbox-build-stage)), and run the
   sandbox check on it if you haven't.

Without `AGENT_HUB_BUILD_PREVIEW=true`, an approval's build fails at its first
step, saying the stage isn't enabled yet — before Claude, GitHub or the plan.
For development in this repository: set it, add the token, and point the
build at `playground/` tickets.

## 2.4.0 — 2026-10-03

The build stage's foundation: tested building blocks, not yet used by a stage.

- **The GitHub library** (`lib/github.sh`): pull requests, the description's
  full edit history, branch lifecycle, never-forced pushes, rewritten-history
  detection, and the publication policy for public repositories. The machine
  user's token reaches only the steps that write to GitHub, through files —
  never a command line.
- **The state block** (`lib/state.sh`): the hub's bookkeeping in a pull
  request's description, trusted only while every edit by anyone else leaves
  it byte-for-byte unchanged. Writes start from the description as it is now
  and are verified in the edit history, so a simultaneous human edit is
  caught, never silently lost (tamper-evident, not transactional).
- **The secret scan** (`lib/secret-scan.sh`): pinned, checksum-verified
  gitleaks, failing closed, which a repository can't switch off — run inside
  every push, on every commit the push would send.

**Updating:** nothing to do. The build stage (next) will need the
`AGENT_HUB_GITHUB_TOKEN` secret — a machine user's token
([docs/setup.md](docs/setup.md#3-add-secrets)).

## 2.3.0 — 2026-10-03

The repository's own Claude Code setup is back, and the build stage's tool
profiles and sandbox are in place.

- **The repository's `CLAUDE.md`, agents and skills are loaded again**
  (missing since 2.0.1, when restricted mode came in): `CLAUDE.md` joins the
  agent's instructions as repository guidance; `.claude/agents/` and
  `.claude/skills/` load like an extension's. Links are skipped. Extension
  agents and skills now load from a copy with a manifest the hub writes.
- **Repository content adds guidance, never capabilities:** only agents and
  skills are copied (no hooks, MCP servers, settings or commands), and their
  definitions keep only allowed fields — none can declare a permission mode,
  hooks, MCP servers or pre-approved tools.
- **Claude Code's bundled skills are off** for every pass — the pipeline
  doesn't use them.
- **Tool profiles for the build stage** (planned): *build* edits the
  repository and runs commands; *review* runs commands without edits; neither
  has web tools. Every command runs in Claude Code's sandbox — the repository
  and a temp folder only, localhost only, no secrets in its environment, and
  no command if the sandbox can't start. Verified on macOS with real Claude.
  The document stages keep the same capabilities (now with the repository's
  guidance).
- **A sandbox check:** `.github/agent-hub/scripts/check-sandbox.sh` checks
  both profiles' limits with the real Claude Code (about $0.20, confirmed with
  `use-claude`). Run it on a new runner and after every Claude Code upgrade.

**Updating:** nothing to do now. Before the build stage, run the sandbox check
on your runner ([docs/runners.md](docs/runners.md#checking-the-sandbox)); on a
personal machine, see [Before running the build on real tickets](docs/runners.md#before-running-the-build-on-real-tickets).

## 2.2.0 — 2026-10-03

The existing stages brought up to the rules the build stage will rely on.

- **Plans are written only from the work order exactly as approved.** If the
  description was edited after the move to Work Order Approved (by anyone),
  the ticket goes back to Work Order (with `needs-human` and a comment); if
  the approval can't be found or the history can't be read, the run fails —
  both before Claude runs.
- **A new work order stops if the request is edited mid-run**, instead of
  writing a work order from the older text.
- **Plans state their scope and governance:** a risk level, which sensitive
  kinds of change they include (dependencies, schema or migration, public
  API, auth or permissions, sensitive data, infrastructure, workflow or CI,
  configuration), paths also in scope, areas that must not be touched, and
  manual changes for a person (workflows, Claude Code settings, CODEOWNERS —
  never in Changes by File; a plan can be all manual changes). Plus an Observability section, the commit the
  plan describes in its Version line, and a risk line in the ticket summary.
- **A kill switch:** the repository variable `AGENT_HUB_ENABLED=false` stops
  every hub workflow.
- **Every run summary ends with its outcome** (written, revised, sent back,
  no change needed, superseded, stale, failed).
- **Trust levels in every prompt:** repository content is information; its
  guidance never overrides the hub's instructions.
- **All actions pinned to full commit SHAs** (Dependabot keeps them current).

**Known issue (since 2.0.1):** the agents don't load the repository's own
`CLAUDE.md`, `.claude/agents/` or `.claude/skills/` — Claude Code's restricted
mode skips them. The next release loads them explicitly; meanwhile, put what
the pipeline needs in extensions.

**Updating:** in Jira, add the Implementation Plan Approved rule
([docs/jira.md](docs/jira.md#rule-implementation-plan-approved)) to clear
`needs-human` when a plan is approved — optional, nothing breaks without it.
Plans written before this version keep working; a revision adds the new
sections when it changes them.

## 2.1.0 — 2026-10-03

The build stage's design, and the rules every stage follows. Docs only.

- **Build design (draft):** [docs/workflows/build.md](docs/workflows/build.md)
  — the planned build pipeline, reviewed externally three times: the approval
  check, validation, build and verification, independent review with a policy
  table, one fix pass and a fix check, the CI gate, hand-off, review items and
  `/apply`, concurrency, the PR as the record, caps and human gates, safety,
  the implementation order, and what's left for later.
- **Pipeline-wide rules** in [docs/architecture.md](docs/architecture.md): the
  pipeline as a state machine, the shared outcome names, who is authoritative
  for what (tracker, GitHub, hub), trust levels for what agents read, and the
  invariants every stage keeps.
- **The automation never approves:** a dedicated service account, barred from
  the "…Approved" transitions, is now required in Jira.

**Updating:** in Jira, use a dedicated service account for
`AGENT_HUB_JIRA_EMAIL` and add a condition to each "…Approved" transition
allowing only your approvers ([docs/jira.md](docs/jira.md#permissions-for-the-automation-account),
which explains why). Nothing stops working until you do; your own account
works for testing.

## 2.0.2 — 2026-10-03

Faster runs and tests.

- Each step reads the repository variables once, instead of once per
  setting (about 90 fewer `jq` calls per run).
- The tests run in parallel, one job per CPU, when GNU parallel is installed
  — about 3× faster locally — and CI installs it. Without it they run one at
  a time, as before.

**Updating:** nothing to do. To run the tests in parallel locally, install
GNU parallel (macOS: `brew install parallel`).

## 2.0.1 — 2026-10-03

Fixes from a review of the existing stages: runs no longer act on things
that changed while they worked, and the agents' limits no longer depend on
the repository's settings.

- **A person's plan upload is never lost or deleted.** A revision stops,
  changing nothing, if a newer plan file was uploaded while it worked; if
  one lands while it publishes, or the check itself fails, it takes back its
  own upload and description change. The hub deletes only its own earlier
  plan files, so `Delete own attachments` is enough; failing to remove one
  is a warning, not a stopped run (the newest file is the plan).
- **People's edits during a run are kept.** A work-order revision stops,
  naming the section, if a person edited a section it changes while it
  worked.
- **Only requests the agent saw and answered are marked resolved.** Each
  request goes to Claude with its id and each answer names it; a `/revise`
  added or edited during a run, or left unanswered, stays open for the next
  one. What counts as a request is one rule for the prompt and for
  resolving.
- **The agents' limits hold whatever the repository's settings say:**
  Claude Code runs in restricted mode (no settings file can add permissions
  or directories; file tools confined to the repository) with an explicit
  list of tools.
- **Failure notices are accurate:** they name the ticket's current status, add
  `needs-human` only while the ticket is still the stage's, and are posted as
  a new comment if the progress comment is gone. A failure resolving comments
  now fails the run instead of passing unnoticed.
- **Every comment is read**, a page at a time (more than 1,000 stops with a
  clear error) — the newest were missed past 100.
- Plan files: `## ` lines inside code blocks (CommonMark fences) no longer
  split sections; Windows line endings and `## Testing ##` headings read the
  same; a section a revision changes appearing twice stops the run. Plan
  file paths must stay inside the repository, and a file to add must not
  exist yet (not even as a link) nor sit beneath a link that doesn't
  resolve. A request using "Overview" or "Scope" as headings is no longer
  mistaken for an existing work order.
- Evals: the work-order cases' setup is fixed, each case's setup is now
  checked in CI without Claude, and the spend total no longer drops a
  draft's cost when there's no review.
- Tests: the Jira mock fails on unexpected requests, follows transitions and
  can fail any call from its Nth time; variants of a scenario replace
  near-copies; every stage must be in the test suite. CI cancels superseded
  runs.
- Docs: install commands no longer name old releases; security claims say
  exactly what's enforced and what isn't (web search queries leave the
  runner; changes in the last seconds before a write; no lock across
  stages).

**Updating:** the runner needs a Claude Code with restricted mode (`claude
--help` lists `--restricted`); without it, runs stop and say so. On
GitHub-hosted runners, an `AGENT_HUB_CLAUDE_CODE_VERSION` pinned to an older
version needs raising.

## 2.0.0 — 2026-10-02

Preparation for the next stages: consistent settings, fewer Jira updates,
faster installs and updates.

- **Per-stage settings are named the same way for every stage:**
  `AGENT_HUB_<STAGE>_<setting>` (`MODEL`, `FALLBACK_MODEL`, `MAX_BUDGET_USD`,
  `REVIEW_MAX_BUDGET_USD`, `REVISION_MAX_BUDGET_USD`), and the review model is
  `AGENT_HUB_REVIEW_MODEL` / `AGENT_HUB_REVIEW_FALLBACK_MODEL` — see
  [docs/setup.md](docs/setup.md#4-set-variables-only-what-differs-from-the-defaults).
  Each stage's review budget is now its own (one variable used to set both).
- Each run makes fewer Jira updates: label changes go in the same request as
  the description, or together in one, so fewer Jira automation events.
- The update script is several times faster, and gives a repository without
  extensions a README on where they go.
- Local hooks lint on commit only; the tests run in CI (and by hand).

**Updating:** if you set any of these repository variables, rename them:

| Before | Now |
|---|---|
| `AGENT_HUB_CLAUDE_MODEL`, `_CLAUDE_FALLBACK_MODEL`, `_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_MODEL`, `_FALLBACK_MODEL`, `_MAX_BUDGET_USD` |
| `AGENT_HUB_REVISION_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_REVISION_MAX_BUDGET_USD` |
| `AGENT_HUB_PLAN_CLAUDE_MODEL`, `_PLAN_CLAUDE_FALLBACK_MODEL`, `_PLAN_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_IMPLEMENTATION_PLAN_MODEL`, `_FALLBACK_MODEL`, `_MAX_BUDGET_USD` |
| `AGENT_HUB_PLAN_REVISION_MAX_BUDGET_USD` | `AGENT_HUB_IMPLEMENTATION_PLAN_REVISION_MAX_BUDGET_USD` |
| `AGENT_HUB_REVIEW_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_REVIEW_MAX_BUDGET_USD` and `AGENT_HUB_IMPLEMENTATION_PLAN_REVIEW_MAX_BUDGET_USD` |
| `AGENT_HUB_REVIEW_CLAUDE_MODEL`, `_REVIEW_CLAUDE_FALLBACK_MODEL` | `AGENT_HUB_REVIEW_MODEL`, `_REVIEW_FALLBACK_MODEL` |

Contributors: remove the old push hook with
`pre-commit uninstall --hook-type pre-push`.

## 1.0.0 — 2026-10-02

The first release.

- Stages: **work order** (an intake ticket → a structured work order, or back
  for details) and **implementation plan** (an approved work order → a
  technical plan attached to the ticket, or back with questions), each with an
  expert review, scoped `/revise` revisions and reverse paths.
- Tracker: **Jira**. GitHub Projects: setup foundations and the intake form;
  its stages aren't connected yet.
- Agent runner: **Claude Code**, read-only and isolated; session files
  removed after every run.
- Repository extensions per stage (`.github/agent-hub-extensions/`).
- Install and update script, tests, evals and docs.

**Updating:** first install — follow [docs/setup.md](docs/setup.md).
