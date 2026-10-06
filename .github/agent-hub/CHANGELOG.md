# Changelog

What changed in each release of the agent hub, newest first. Each entry says
what a repository has to do when updating to it, under **Updating**
("Nothing" when it's just a file update). How to update:
[docs/updating.md](docs/updating.md).

## 2.6.2 — 2026-10-06

The re-test on 2.6.1 got through the verify copy, then the check failed in
a second: Node aborted on startup inside the sandbox, after Claude had run.

- **Fixed: commands in the hub's sandbox on self-hosted runners.** A
  self-hosted runner's temp folder is in the home folder
  (`~/actions-runner/_work/_temp`), which the sandbox denies. The commands'
  output went straight to a log file there, and Node aborts when its output
  is a file it can't read. The output now reaches the log through a pipe, so
  the command never holds the file. This affected every check and install
  that runs Node on a self-hosted runner with the default layout.
- **The rehearsal before Claude now runs a command in the sandbox**: Node
  starting, as the checks will. A sandbox that can't run the toolchain stops
  the build before any Claude usage, with the end of its output on the
  ticket. 2.6.1's rehearsal ran no sandboxed command when there was nothing to
  install, which is why this got past it.
- **Tests:** a real-sandbox probe laid out as on a self-hosted runner (the
  job's folders inside the denied home folder, running Node); fails on 2.6.1
  with the same abort. A scenario where the toolchain can't start in the
  sandbox stops the build before the agent.

**Updating:** nothing to do. Re-approve a ticket whose checks failed this way.

## 2.6.1 — 2026-10-06

The first real build on 2.6.0 ran the agent, then failed before its checks:
"Couldn't make a copy of the build's commit to check". Claude's spend was
wasted on a problem that didn't depend on the agent.

- **Fixed: the verify step's copy of the build's commit.** The workflow's
  checkout is sparse and partial (the hub's own test data is left out, and
  that data's content is never fetched), so a plain copy of it couldn't be
  checked out. The copy now uses the checkout's sparse patterns, taken from
  the git metadata copied before the agent ran. When a copy still fails,
  git's message is on the ticket (not in the run log).
- **The verify step is rehearsed before Claude runs.** The install step now
  makes the same copy of the base commit, installs its dependencies, reads
  the list of checks and installs the sandbox runtime. A problem with the
  environment stops the build before any Claude usage; after the agent, only
  the checks themselves can fail.
- **Tests:** the scenario checkouts are now sparse and partial, made with the
  stage workflow's own patterns (they'd have caught this); a rehearsal
  failure stops the build before the agent.
- **The sandbox check** names the planted skill as Claude Code lists it
  (`repository:check-skill`), and its CLAUDE.md, agents and skills items show
  what Claude reported when they fail.

**Updating:** nothing to do. A ticket whose build failed this way: move it
back to Implementation Plan and approve it again.

## 2.6.0 — 2026-10-05

The build runs in a known environment, and checks its own work: the first
real builds ran whatever Node the sandbox could find (an old one, since the
runner's own was in the home folder) and only reported the checks the agent
said it ran.

- **The repository's Node version.** The build workflow sets up the Node
  version the repository declares (`.nvmrc`, `.node-version`,
  `.tool-versions`, or `package.json`'s `engines`, `volta` or `devEngines`)
  with `actions/setup-node`, and makes that one folder readable in the
  sandbox and first on the agent's commands' `PATH`. A repository with a
  `package.json` that declares no version isn't built: the build stops before
  Claude, asking for an `.nvmrc`. Other toolchains are the runner's, and the
  docs say so ([build.md](docs/workflows/build.md#toolchain)).
- **Dependencies installed from the lockfile**, before the agent starts, by a
  new step with no agent and no credentials: `npm ci`, or pnpm's or Yarn's
  frozen install, in the sandbox runtime (`srt`, the engine of Claude Code's
  own sandbox) with the package registries as its only network. Every
  process the install starts — a package's install scripts and their
  children too — can't read the home folder, write outside the project or
  reach anything else. No lockfile, a private registry, an install that fails,
  runs out of time or changes the repository: nothing is built
  ([build.md](docs/workflows/build.md#install)).
- **The hub runs the repository's checks on the build's commit.** A new
  verify step commits the agent's changes, installs a clean copy of exactly
  that commit, and runs its checks in the sandbox with no network but
  localhost: the `package.json` scripts `test`, `lint`, `typecheck` and
  `build`, or the repository's new `build/checks.json` extension, both as
  they were before the agent ran. **A check that fails means nothing is
  pushed**; the ticket gets a "🧪 Checks that failed" comment with the end of
  each one's output (never in the run log). Otherwise only that commit is
  pushed, and the pull request and the ticket show the hub's results first,
  with the checks the agent reported separately
  ([build.md](docs/workflows/build.md#verify),
  [extending.md](docs/extending.md#the-builds-checks)).
- **Time limits** for the install (`AGENT_HUB_BUILD_INSTALL_MINUTES`) and each
  check (`AGENT_HUB_BUILD_CHECK_MINUTES`), 10 minutes each, ending everything
  the command started; the build job's limit is now 140 minutes.
- **The preview gate stays until the review and CI gate (PR 4)**, changing
  the earlier plan to lift it now: a person is still the build's only
  reviewer ([build.md](docs/workflows/build.md#building-it)).
- **Tests:** the sandbox probed against the real runtime
  (`tests/shared/sandbox.bats`: an install script's child process, localhost
  for checks, the time limit), run in CI on Linux with the sandbox tools
  installed; the install command per lockfile, the checks' source, and the
  build's paths with a failing check, no declared Node and no lockfile.
- **This repository:** the playground declares Node 22 (`playground/.nvmrc`,
  used by its CI) and its checks (`.github/agent-hub-extensions/build/checks.json`);
  Dependabot keeps the sandbox runtime's lockfile current.
- **Fixes:** a time limit of 0 is refused (it would have been none).

**Updating:**

1. **A Node repository declares its Node version** — add an `.nvmrc` (e.g.
   `22`) if it has none — and **commits its lockfile**.
2. **If its checks aren't the root `package.json`'s `test`, `lint`,
   `typecheck` and `build` scripts** (a project in a subfolder, or not a Node
   project), add `build/checks.json` to your extensions
   ([extending.md](docs/extending.md#the-builds-checks)).
3. **Runners:** a self-hosted Linux runner also needs `ripgrep`, and on
   Ubuntu 24.04 the user-namespaces setting
   ([runners.md](docs/runners.md#the-sandbox-build-stage)); macOS needs
   nothing. Every runner needs to reach `registry.npmjs.org` the first time a
   build runs (the hub installs the sandbox runtime into its tool cache).
4. **Run the sandbox check again** (it uses Claude, about $0.20): the build
   profile's sandbox now reads the Node folder and sets the commands' `PATH`
   ([runners.md](docs/runners.md#checking-the-sandbox)).

## 2.5.3 — 2026-10-05

From the second real build: the ticket had everything, but its testing
instructions described what the build did rather than what a reviewer should
do, and a step the build couldn't run was shown as checked.

- **Reviewer's steps, with expected results.** The build now writes how a
  person reviews the change (`review_steps`, replacing `manual_checks`): each
  step a command to run (or what to open) and what they should see, covering
  every acceptance criterion a person can observe. A step is marked as seen by
  the build only if it ran exactly as written and gave that result; otherwise
  it says why not. Automated checks stay with the checks run.
- **The ticket's Delivery sections read on their own.** Testing Instructions:
  check out the branch, then the steps as the reviewer's own checklist (every
  box open, each with what to expect and whether the build saw it), then the
  checks run. Pull Request: the link, what changed, and each file with its
  line counts.
- **The 🔨 comment says what happens next**: the ticket stays in
  Implementation Plan Approved until the hand-off (a later version), so a
  person reviews the draft and moves it on.
- **When the environment stops a check**, the build reports it as it went
  (failed or not run, and why) and doesn't change the repository to work
  around it.
- **Docs:** what happens when a pass reaches its budget cap, per stage (nothing
  half-written is applied, nothing existing is lost, and how to retry); tools
  installed in the home folder (nvm, pyenv, rbenv) aren't
  visible to the build's sandboxed commands — the first real build ran an old
  Node from `/usr/local/bin` — and the next version's install step provides
  the repository's declared toolchain; the pull request's and ticket's
  content.

**Updating:** nothing to do. (Builds' recorded outputs use `review_steps`
now; nothing else reads them.)

## 2.5.2 — 2026-10-05

From the first real build: its pull request was hard to follow in a public
repository, and the details it held back went nowhere.

- **The ticket gets the build's whole report**, whatever the repository's
  visibility: the "🔨 Draft pull request opened" comment now has what changed,
  how each acceptance criterion is verified, the checks run and their results
  (including why one failed), the manual steps, the build's decisions and
  what's left for a person. The work order's **Pull Request** and **Testing
  Instructions** sections are filled in (the link; the manual steps as a
  checklist and the checks run), with `needs-human`. A description without
  those sections, or one that would pass Jira's size limit, keeps its text —
  the comment has it all.
- **Clearer pull requests.** The title names what changed when ticket text
  can't be published ("PROJ-1: change src/a.js and src/b.js"); the description
  opens with what the pull request is and where the details are, lists each
  file with its line counts, refers to criteria and checks by number with a
  pointer to the ticket, and shows the run's real duration.
- **The plan's Must not touch and Also in scope lists** are paths or patterns
  only, never sentences.
- **Docs:** adding the Jira service account; restricting both "…Approved"
  transitions to people (team-managed and company-managed); every Jira web
  request (six across the four rules) sends the same dispatch token to
  `…/dispatches`; testing with your own Jira account works for the document
  stages, not the build.

**Updating:** nothing to do. To see the full report on an existing ticket,
rebuild it (close its pull request, delete the branch, approve the plan again).

## 2.5.1 — 2026-10-04

Boundary hardening, from two full reviews of 2.5.0 — before the build runs
on a real ticket.

- **Credential files are always removed.** A code stage's steps load both
  the tracker and GitHub, and GitHub's cleanup replaced the tracker's, leaving
  the Jira credential file in the job's temp folder for the agent step. Each
  library now adds its files to one cleanup, the final step also removes any a
  killed step left, and every test step fails if it leaves one behind.
- **The gates read exact file names.** Git quotes names with special
  characters, which slipped such a file past the refused paths (a workflow
  named with an accent was a decision item, not refused). The gates now read
  git's NUL-separated output, match hub paths in any letter case, and fail if
  git can't list the changes.
- **Approvals bind to what was approved.** The build reads the approval and the
  plan files together and again before it pushes or sends the ticket back: a
  plan newer than the approval, a plan file added or removed, or the work order
  edited since the approval makes it stale. The plan stage no longer publishes
  a plan when the work order changed while it was written.
- **A first push needs the branch absent** — one created during the run, even
  at the same commit, isn't pushed to.
- **The build needs an exact Claude Code version**
  (`AGENT_HUB_CLAUDE_CODE_VERSION`, e.g. `2.1.280`) matching the runner's,
  checked before any Claude usage; Claude Code doesn't update itself during
  runs. The sandbox check stays a manual step (it uses Claude).
- **Public pull requests show checks by number and result**, not the commands
  Claude wrote, and Claude's commit message loses trailers that would
  attribute the commit (e.g. `Co-authored-by`).
- **The plan's contract is read strictly**: any list marker reads the same; an
  item it can't read, or a repeated section or label, stops the build rather
  than silently dropping a restriction; the base commit comes only from the
  Version line.
- **Tests never reach the real Claude** even with `REAL_CLAUDE` or `RUN_EVALS`
  exported; evals refuse parallel cases and a cap that isn't a number, and an
  unreadable cost stops the run instead of counting as $0. One test that
  needed the network no longer does.
- **Tightened further after a second look:** a time that can't be read (or
  a fraction of a second) is handled — an unreadable time counts as stale,
  never as approved; the contract also reads numbered and indented items and
  rejects prose in a list (an empty list is only the exact line the plan
  stage writes), a change written as an indented line and repeated table
  rows; a file with more than one hard link is never committed; the gates fail
  on any error — a size limit that isn't a number included (checked before
  Claude runs too) — and nothing is pushed without their complete result; a
  file's attributes are read exactly, whatever its name holds.
- **One definition each** for the paths only people change (`lib/paths.sh`,
  used by the agent's deny rules, the plan's path check and the gates), the
  acceptance criteria, the "every criterion covered" check, the "changed after
  approval" send-back and the plan file's name. The tracker's history names
  changes by kind (`attachment`, `description`), so the build no longer reads
  Jira's field names.
- **The build's questions are cleared once answered**: a plan revision answers
  a "Questions from the build" section and removes it.
- **The CI eval notice** suggests evals only for stages that have them.
- **Docs:** no more "not built yet" or "planned" for the build; what Claude
  usage the build adds, and that caps are per pass (not a total); the kill
  switch stops runs before they start; the PR 4 prerequisites (a read-only
  review profile, GitHub's edit-history format) are written into the build
  plan.

**Updating:** for the build (development only), set
`AGENT_HUB_CLAUDE_CODE_VERSION` to the runner's version (`claude --version`)
and add `DISABLE_AUTOUPDATER=1` to the runner's `.env`
([docs/runners.md](docs/runners.md#claude-code-version)). Nothing else.

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
([docs/jira.md](docs/jira.md#rule-build-requested), then named Implementation Plan Approved) to clear
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
