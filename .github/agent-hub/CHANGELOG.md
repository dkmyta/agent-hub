# Changelog

What changed in each release of the agent hub, newest first. Each entry says
what a repository has to do when updating to it, under **Updating**
("Nothing" when it's just a file update). How to update:
[docs/updating.md](docs/updating.md).

## 2.21.0 — 2026-10-10

Fixes from two reviews of 2.20.0 — this session's, and a fresh one with no
context — before the first full manual test.

- **The sandboxes deny the runner's own folders, wherever it's installed:**
  its install folder (its identity), its temp folder and its tool cache, as
  well as the home folder — for the agent's commands and the hub's own. A
  runner outside the home folder (`/opt/actions-runner`, common on Linux)
  had them readable, and what a command reads could be written into the
  pull request. The rest of the machine stays readable, and the docs now say
  so (the "reads only the repository" claims were wrong). The sandbox check
  probes it.
- **Text from outside the hub is shown as written in the pull request:**
  Claude's, the ticket's and a package's licence get no links, images,
  mentions or HTML — an image GitHub's servers fetch could carry data out.
  A licence or version can no longer break a line or forge a marker.
- **`/apply` acts only on the review the pull request's record names:** the
  findings' full text lives on the ticket, where anyone who can edit it can
  change it; the record now keeps its hash, and an edited copy is refused.
- **Hand-off and CI fix recovery:**
  - a pull request marked ready whose ticket didn't move (the move failed)
    is finished by a re-run, instead of "nothing to do" for good;
  - new commits reviewed after a hand-off undo it: back to draft, with a
    comment, until the gate hands it off again;
  - a CI fix whose run stopped part-way is reported to a person, once,
    instead of passing silently as "already tried".
- **Processes a command leaves running end with it** (the hub's own install
  and checks; macOS's sandbox didn't end them).
- **Smaller:** a wake value the hub never sets is refused without a comment
  on the ticket; a time-limit note can't be reported for a later step's
  failure; extensions that can't be read stop the build instead of being
  skipped; the hub's git copy reads its settings entry by entry.
- **Setup and docs:** the machine user and branch protection, step by step;
  what your CI runs (the build's code) and how to keep secrets from it; that
  everyone with write access can run code on a self-hosted runner, its
  Claude login included; the build's requirements stated plainly (preview,
  an exact Claude Code version, the build token); the approvers group
  required before real tickets; the API key in the `agent-hub` environment
  (runners.md said repository secret); who can lift the caps; undoing an
  update's manual steps; stale details corrected.
- **`repository_dispatch` stays until 2.22.0**, after the first full manual
  test (2.20.0 said this release), so the Jira rules keep working until
  you've switched them.

**Updating:**
- If you haven't done 2.20.0's steps: **move the secrets into the
  `agent-hub` environment first**, then switch the Jira rules to
  `workflow_dispatch` — a dispatch can name any branch, and the
  environment's branch limit is what keeps a run on another branch from the
  secrets.
- Open pull requests from before 2.21.0 have no review hash: `/apply` can't
  use their findings until a run reviews them again (a person's re-run).
- Check your CI and runner against the new setup notes (no secrets in pull
  request CI, CI off the `claude` runner).

## 2.20.0 — 2026-10-09

Dispatch, setup and docs, from the 2.17.0 reviews.

- **The Jira rules start workflows directly** (`workflow_dispatch`), with a
  token that has only **Actions: read and write** — it can start workflows,
  but not push code, as the old **Contents: read and write** token could.
  Each rule calls its stage's workflow
  (`…/actions/workflows/<file>/dispatches`, body
  `{"ref": "<default branch>", "inputs": {"ticket_key": …}}`).
  `repository_dispatch` still works in this release, so nothing breaks while
  the rules change; the next release removes it.
- **Secrets in an `agent-hub` environment:** every stage's job names it, so
  with the secrets there and the environment limited to the default branch,
  a run someone starts on another branch — with its own copy of the hub's
  scripts — gets none of them. GitHub creates the environment on the first
  run; repository-level secrets keep working until you move them.
- **The CI gate warns about a required check not bound to an app** (any
  source can meet it, the build's own code in CI included), and setup now
  asks for read-only default workflow permissions and app-bound required
  checks.
- **The plan summary shows what the build may change:** the files and how,
  wider scope patterns, what it must not touch, the dependency changes and
  the manual changes — read from the attached plan the way the build reads
  it, so approving the plan approves what the build's gates enforce. A plan
  the build can't read shows its problems instead.
- **Docs current:** the build is described as complete and in preview
  everywhere; `build.md` is now the workflow as built, and a new
  `build-design.md` holds the contracts, decisions, history, after v1 and
  the **production checklist** (including the CI sweep's and closed-PR
  workflow's preview condition, and the approvers group as required);
  Revision Requested limited to the people who work the tickets, and why;
  the counts (five rules, seven web requests), the shared concurrency, where
  `checks.json` is read from, and the build's review cap corrected. The
  pull request's note and the ticket's report describe the hand-off instead
  of "a later version". "Support for any device" (Windows) is on the after
  v1 list.
- **Tests:** setup.md must document every setting the code defines, with
  its default; the stage workflows must take what the tracker sends; the
  stage job's environment; the scope block; the unbound-check warning.

**Updating:**
- **Change the Jira rules** ([jira.md](docs/jira.md#web-requests)): create a
  dispatch token with only Actions: read and write, then in each of the
  seven web requests set the URL to its stage's workflow, the body to
  `{"ref": "main", "inputs": {"ticket_key": "{{issue.key}}"}}` (your default
  branch; Build Command adds `"wake": "command"`) and the new token. Check
  each rule's audit log shows 204, then delete the old token. Before 2.21.0.
- **Move the secrets** into the `agent-hub` environment, limit it to your
  default branch, and delete the repository-level copies
  ([setup.md](docs/setup.md#3-add-secrets)).
- **Set read-only default workflow permissions, and bind each required
  check to its app** ([setup.md](docs/setup.md)).
- Runs now show under the repository's Deployments (the environment).
- Links into `build.md` for its contracts, decisions, history or after v1
  now point to `build-design.md`.

## 2.19.0 — 2026-10-09

Correctness fixes from the 2.17.0 reviews, and how the hub is tested.

- **After the hand-off, a person's run checks the pull request again.** A run
  a person starts (Actions → Agent hub: Build → Run workflow) for a ticket in
  Ready for Review or Approved now reconciles its pull request — commits
  pushed since the hand-off are verified and reviewed; before, it did
  nothing (reproduced). A new build still starts only from Implementation
  Plan Approved, and a repeated wake-up after a hand-off changes nothing.
  `/apply`'s refusal after someone else's push says how to run it.
- **A hand-off that stopped part-way is finished:** recorded, but the pull
  request still a draft (marking it ready failed) — the CI sweep now wakes
  the gate for it instead of treating it as handled.
- **The record survives a browser save:** a description saved with Windows
  line endings no longer makes the state block untrusted.
- **`/skip` is answered only once its record is written:** a record that
  can't be written leaves the command unanswered, so it runs again.
- **Nothing read only in part:** the CI sweep reads every page of open pull
  requests; the CI gate fails rather than judge from part of a commit's
  checks (over 1,000 check runs or 100 statuses); `/apply comments` is
  refused when the review threads (over 100, or 100 comments in one) can't
  all be read; a ticket's history follows Jira's `isLast: false` — before,
  a page with no total ended the read.
- **Claude's output is used only as the schema says:** a change request's
  id must be digits and is never split into words.
- **Budgets allow for going over:** a pass stops only after the turn that
  crosses its budget (measured at 3.4× on a $0.05 budget), so admission adds
  `AGENT_HUB_PASS_OVERSHOOT_USD` ($1) per pass, and a pass with no cost
  report counts at its budget plus that. A default build is admitted on $23
  rather than $19; the $60 cap still fits.
- **Time limits:** the checkout has a limit of its own and the build job
  more headroom (270 minutes), so a slow step is reported, not lost to a job
  timeout; when GitHub stops a step during an install or the checks, the
  failure comment says which and what to lower.
- **Model defaults:** `claude-sonnet-5-5` replaces `claude-sonnet-5`
  (checked to resolve on Claude Code 2.1.285).
- **Tests:** which kind of test a change gets is written down (tests
  README, CONTRIBUTING, the pull request template); fuzz tests for the
  parsers at the trust boundaries (the state block, plan sections, ADF →
  Markdown, the plan's contract) from a fixed seed; the whole suite on macOS
  (Bash 3.2, a non-C locale) on main; sort order pinned in the test runner;
  every mock setting reset between scenario runs. A mutation check of 24
  security and gating guards found every one caught by a test.

**Updating:**
- Model defaults change to `claude-sonnet-5-5` (the work order's model, and
  the fallbacks and the build's fix model): set the `AGENT_HUB_*_MODEL`
  variables to keep the old ones.
- Runs are admitted on more ($1 per pass): a ticket near its cap stops one
  run sooner. Set `AGENT_HUB_PASS_OVERSHOOT_USD` to change it (`0` for none).
- A person's run for a ticket in Ready for Review or Approved now checks its
  pull request again (and can use Claude) instead of doing nothing.

## 2.18.0 — 2026-10-09

Security fixes from two reviews of 2.17.0 — this session's, and an
independent one run in a fresh session with no context. Several change what
honest use sees (listed under **Updating**).

- **Nothing an agent writes becomes a later pass's instructions.** The
  build snapshots the repository's guidance — `CLAUDE.md`, `AGENTS.md`,
  `.claude/` (its agents and skills) and the hub extensions — from the target
  branch's head when the run starts, before any agent, and every pass reads
  that: never the checkout the build agent edits, and never a pull request's
  head when reconciling. Before, the build agent could rewrite what the code
  review and the fix check were told (reproduced).
- **The code review and the fix check judge a clean copy** of exactly the
  commit — dependencies installed from the lockfile — never the checkout an
  agent left (whose ignored files could steer the tests they run), and their
  sandbox keeps them from writing to it. The fix pass's candidate is now
  committed in the Fix step, so its check judges that commit, and Verify fix
  checks it rather than making it.
- **Always a person's decision:** a change to `CLAUDE.md`, `AGENTS.md` or
  `.mcp.json` at any depth; package-manager configuration (`.npmrc`,
  `.yarnrc`, `.yarnrc.yml`, `.pnpmfile.cjs`, `pnpm-workspace.yaml`); a file
  whose mode changed; and any review finding in the `security` area, whatever
  its kind (never fixed automatically). `.claude/` and `.github/` stay
  refused.
- **Self-hosted runners start each job from an empty work folder,** so
  nothing an earlier job's agent left — `.git` hooks or config included —
  reaches a step with credentials. The build's first git command runs with
  every setting that could run a program turned off, and the hub's git copy
  keeps only an allow-listed config (no credential helpers, filters or
  hooks). A full clone each job: slower on a large repository, by design.
- **Commands and approvals:** an item command someone else edited isn't its
  author's, and is refused; `/apply comments` takes threads only from people
  GitHub says have write access (not every org member or read-only
  collaborator) and replies to each thread's first comment; with
  `AGENT_HUB_APPROVERS_GROUP` set, the plan's approver (build) and the work
  order's (plan stage) must be in it, and the work order's approver must be
  a person; a plan file a person uploaded is said so on the progress comment
  and the pull request. The build's `wake` input only takes the hub's values.
- **Smaller:** a dependency folder that is a link is refused; gate reasons
  (which can quote a package's licence) are escaped in the pull request
  description; the review prompt says what its diff really is; the sandbox
  check reports whether the agent's shell can write `.git/config`, `.github/`
  and `.claude/`.

**Updating:**
- New decision items may appear (the paths above, and changed file modes),
  and security findings are no longer fixed automatically.
- With `AGENT_HUB_APPROVERS_GROUP` set, approvals now need its members: put
  your approvers in it.
- An item command edited by someone else is refused: its author posts it
  again.
- On self-hosted runners every job clones afresh.

## 2.17.0 — 2026-10-08

Step 5, second part, second half (5b-2): `/apply` on the ticket. With it the
build stage's loop is complete: plan → build → review → CI → people's review
→ merge → Done.

- **`/apply R2 D1`, `/apply all`, `/apply comments`** (combinable): a fix of
  exactly the requested items, **through the fix pass's own path** — each
  item or review thread becomes one bounded finding for the fix pass (new
  instructions, `stages/build/apply/prompt.md`), then the fix check, the
  Verify-fix gate and a push that's never forced. Never a free-text
  instruction to the agent.
  - `all` is every open R item, never a decision; a decision only by its id.
  - `comments` is the pull request's unresolved review threads from people
    with write access (owner, member, collaborator), read when the run
    starts — the snapshot the fix is attributed to.
  - Each finding comes from the review the hub keeps on the ticket (a
    decision as the gates flagged it). A manual change, the "review didn't
    finish" decision, or an item whose finding the hub didn't keep can't be
    applied, and the reply says so.
- **Only on the head the hub last recorded and reviewed;** after anyone
  else's push it's refused — re-run the build first. Approvers only, item
  ids only, as for `/skip`. One `/apply` per run.
- **Afterwards:** the kept fix is the hub's (`kind: fix`, verified on its
  commit, with the `/apply` it answers); items the fix check found resolved
  are closed as *fixed*; each thread gets a reply (the commit, or "not
  applied" — Claude's words only on the ticket) and is resolved when
  applied; the `/apply` is answered on the ticket item by item. CI and the
  hand-off gate run again on the new SHA.
- **After a hand-off:** the pull request goes back to draft and the ticket
  stays in Ready for Review — the hub never moves a ticket back into
  Implementation Plan Approved, since its own move there wouldn't be an
  approval. The CI gate and hand-off now also run for a ticket in Ready for
  Review (or Approved) and mark the pull request ready again.
- Admitted on the fix pass and its check ($4).

**Updating:** Nothing more than 2.16.0's (the Build Command rule, the
approvers group, Browse users and groups).

## 2.16.1 — 2026-10-08

A fix found while building 5b-2.

- **The build's own edit no longer makes its approval look stale.** After it
  opens the pull request, the build writes the description's Pull Request
  section. The approval check counted every description change after the
  approval as "the work order was edited", so every later run on the ticket
  — reconciling, syncing, the CI gate and hand-off, item commands — would
  have sent the ticket back to be approved again. Changes by the automation
  account no longer count; a person's edit still does. (Not seen in the
  playground runs, which never reached a second run on a built ticket; the
  tests' recorded history had no such edit — it has one now.)

**Updating:** Nothing.

## 2.16.0 — 2026-10-08

Step 5, second part, first half (5b-1): `/skip` on the ticket, and what
every item command stands on.

- **The Build Command rule** (new, in Jira; docs/jira.md) wakes the build
  (`wake: command`) when a comment starts with `/skip` or `/apply`. The
  build reads the ticket's open commands itself, oldest first, and answers
  each one exactly once — marking it resolved with what was done, or why not.
- **Commenting never authorises a change:** the commenter must be in
  `AGENT_HUB_APPROVERS_GROUP` (new setting), checked by the hub from Jira —
  the service account needs Browse users and groups. Unset, or not
  checkable: nothing is done.
- **Only item ids,** and only items open in the pull request's current
  record. Anything else on the command's line refuses the whole command.
- **`/skip D1 R2`:** a decision is accepted, any other item skipped — no
  Claude. The description's items are rewritten, the pull request gets a
  comment, and who did what, when and on which head is kept on the ticket
  (an issue property, not the public pull request). The CI gate's last
  result is cleared, so the CI sweep runs it again: a pull request whose
  only blocker was a decision item is then handed off.
- **The latest review's findings are kept on the ticket** (the private
  `agent-hub-review` issue property, trimmed to Jira's 32 KB), written after
  each review — what `/skip` re-renders from, and `/apply` (5b-2) will act on.
- `/apply` is answered "not yet" until 5b-2.

**Updating:**
- Add the **Build Command** rule (docs/jira.md).
- Set `AGENT_HUB_APPROVERS_GROUP`, and give the Jira service account the
  global **Browse users and groups** permission.

## 2.15.0 — 2026-10-08

Step 5, first part (5a): a merged pull request moves its ticket to Done.

- **A ticket reaches Done only from a hub pull request the hub handed off
  and GitHub reports merged.** Merged after the hand-off → Done, and
  `needs-human` removed; if people pushed after the hand-off, still Done,
  with a note (the person who merged owns those commits). Merged without
  the hub's hand-off, or with a record that can't be trusted → not Done: a
  comment and `needs-human`, a person moves it. Closed without merging →
  never Done: a comment.
- **`agent-hub-pr-closed.yml`** (new): on `pull_request_target: closed`,
  for the hub's own pull requests, it only requests the build (`wake:
  closed`) — no checkout, no repository code, nothing from the pull request
  run; its branch name is only matched against a fixed pattern. The build
  (`stages/build/closed.sh`) re-reads GitHub and the ticket and does the
  rest. Nothing is built, no Claude.
- New settings: `AGENT_HUB_DONE_STATUS` (`Done`) and
  `AGENT_HUB_APPROVED_STATUS` (`Approved`, a status a person may move the
  ticket to before merging).
- Post-merge CI is after v1.

**Updating:** allow the Jira transitions **Ready for Review → Done** and
**Approved → Done** (or "Allow all statuses to transition to this one" on
Done). `agent-hub-pr-closed.yml` is installed by the update.

## 2.14.0 — 2026-10-08

PR 4's last part, second half (4d-2): CI fixes. A required check that fails
on the hub's pull request gets a fix through the fix pass's own path, up to
twice per hand-off; anything else goes to a person.

- **When:** every failed required check ran and failed (conclusion
  `failure`). Timed out, cancelled, needing action or erroring → a person:
  a code fix can't address them. At most `AGENT_HUB_BUILD_CI_FIX_ATTEMPTS`
  (2) since the last full review, so a person's commits, reviewed again,
  start a new count; past it, a person.
- **How:** the failed checks become the fix pass's findings, with what each
  reported — the check run's summary and, for a GitHub Actions job, the end
  of its log (the workflow's token, now with `actions: read`; to the agent
  only). From there it's the fix pass's path, no more and no less
  permissive: new instructions (`stages/build/ci-fix/prompt.md`: find the
  cause, never weaken a test), the fix check, Verify fix (no new refused
  file or decision item, no hard link, and every one of the repository's own
  checks the hub runs — its test, lint, typecheck and build scripts —
  passing in the sandbox on exactly that commit), the secret scan and a push
  that's never forced. Only failed **required** checks start a CI fix, and
  the hand-off still needs every currently required check green on the
  fix's own SHA: earlier results are never reused.
- **The record:** the attempt is written before any Claude runs, so a run
  that stops part-way isn't repeated by the sweep. A kept fix is a
  `kind: ci-fix` head, verified on exactly its commit, and the hand-off rule
  accepts it; CI runs again on it, and the sweep wakes the gate. A fix that
  wasn't kept changes nothing, and the pull request and ticket say why.
- **Admission:** the fix pass and its check only ($4 by default).
- Docs: build.md (CI fixes as built, the contracts, "Hand-off without CI"
  added to After v1), architecture.md (the CI fix pass), claude-usage.md,
  setup.md.

**Updating:** Nothing (the workflows' token now also reads CI jobs' logs:
`actions: read`).

## 2.13.0 — 2026-10-08

PR 4's last part, first half (4d-1): the CI gate and the hand-off. A build's
draft pull request is handed off to a person once every required check
passes on exactly the head the hub verified — and only then.

- **The CI gate.** When the hub's pull request is exactly as the hub left it,
  a run reads the target branch's required checks (branch protection and
  rulesets, with the app that must post each) and each one's latest result
  on exactly that head. Pending → nothing yet; past
  `AGENT_HUB_BUILD_CI_WAIT_MINUTES` (120) → a person; any failed → a person
  (CI fixes are 4d-2); nothing required on the target → a person (the hub
  can't tell when CI passed). Each result is reported once per head.
- **Read with the workflow's own token,** granted `checks: read` and
  `statuses: read` (fetch and apply steps only): a fine-grained token can't
  be given the Checks permission. Proven by a spike before building.
- **The hand-off rule** (`handoff_problems`), checked again just before
  anything is written: the record is trusted; the branch's head, the last
  head recorded and the commit whose checks passed are the same; every head
  after the last full review is the hub's fix or mechanical merge, each
  verified on exactly its own commit; the review finished; no decision item
  is open; the plan and approval still stand. Then the pull request is
  marked ready for review, the ticket moves to **Ready for Review** with
  `needs-human`, and both get a comment. Green CI never makes a person's
  unreviewed commit eligible.
- **Each head in the record says what it is:** `kind` (`build`, `fix`,
  `sync`, `people`), `verified: {head, by}` for the hub's, and `at`. The
  first build now records the build's commit and a kept fix separately, so
  the reviewed commit is always listed. A record from before 2.13.0 is never
  handed off (a person reviews it).
- **The CI sweep** (`agent-hub-ci-sweep.yml`): every 10 minutes, with no
  agent, it requests the build (`wake: ci`) for the hub's draft pull requests
  whose required checks have finished on the head the hub recorded, or
  waited too long, and whose result isn't handled yet. It skips paused,
  superseded and people-pushed pull requests. A run it requests does only
  the CI gate: anything else is left, quietly, for a run a person starts.
  Runs only while `AGENT_HUB_BUILD_PREVIEW` is true.
- Docs: build.md (CI gate and hand-off as built, the contracts marked
  built), setup.md, jira.md, architecture.md.

**Updating:**
- The target branch must **require your CI's checks** (branch protection or
  a ruleset), or nothing is ever handed off.
- Allow the Jira transition **Implementation Plan Approved → Ready for
  Review** (or set `AGENT_HUB_READY_FOR_REVIEW_STATUS`).
- The new workflow `agent-hub-ci-sweep.yml` is installed by the update.
- Hub pull requests opened before 2.13.0 aren't handed off: review them by
  hand.

## 2.12.1 — 2026-10-08

Settles the v1 scope after an external review of the plan: one queue per
ticket now, the rest of the hardening listed for after v1.

- **One queue per ticket, for every stage.** The work-order and plan
  workflows now share the build's concurrency group
  (`agent-hub-<repo>-<ticket>`): nothing for a ticket runs in parallel, so
  no two runs update its state or its Claude usage record at once (the
  record is a Jira issue property, which can't be updated atomically). A
  newer work-order or plan request **waits** for a run in progress instead of
  cancelling it, then acts on the ticket as it finds it — one whose ticket
  moved on does nothing.
- **A queued duplicate costs nothing.** A revision with nothing left to do
  now ends before Claude ("no change needed"): in the plan stage, one with no
  open `/revise` comments; in the work-order stage, one with no open
  `/revise` comments whose work order was already written after the ticket
  last entered Work Order (a ticket resubmitted through Intake with an edited
  request is still revised, as before). So several `/revise` comments in a
  row, two quick moves to Work Order Approved or two quick saves in Intake
  run Claude only for what's actually new.
- **build.md:** the loops table now says what was decided for 4c (a merge
  conflict goes to a person; semantic drift is reviewed again on the merged
  commit), and a new **After v1** section lists the deferred hardening and
  what won't be built at all.
- architecture.md, implementation-plan.md and jira.md describe the queue;
  a cancelled run is now one a person cancelled.

**Updating:** Nothing. (Runs already in progress when you update finish
under the old groups.)

## 2.12.0 — 2026-10-08

PR 4's third part, second half (4c-2): an existing pull request is synced
with a target branch that moved, against the contracts written in 2.10.2.

- **Sync:** when the target branch has moved past where the hub's open pull
  request last met it, a run merges it in — as the machine user, a merge
  commit, never a rebase or a force-push — in the fetch step, before
  anything reads the code or Claude runs. A move is now a reason to run on
  its own, even when nobody pushed.
- **Drift, from paths alone:**
  - **mechanical** — the target changed no file the pull request or its
    plan touch, and no drift-sensitive path: the merge is verified and the
    earlier review still applies. No Claude runs, so the run isn't admitted
    against the ticket's caps or counted;
  - **semantic** — otherwise: the merge is verified and the whole change is
    reviewed again on the merged commit, and fixed once where allowed;
  - **a conflict** — nothing is pushed; the conflicting files go on the pull
    request and the ticket, with `needs-human`, and a person merges the
    target (outcome blocked).
  Drift-sensitive paths (`BUILD_DRIFT_SENSITIVE`, gates.sh): the gates'
  sensitive kinds plus compiler and build configuration, shared types and
  the hub-managed paths.
- **Provenance:** the state block records the merge as the hub's, with its
  target and drift; the hand-off rule (4d) accepts a mechanical sync after
  the last full review. The gates and the review compare with the target's
  new head, so they see the pull request's own changes only.
- A push the build token can't make because the merge brings in workflow
  changes says so (the token has no Workflows permission, by design): a
  person merges the target.
- Docs: build.md (Sync with the target branch, contracts marked built, the
  hand-off rule), claude-usage.md.

**Updating:** Nothing.

## 2.11.0 — 2026-10-08

PR 4's third part, first half (4c-1): a build whose pull request already
exists reconciles it instead of stopping, against the contracts written in
2.10.2.

- **Reconcile, not stop:** when the hub's pull request for the ticket is
  open, a build run works out what it needs:
  - the `agent-hub-paused` label (`AGENT_HUB_BUILD_PAUSED_LABEL`) → nothing;
  - a record (the state block) someone else edited, or a branch that no
    longer builds on the hub's last push → stop for a person;
  - built from an earlier plan than the one approved now → **superseded**:
    a comment on the pull request and the ticket, `needs-human`, a person
    decides (closing it builds the new plan); nothing is rebuilt;
  - nobody pushed since the hub → nothing to do;
  - **people pushed** → their head is verified, the whole change reviewed
    again and fixed once where the review allows, under every candidate rule
    the build has; a kept fix is pushed without force and rejected if anyone
    pushed meanwhile. No build pass, so a reconcile run is admitted on the
    review, fix and fix check ($9 by default).
- **The pull request stays the record:** the state block gains the next
  generation and each head's provenance (the hub, or people); the
  description's hub-managed status section — the automated review and the
  items — is rewritten in place between its markers, with the rest of the
  description kept and the edit history checked afterwards; a comment on
  the pull request says what was re-checked; the ticket gets the full
  report. Items carry over by the contracts: a gate decision still there
  keeps its id, the previous review's open items close, ids are never
  reused.
- **Verify fix compares refused files with the reviewed commit,** as it
  does decision items: a person's commit on an existing pull request may
  already have one; only a fix that adds one is dropped.
- Docs: build.md (status, branch lifecycle, contracts marked built,
  structure), setup.md, claude-usage.md.

**Updating:** nothing to do. A ticket whose pull request is open no longer
needs it closed to run a build: the run reconciles it. Syncing with a moved
target branch (4c-2) comes next.

## 2.10.3 — 2026-10-08

Tidy-ups from the first real build on 2.10.x (the playground's
AGENTHUB-58: build, review, ticket caps and a budget-blocked run, all as
designed) and the build eval's first run (passed: the review found the
planted problem, the fix was kept and confirmed, $0.38).

- **git works for the agent's commands** in the sandbox: they get
  `GIT_CONFIG_GLOBAL=/dev/null`, so git no longer fails trying to read the
  user's `~/.gitconfig`, which the sandbox (rightly) blocks. The build agent
  had worked around it, and said so in its testing instructions.
- **Money is shown as money everywhere:** `$19.20`, not `$19.2`; the cost
  line reads `$0.37`, not `0.37 USD` (one `usd` helper in `lib/adf.jq`).
- **The cost line's time covers every pass** — the build, the review, the fix
  pass and its check — not just the build pass.
- **The over-cap log line says why, in numbers:** "a run of this stage can
  cost up to $19.00, and $18.83 is left of its $19.20 cap ($0.37 used)", or
  the runs used — instead of only listing the caps.
- The build eval's results table rounds its cost.

**Updating:** nothing to do.

## 2.10.2 — 2026-10-07

The build stage's contracts, written down before 4c and 4d are built, and
faster step start-up.

- **Contracts** (build-design.md, "Contracts"): the rules every part of the build,
  built or planned, must keep — fail before Claude; agents propose, gates
  decide, only verified candidates are published; the publication policy;
  people merge; budget as three limits (the cap, run admission, each pass's
  maximum); **freshness**, separating what a pass works from from what must
  hold when anything is published, per pass; **candidate eligibility** for
  every automatic change (the build, the fix pass and, in 4d, CI fixes
  through the same path); review coverage and the hand-off provenance rule;
  CI semantics case by case; decision-item ownership; `/apply` freshness;
  and the failure classes. Each is marked built (with its version) or
  planned (4c, 4d, step 5); 4c, 4d and step 5 are reviewed against them.
- **Settings without subshells:** every setting was read in a subshell of
  its own, and a stage's settings ran `tr` each time, which was most of a
  step's start-up on macOS. Settings are now assigned directly
  (`setting_into`, `stage_setting_into`), and a stage's variable prefix is
  worked out once. Loading the hub for a step takes 0.1–0.2 s instead of
  0.4–0.5 s, so every run starts its steps faster and the test suite runs
  in less time and with less load.
- The sandbox check after 2.10.1 passed every item (31 of 31, Claude Code
  2.1.285, macOS): Claude Code's sandbox itself stops a hard link to a file
  outside the repository, so the hub's own check is a second line.

**Updating:** nothing to do. A repository's own extensions are unaffected;
anything that sourced `lib/settings.sh` and called `setting` or
`stage_setting` still can (both remain).

## 2.10.1 — 2026-10-07

Fixes from the review after 4b, each validated by reproducing it first (and
reviewed externally), plus whole-run budget admission.

- **Hard links can't slip through the fix pass** (was: a hard link named
  like an option, `-quit`, to a file outside the repository was committed
  and pushed — reproduced). Verify and Verify fix now share one check,
  which gives file names to `stat` only after `--`; nothing passes file
  names to `find`. A test proves the exact case refused in both paths, and
  that there's only the one check.
- **An automatic fix never puts a person's decision into a pushable commit**
  (was: a fix that also changed a must-not-touch file was kept and pushed,
  with a decision item — reproduced). Verify fix keeps a fix only if,
  compared with the reviewed commit, it adds no refused file and no decision
  item (out of scope, must-not-touch, a dependency file, the size limits),
  and every check passes; otherwise the whole candidate is discarded — the
  commit, its gate results, its checks' copy and output — and the reviewed
  commit is pushed exactly as it was. Tested case by case, including a good
  fix mixed with a bad change.
- **The code review and fix pass work in repositories with extensions**
  (was: the extensions' log line went into the pass's result, so with any
  `build/` extension every review came back "didn't finish" and the fix pass
  never ran). Found by the new pass-table test.
- **Each pass gets the repository's guidance it needs:** `guidance.md` for
  every pass that writes or judges code (the code review, fix pass and fix
  check now too), `review.md` for the review-type passes only. One table,
  *Agent passes* in architecture.md, says which pass gets what; a test
  checks every build pass's real prompt and every setting against it.
- **Budget admission for the whole run:** a run may use Claude only if the
  ticket's spend so far plus the most the run can cost — the sum of every
  pass's configured maximum ($19 for a build: build, review, fix, fix
  check; $4 for a work order, $10 for a plan, less when revising) — fits
  within the cap; otherwise it's blocked, before Claude, as at the cap. A
  cap smaller than one run's maximum is a settings error. With each pass's
  own `--max-budget-usd`, that's three limits in a row.
- **`continue-on-error` is pinned:** exactly the build's Review, Fix and
  Verify fix steps may fail without failing the job (a test reads the
  workflows by step id); the workflow-shape snapshot now records it and
  every time limit.
- **The evals workflow installs the Linux sandbox tools** on GitHub-hosted
  runners, as the stage workflow does, so the build eval can run there
  (without them Claude Code refuses to run — the sandbox is never optional).
- **The sandbox check** also tries to hard-link a file from outside the
  repository into it.
- **Tests:** unique canaries in every Claude-written review and fix field
  never reach a public repository's pull request or commits, whether the
  fix was kept, dropped or failed; every scenario's snapshot now records its
  outcome, which replaces the two slowest tests (≈150 s each).
- **Docs:** the review and fix pass are no longer described as future work
  (build.md, the README, setup.md, runners.md, extending.md, the build
  stage's comments); setup.md lists every step's time limit; evals.md says
  what the build eval covers.

**Updating:** nothing to do. A ticket now needs room for a whole run's
maximum under its cap before a run starts (by default $60 holds three
builds' maximums); raise `AGENT_HUB_TICKET_MAX_COST_USD` if that stops
runs too early.

## 2.10.0 — 2026-10-07

PR 4's second part, completed (4b-2): the review's fix-eligible findings are
fixed once, each fix checked, and the fix kept only if the build still
passes.

- **A Fix step** after the review, only when it found fix-eligible findings:
  the fix pass (the build profile; Sonnet, `AGENT_HUB_BUILD_FIX_MODEL`,
  capped at $3) fixes exactly those findings, once; then a **fix check** — a
  fresh read-only session ($1) — judges each fix resolved or not from
  exactly the diff it made, and reports any new concern it raised. No second
  loop.
- **A Verify fix step** (no agent) commits the fix on top of the reviewed
  commit and keeps it only if the gates refuse nothing and the repository's
  checks pass on it; otherwise the reviewed commit is pushed as it was. A
  fix the check couldn't judge, or one that changed nothing, isn't kept.
  Both steps continue on error, and Apply drops a fix that never finished
  verifying — the fix pass can't cost the build or push an unchecked
  commit.
- **On the pull request and ticket:** resolved findings are listed as fixed;
  unresolved ones, and any when no fix was kept, stay open; the fix check's
  new concerns become decision or review items by the same policy. The
  ticket's report has each fix, its check and the concerns; the cost line
  covers the build, review and fixes.
- **The build's first eval** (`tests/build/evals`, run by hand: Actions →
  Agent hub: Evals → build): a build that misses an acceptance criterion
  its tests don't cover — the review should find it, the fix pass fix it and
  the fix check confirm it. Only the review and fix passes use Claude (about
  $2–5).
- The build workflow's job limit is 240 minutes (the Fix step's 40 and
  Verify fix's 30 added).
- Tests: the scenario harness's own `skip` helper no longer replaces bats'
  `skip` after a scenario runs (renamed `skip_step`).

**Updating:** nothing to do. Builds whose review finds serious problems now
cost a fix pass too (typically $0.5–2.5).

## 2.9.0 — 2026-10-07

PR 4's second part, first half (4b-1): an automated code review of every
build. Its findings become the pull request's items; nothing is changed
automatically yet (the fix pass is 4b-2, 2.10.0).

- **A new Review step** after Verify (code stages only): a fresh Claude
  session with the review profile — commands in the sandbox, nothing written
  to the repository — reviews the build's commit against the plan. It gets
  the ticket and plan, the hub's own check results and the diff the hub
  computed from the git metadata copied before the agent ran. Opus on the
  shared review model setting, capped at $5
  (`AGENT_HUB_BUILD_REVIEW_MAX_BUDGET_USD`); 30 minutes. Its cost counts
  towards the ticket's caps.
- **The hub sorts the findings, not the agent** (`stages/build/review/policy.json`):
  dependencies, security-sensitive areas, workflows, licences, scope and
  anything beyond the plan are decision items (`D`) for a person, whatever
  the severity; serious correctness, test, docs, performance and structure
  findings within the plan are fix-eligible (review items marked so until
  2.10.0); the rest are review items (`R`).
- **On the pull request:** an *Automated review* section and every item
  under *Items for a person*. A public repository's shows only each
  finding's kind, severity and area unless ticket content may be published;
  the state block never holds a finding's text. The ticket's report gets
  each finding in full, with its evidence and suggestion.
- **A review never costs the build:** the step continues on error, and a
  review that returns nothing usable, reaches its budget, fails or times
  out, or names a file outside the repository is a decision item on the
  draft instead.
- **Runner interface:** `agent_pass`, a further independent pass with the
  profile, model and budget the stage chooses. The *Agent behaviour changed*
  notice now covers a stage's `policy.json` too.
- The build workflow's job limit is 170 minutes (was 140) to fit the review.

**Updating:** nothing to do. The build now costs a review on top of each
build (typically $1.5–4, capped at $5).

## 2.8.1 — 2026-10-07

The rest of PR 4's prerequisites (4a): the review profile proven read-only,
and GitHub's edit-history format recorded and handled.

- **The review profile can't write the repository.** Its sandbox now denies
  the repository outright (`denyWrite`), not only by leaving it out of the
  writable folders, since Claude Code otherwise lets commands write the
  working directory. The sandbox check has a third session for it: a shell
  redirect, `touch`, a child process and the file tools all failed to write
  the repository, while reading it and writing the temp folder worked (run on
  Claude Code 2.1.285, macOS). The check now costs about $0.30.
- **GitHub's edit history, recorded:** real responses from a scratch pull
  request are now test fixtures (`tests/shared/fixtures/github-edit-history`).
  They confirm each edit's `diff` is the whole description after it, as the
  hub and its mock assumed. They also showed that a revision deleted in
  GitHub's web page keeps its entry, its text replaced by `deleted`:
  `gh_pr_body_versions` now marks it (`deleted`, `deleted_by`), and
  `state_trusted` refuses such a history, naming who deleted it (it was
  refused before, with a misleading reason). The newest version must also
  equal the description GitHub returns.
- **The sandbox check's agents item** names the agent as the plugin lists it
  (`repository:check-expert`): on 2.1.285 Claude asked a generic subagent
  instead, although the repository's agent was loaded.
- **Less duplication:** the build's cost line and dependency summary are
  written once (`stages/build/wording.jq`) for both the pull request and the
  ticket report, and the pull request template uses the shared `unstop` and
  `plural`; a duplicated test helper moved to the shared helpers.
- Docs: Dependabot's scope in build.md's last two mentions; build.md's
  prerequisites marked done.

**Updating:** nothing to do.

## 2.8.0 — 2026-10-07

The first of PR 4's prerequisites (4a): per-ticket caps on Claude usage,
across every stage. The rest of 4a follows in the next release.

- **Every ticket has two caps**, across every stage and run — retries,
  revisions and resubmissions included: 10 runs that used Claude
  (`AGENT_HUB_TICKET_MAX_RUNS`) and $60 API-equivalent
  (`AGENT_HUB_TICKET_MAX_COST_USD`). Both provisional, like the build's
  other caps.
- **Counted on the ticket:** after each run that used Claude, a new step
  (*Record Claude usage*, which runs whatever happened) adds the run and its
  cost to a record the hub keeps on the ticket — in Jira an issue property,
  which Jira's screens don't show — with each stage's share. A pass with no
  cost report (cut off by a time limit, or cancelled) counts at its whole
  budget, marked estimated. The run summary ends with the ticket's total.
- **Checked before Claude:** a run for a ticket at either cap stops before
  its progress comment, adds `agent-hub-over-cap` and `needs-human`, and
  posts a ⛔ comment with the totals and how to go on (outcome *blocked*,
  now one of every stage's outcomes). A person lifts the caps by removing
  the label; the next run allows one more cap's worth. A record or label
  that can't be read stops the run rather than lifting a cap.
- Docs: claude-usage.md ("Per-ticket caps"), setup.md (the three
  variables), jira.md (the label; the permission it needs, which the
  automation account already has), architecture.md (the tracker interface's
  new functions), build.md (the cap decision and PR 4's four parts).

**Updating:** nothing to do — existing tickets start counting from their
next run. To change a cap, set the variables. The automation account needs
Edit work items, which it already has.

## 2.7.3 — 2026-10-07

Jira and GitHub calls survive brief outages and rate limits, and the two
requests that can't safely be sent twice check what happened before trying
again — so a lost reply after Claude has done the work no longer means a
failed run or a pushed branch with no pull request.

- **Every Jira and GitHub API call** has a connection time limit (10s) and an
  overall one (120s), through one shared function (`lib/http.sh`).
- **Retries, only where they're safe:** a call the server never got (no
  connection) or turned away (429, GitHub's rate limits) is tried again
  whatever it is; one that failed after it was sent (500, 502, 503, 504, a
  timeout, a broken connection) only if repeating it can't do anything twice
  — reads, updates, deletes, adding a label, GitHub's GraphQL queries.
  Three attempts at most, waiting as the server asks (Retry-After or the
  rate-limit reset) or 2s then 4s; a server asking for more than 60s ends
  the retries. Each retry is a warning in the log, naming only the service,
  method and status.
- **Opening the pull request and moving the ticket check before trying
  again:** after a failure, the build looks for an open pull request from
  its branch into the target (GitHub never opens two for the same branches),
  and a move checks the ticket's status (Jira refuses a move that's no
  longer available). Found done, the run carries on; not done, it tries
  once more.
- **Not repeated:** a comment or attachment that may have been posted, since
  a second copy can't be reliably told apart; that failure still fails the
  run (architecture.md, "Known gaps").
- The secret scanner's download has time limits and retries too.

**Updating:** nothing to do.

## 2.7.2 — 2026-10-07

Fixes from the full review before PR 4 (the lower-risk group; retries and
reconciliation for Jira and GitHub calls follow in 2.7.3), and the decisions
that review asked for, recorded.

- **A failure's retry advice fits the reason.** Shared failure messages no
  longer tell people to comment `/revise` (the build has no `/revise`); each
  says what went wrong, and the comment's "To try again" line says how, for
  that stage and that reason. A build stopped by an earlier pull request or
  branch now says exactly what to close, delete or approve again. A test
  keeps `/revise` out of shared messages.
- **Settings checked before Claude:** a stage's Claude budget that isn't a
  positive number of dollars, or an `AGENT_HUB_TRACKER` / runner that isn't
  one of the hub's, stops the run by name, before anything is loaded or
  Claude is used.
- **A shared runner user is flagged:** a self-hosted run warns when the
  runner's user also runs Claude Code outside the runner, since the agent's
  sandboxed commands then share Claude Code's temp folder with that person's
  sessions. A dedicated runner user (or machine, or GitHub-hosted runners) is
  now a stated blocker before the build's preview gate comes off. The
  sandbox check also removes the Claude Code project folder it creates.
- **Dependency folders checked at plan time:** a plan whose dependency
  changes name a folder that isn't an npm project with a lockfile (or is the
  hub's) is sent back by the plan stage, before anyone approves it.
- **Plan paths through chains of links** are followed link by link (no
  `realpath`, which older macOS lacks).
- **The work order's group headings are one list**, used both to render it
  and to recognise an existing work order.
- **CI:** the stages' scenarios also run on macOS with its own Bash 3.2, as
  part of **Agent hub: Test**; every job has a time limit (and a test keeps
  it so).
- **Docs:** runners.md lists every tool a runner needs, per stage; stale
  status text fixed (the build's status, the stage header, update.sh's
  example version and extensions note, the actions-pinning note, the
  sandbox-check workflow in the README and architecture); Dependabot noted as
  the hub repository's own; CONTRIBUTING.md says which tests need the
  network and what to do when a download fails. build.md records that people
  merge on GitHub and the hub only observes the merge (automating the steps
  after a person's approval is a later item), a per-ticket spend cap as a
  PR 4 prerequisite; github-projects.md says why the intake is a form.

The hub's own repository also gets a `LICENSE` (all rights reserved),
`SECURITY.md` and `CODEOWNERS`; none of them are hub files, so updating
doesn't install them.

**Updating:** nothing to do. A self-hosted runner that warns about a shared
user should get its own user before real tickets (docs/runners.md, "Before
running the build on real tickets").

## 2.7.1 — 2026-10-07

Both ways of reaching Claude — a self-hosted runner logged in to a Claude
account, or a Claude API key — built out, recorded on every run, and
checkable on any runner. The API setup is built and tested without a real
key; the steps to verify it with one are in docs/runners.md.

- **Every run says how it reached Claude:** "Claude access: a logged-in
  Claude account (pro)", "an API key", or another provider (Bedrock,
  Vertex), in the run log, the run summary's new *Claude access* column, and
  the build's pull request and ticket. It comes from `claude auth status`
  (no Claude usage); the account's email and organisation, which that also
  gives, are never recorded. A runner with both a key and a login gets a
  warning (which one Claude Code uses then isn't verified yet), as does one
  with neither.
- **The build's cost line says what the cost means:** API-equivalent and
  counted against the plan's usage limits, or billed to the API key.
- **Agent hub: Sandbox check** (a new manual workflow, `use-claude` to run):
  the sandbox check on the runner `AGENT_HUB_RUNS_ON` names, with its access
  to Claude — the only way to check a GitHub-hosted runner. Kill switch,
  the evals' reviewer environment, and the key only in the step that uses it.
- **The sandbox check reports the agent's commands' temp folder**, and checks
  it's outside the repository and the home folder. A run on 2.7.1 showed it's
  Claude Code's per-user folder (`/tmp/claude-<uid>`), shared by the jobs run
  as that user, whatever the hub sets — documented in runners.md, with srt's
  `/tmp/claude`, as a reason for runners that start fresh for each job. (The
  hub's own sandbox uses the job's temp folder: 2.7.0.)
- **The sandbox check's skills item** accepts Claude's answer when it adds a
  note to the planted word (it failed on an exact match while the skill had
  loaded).
- **Docs:** runners.md describes both setups side by side, how to switch,
  what each run records, and what's not yet verified for the API — and no
  longer says a login takes precedence over a key, which wasn't verified.

**Updating:** nothing to do. To check a runner's sandbox, or a GitHub-hosted
runner with the API: Actions → Agent hub: Sandbox check.

## 2.7.0 — 2026-10-06

The dependency step: a plan can add, update or remove npm packages, and the
hub applies exactly those itself, before the agent starts, with the
supply-chain checks dependency bots use. The second part of 3d.

- **Plans list their dependency changes exactly.** The implementation plan's
  Scope & Governance section has a new **Dependency changes** list: for each
  npm package, its folder, the version range, runtime or dev, and add,
  update or remove. The build reads it back strictly; anything it couldn't
  apply exactly (a URL, git or file reference, a path out of the repository)
  is a problem, and nothing is built.
- **Applied before the agent**, so it writes code and runs tests with them
  installed, and never reaches a registry: package.json gets exactly the
  plan's ranges (npm on its own would rewrite `7.x` as `^7.0.0`), npm
  resolves the lockfile without install scripts, then the sandboxed install
  installs them (new packages' install scripts get its limits).
- **Supply-chain policy**, check by check ([build.md](docs/workflows/build.md#dependencies-planned-changes-only)):
  - **release age:** every version the lockfile adds or changes, direct and
    transitive, published on or before now − 3 × 24 hours by the registry's
    own times (`AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS`, `0` for none) — npm
    chooses within it, and the hub checks every new version itself;
  - **source:** every new version from the npm registry (not git or a URL);
  - **determinism:** the manifest and lockfile are recorded once resolved;
    the install must leave them unchanged, and the gates pass only those;
  - **signatures:** every installed package's must verify, and provenance
    wherever a package publishes it; a package without provenance is
    allowed and counted (most publish none);
  - **vulnerabilities:** compared advisory by advisory, before and after: a
    new high or critical one blocks, a new lower one is a decision item; an
    audit that can't run blocks;
  - **licences:** every new version's must be on an allowed list
    (`AGENT_HUB_BUILD_ALLOWED_LICENSES`, permissive licences by default),
    otherwise a decision item; so is a changed lockfile format.
  Each was checked against npm's real behaviour and the code after an
  external review, which this version follows; build.md records what changed
  and what didn't, and why.
- **The gates pass the manifest and lockfile only byte for byte** as the hub
  produced them (not counted in the size limits); the agent changing them
  is a decision item.
- **On the pull request and the ticket:** each change with the version it
  resolved to and its licence, and the lockfile's added, changed and removed
  packages and vulnerabilities before and after.
- **Stops before Claude** when a change can't be applied, or shown safe,
  exactly — every change checked before any is applied.
- **npm only:** a pnpm or Yarn project's dependency changes stop the build,
  saying so (their release-age settings are too new to rely on); a plan
  from before this version keeps its dependency changes as decision items.
- **Subfolder projects are installed:** the install now covers the plan's
  dependency folders and the folders `build/checks.json` lists under its new
  `install` key, not only the repository root.
- **Fixed:** a hub sandbox policy for npm's signature check (`verify`): the
  registries and Sigstore's trust metadata (`tuf-repo-cdn.sigstore.dev`),
  found by the new real-registry probes.
- **Fixed: the hub's sandboxed commands' temp folder.** srt replaces the
  command's `TMPDIR` with its own, a shared `/tmp/claude`, unless
  `CLAUDE_CODE_TMPDIR` is set: the commands wrote temp files there rather
  than in the job's temp folder, and on a runner without that folder (CI's
  Linux) npm's signature check failed. Both now point at the job's temp
  folder. (srt itself keeps `/tmp/claude` writable; see runners.md.)
- **This repository:** the playground has a `package-lock.json` (so plans can
  add packages to it), and `build/checks.json` installs it for its checks.
- **Evals:** a plan case, `npm-dependency`, checks the plan lists exactly the
  package a work order needs; every other case checks it lists none. The
  `stale-work-order` case now describes a deploy workflow: the build
  workflow it described stopped being missing when the build stage arrived
  (2.5.0), so the model rightly planned against the real one.
- **Tests:** the contract's new list, the gates, every dependency path with
  a stand-in npm, and probes against the real npm registry in the real
  sandbox (`tests/build/dependencies.bats`).

**Updating:**

1. The implementation-plan stage's prompt and schema changed: CI posts the
   **Agent behaviour changed** notice. Run the plan evals before relying on
   it (Actions → Agent hub: Evals, stage `implementation-plan`; it uses
   Claude).
2. A self-hosted runner that limits outgoing traffic needs
   `tuf-repo-cdn.sigstore.dev` as well as the npm registry.
3. A repository with a subfolder project whose checks need its
   dependencies: add `"install": ["<folder>"]` to `build/checks.json`.

## 2.6.3 — 2026-10-06

Less Claude spend on builds that can't succeed, the runner's caches checked
on every use, and clearer wording. The first part of 3d, after a review of
its plan against how dependency bots, npm and CI systems handle the same
jobs (docs/workflows/build-design.md, "Building it").

- **Baseline before Claude.** The repository's checks now also run on the
  base commit before the agent. If one already fails there, the build would
  fail it too, so nothing is built and Claude isn't used; the output is on
  the ticket. A failing check runs once more first, in case it's flaky.
  `AGENT_HUB_BUILD_BASELINE`: `stop` (default), `warn` (build anyway, for a
  plan that fixes a failing check) or `off`
  ([build.md](docs/workflows/build.md#baseline)).
- **The runner's caches are checked on every use.** Other jobs on a
  self-hosted runner can write to its tool cache, so the hub no longer
  trusts anything there unchecked. The sandbox runtime (`srt`) was
  installed once into the tool cache and reused as it was; it's now
  installed for each job from npm's download cache, which npm checks
  against the hub's lockfile on every install (a changed package is
  downloaded again). gitleaks' release archive is now kept in the tool
  cache, rather than downloaded every job, and checked against its pinned
  checksum every time before it's unpacked.
- **Fixed: the sandbox on Linux runners.** On Linux, srt runs its own
  seccomp helper inside the sandbox, so the helper must be readable there.
  srt now lives in the job's temp folder, which on GitHub-hosted runners
  and most self-hosted ones is in the home folder the sandbox denies, so the
  helper folder (and nothing else of srt's) is made readable. Self-hosted
  Linux runners were already affected in 2.6.2, whose tool cache is in the
  home folder too; macOS needs no helper.
- **Wording:** an expected result that ends in a full stop doesn't get a
  second one; the pull request says "1 file" and "2 files" (not "file(s)"),
  and "verified manually" or "verified by a new test"; the build's summary,
  which goes on the ticket and the pull request, is written impersonally
  ("Adds…", not "I added…").
- **Design, 3d-2 (the dependency step):** dependencies resolved by the hub
  before the agent, from an exact list in the plan, with a minimum release
  age, provenance and licence checks; reconciliation of an existing pull
  request moved to PR 4 ([build.md](docs/workflows/build-design.md#building-it)).

**Updating:** nothing to do. A repository whose checks can't pass in the
sandbox (they need the network or a service) now finds out before Claude
runs: list the checks that can run offline in `build/checks.json`, or set
`AGENT_HUB_BUILD_BASELINE` to `off`.

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
  reviewer ([build.md](docs/workflows/build-design.md#building-it)).
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
