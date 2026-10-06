# Build (`agent-hub-build.yml`) — design

> **Status: being built** ([Building it](#building-it)). **Not enabled for
> real tickets:** it runs only with `AGENT_HUB_BUILD_PREVIEW=true`, for
> development, until the review and CI gate (PR 4). Since 2.5.0 an approved
> plan becomes a **draft pull request** — start, validate, build, gates,
> secret scan, push — that a person reviews. Since 2.6.0 the build runs in a
> known environment — the Node version the repository declares, its
> dependencies installed from the lockfile — and the hub runs the
> repository's checks on the build's commit itself, pushing nothing if one
> fails ([Toolchain](#toolchain), [Install](#install), [Verify](#verify)). The
> dependency step, the review, CI gate and hand-off come in later versions.
> The agreed plan, reviewed externally three times. Items marked
> *provisional* are defaults to revisit after the first full pipeline test.
> When the stage is complete, this page becomes its workflow doc (in the
> [TEMPLATE](TEMPLATE.md) layout).

Turns an approved implementation plan into a pull request: the code and its
verification, reviewed by an agent, passing CI, ready for people to review
and merge. It's the first stage that changes code, so it's built around three
ideas: **bounded automation** (every automatic loop has a cap, then a
person), **deterministic gates** (tests, CI and hard checks decide, not the
agent's opinion), and **human ownership** (people approve the plan, review
the code and merge it; the agent never can).

| Artifact | Answers | Owner |
|---|---|---|
| Work order | What and why | Requester, approved by a person |
| Implementation plan | How | Agent, approved by a person |
| Change set | Exactly what was approved for this build | Recorded by the hub when the build starts |
| Pull request | The code, its verification and the evidence | Agent writes it; people review and merge |

The rules every stage keeps — the state machine, who is authoritative for
what, trust levels and the invariants — are in
[architecture.md](../architecture.md#the-pipeline-as-a-state-machine).

## Goals

1. An approved plan becomes a draft pull request with code that implements
   it, on a branch the hub owns.
2. **Every behaviour change has meaningful verification, and everything
   passes.** Automated tests wherever the repository has a suitable test
   surface; otherwise the reason automation doesn't fit and the exact manual
   verification are recorded — no filler tests. The repository's tests, lint,
   type checks and build pass in the sandbox, then in CI.
3. **Thorough, accurate manual testing instructions**, each tied to an
   acceptance criterion; the agent runs the steps it safely can in a simple
   way and marks each as checked or needing a person.
4. An independent, read-only review; serious findings within the approved
   plan fixed once and the fixes checked; the rest handed to people.
5. The ticket moves to Ready for Review only when the pull request is
   hand-off eligible.
6. People drive every further change (`/apply`, `/revise`) and merge under
   branch protection; the hub follows the pull request to Done.
7. Bounded, observable cost.
8. Safe under concurrency, stale state, dropped or duplicate events, agent
   mistakes, CI instability and human intervention.

## The flow

```
Implementation Plan Approved                                     [human: plan approval]
  │
  0 START — kill switch · approval still valid for this exact plan · reconcile
  │         outstanding work · clean checkout · baseline · dependencies installed
  1 VALIDATE ── blocking questions ──▶ into the plan; ticket → Implementation Plan
  │                                    (needs-clarification)      [human: answer, re-approve]
  2 BUILD — code, tests, decision log; gates
  │   (planned dependency change → DEPENDENCIES: hub-run resolve and install, gates again)
  3 VERIFY — repository tests, lint, type checks, build; simple manual-step checks
  4 REVIEW — read-only, independent; findings have severity and kind
  5 FIX — eligible findings, one pass → FIX CHECK → VERIFY again
  6 SYNC — up to date with the target branch (mechanical / semantic drift)
  7 PUSH — gates, secret scan, stale checks; draft pull request
  8 CI GATE — required checks for GitHub's current evaluation commit; failures classified;
  │           code/test failures: 2 CI-fix attempts
  9 HAND-OFF — eligible → PR ready; ticket → Ready for Review   [human: code review]
                │
                ├── review items (R, M, D, C) ──/apply──▶ a revision (steps 0–9)
                └── approve + merge (human, under branch protection)  [human: merge]
                      ▼
                    POST-MERGE CHECK ──▶ Done
```

Steps 0–7 run in one job; every agent pass is a separate Claude session.
Step 8 is event-driven (no job waits on CI); step 9 runs when CI is green. The
ticket isn't touched until step 9, apart from the progress comment and
send-backs.

Every run ends in one of the shared outcomes
([architecture.md](../architecture.md#the-pipeline-as-a-state-machine)); the
build adds *blocked* and *paused*. A queued run whose work was already done
ends as *no change needed* — a normal outcome.

## Steps

### Start (every run)

1. **Kill switch:** `AGENT_HUB_ENABLED=false` (a repository variable, which
   only admins can change) stops every hub workflow, in every stage, at its
   first step, with a notice.
2. **Approval check (exact artifact):** from Jira's change history, the
   approved plan is the newest plan file uploaded before the transition to
   Implementation Plan Approved, which a person (not the automation account)
   made. That attachment must still exist and still be the newest plan file,
   no plan attachment may have been added or deleted after the approval, and
   the work order (the description) mustn't have been edited since. The
   history and the attachments are read together and read again after the
   plan downloads, before the push and before any send-back: the approval and
   the set of plan files must be exactly as first read. Otherwise the approval
   is **stale**: back to Implementation Plan with the reason, to be approved
   again (or, once the agent has run, the run stops without pushing). The
   plan's content hash and the approver go into the change set.
3. **Reconcile:** the run collects all outstanding work from its sources —
   unhandled `/apply` and `/revise` requests, the current pull request head and
   its CI state, the plan hash, the review items — and does the next step. The
   event that started it is only a wake-up ([Concurrency](#concurrency-and-stale-runs)).
   When it finds several things at once, it handles the first that applies,
   in this order:
   1. the kill switch or the `agent-hub-paused` label → stop;
   2. a branch or state integrity failure (a non-descendant history, a
      tampered state block) → stop, a person;
   3. a superseded build or a stale approval → mark it, stop or send back;
   4. outstanding human commands (`/apply`, `/revise`, `/skip`);
   5. the CI state of the current evaluation commit (CI fix or hand-off);
   6. the next step of ordinary work.
4. **Clean checkout and baseline:** `git status` must be empty (after
   `git clean -ffdx`). The run records the repository baseline in the change
   set: target branch and head, the plan's base commit, and the repository's
   test, lint, type-check and build commands (found, or from
   `build/guidance.md`).
5. **Dependencies:** a hub step (no agent) installs dependencies from the
   lockfile with the repository's install command in its frozen or immutable
   mode (`npm ci`, `--frozen-lockfile`, `--immutable` and equivalents),
   network limited to the package registries. It fails rather than rewrite a
   manifest or lockfile, and `git status` must still be clean afterwards. The
   agent never gets registry access; a dependency change the plan approves is
   resolved by the hub ([Dependencies](#dependencies-planned-changes-only)).
   Built in 2.6.0, with the toolchain: [Toolchain](#toolchain) and
   [Install](#install).

### Toolchain

The build's commands — the install, the agent's, the checks — run with the
toolchain the repository declares, not whatever the runner happens to have
(the first real build ran Node 16 from `/usr/local/bin` because the sandbox
couldn't see the runner's Node 22 in the home folder).

- **Node** is set up by the workflow (`actions/setup-node`, pinned) from the
  first of `.nvmrc`, `.node-version`, `.tool-versions` (`nodejs`) or
  `package.json` (`volta.node`, `engines.node`, `devEngines.runtime`) in the
  checkout — the files setup-node itself reads (`lib/toolchain.sh`). A
  repository with a `package.json` that declares none of them is **not
  built**: the fetch step stops before Claude with "Add an .nvmrc". A
  repository without a `package.json` gets Node 22, which the hub's own
  tools need.
- **The Node folder is made readable** in both sandboxes (the agent's and
  the hub's) — only that folder of the home folder — and is on the
  commands' `PATH`.
- **Other toolchains** (Python, Go, Ruby, …) are what the runner has: the
  hub doesn't set them up yet. Their checks still run in the sandbox, so a
  toolchain the sandbox can't read (one installed in the home folder) fails
  them; install it outside the home folder, or declare the checks
  ([extending.md](../extending.md#the-builds-checks)).

### Install

A hub step after the fetch and before the agent (no agent, no tracker, no
GitHub token): the frozen install the repository's lockfile asks for —
`npm ci` (`package-lock.json` or `npm-shrinkwrap.json`), `corepack pnpm
install --frozen-lockfile` (`pnpm-lock.yaml`), `corepack yarn install
--immutable` (Yarn 2 and later) or `--frozen-lockfile` (classic Yarn,
`yarn.lock`). It runs in the **hub's sandbox** (`lib/sandbox/sandbox.sh`:
Anthropic's sandbox runtime, `srt`, the engine of Claude Code's own sandbox,
installed from the hub's lockfile), so every process it starts — a
package's install scripts and their children included — gets the same
limits, enforced by the operating system:

| | Install | Checks ([Verify](#verify)) |
|---|---|---|
| Network | The package registries only (`registry.npmjs.org`, `registry.yarnpkg.com`, `repo.yarnpkg.com`) | None; localhost only |
| Read | Not the home folder (where the runner's credentials live), apart from the Node folder | Same |
| Write | The project folder and the job's temp folder | Same |
| Environment | Only `PATH`, a temp `HOME`, `TMPDIR`, `CI=true` and package caches in the temp folder: no secrets, no repository variables | Same |
| Time | `AGENT_HUB_BUILD_INSTALL_MINUTES` (10), the whole process tree ended at the limit | `AGENT_HUB_BUILD_CHECK_MINUTES` (10) per check |

Nothing is built when the repository has dependencies but no lockfile, an
`.npmrc` that names another registry or holds credentials (not supported
yet), an install that fails or runs out of time, or an install that changes
the repository (a rewritten lockfile, or installed files `.gitignore`
doesn't cover): `git status` must be clean afterwards. A repository with no
`package.json`, or no dependencies, installs nothing. The output stays on
the runner, never in the run log.

**Then it rehearses the verify step, before Claude runs (and is paid
for):** the clean copy of the base commit, its install, the list of checks,
the sandbox runtime, and one command run in the sandbox as the checks will be
(Node starting, when the repository has it). Anything in the environment that would stop the
verify step stops the build here instead, so after the agent only the checks
themselves can fail. (Since 2.6.1: the first real build in 2.6.0 spent its
Claude budget, then couldn't make the verify copy.)

### Validate

The agent reads the whole plan and checks it against the code as it is now,
starting from the commit the plan was written against (in the plan's Version
line): the files exist, the approach still fits, every acceptance criterion
can be verified. A blocking question is written into the plan attachment
(**Questions from the build**) and a comment; the ticket goes back to
Implementation Plan with `needs-clarification`. The answer comes as a plan
revision (`/revise`) and a new approval. Nothing is built from an unclear plan.

### Build

Implements the plan on branch `agent-hub/<KEY>` (which links the pull request
in Jira's development panel when Jira's GitHub integration is installed):

- **Verifies every behaviour change meaningfully:** automated tests in the
  repository's framework wherever it has a suitable test surface; otherwise
  the reason and the exact manual verification. Each acceptance criterion
  maps to its verification (the plan's per-criterion `verification` is the
  starting point).
- **Tests change only because approved behaviour changed** — never weakened,
  deleted, skipped, generalised or otherwise altered to get a pass. An edited
  test cites the criterion or plan decision behind it.
- Follows the repository's standards (`CLAUDE.md`,
  [extensions](../extending.md), the surrounding code) rather than introducing
  new ones.
- Records every judgement call in a **decision log**: decision, why,
  alternatives.
- Runs commands in the sandbox with **network to localhost only**.

Outcomes: *built* · *needs clarification* (back to the plan) · *no change
needed* (no empty commit; explained; a person decides) · *blocked*
(environment or tooling; flagged).

**A plan whose work is all manual changes** (only refused paths such as
`.github/**` or CODEOWNERS) leaves the build nothing to do: no commit, no
pull request, no attempt to implement it another way. The run posts the
plan's manual changes on the ticket with `needs-human` and ends as *no change
needed*; a person takes over.

### Dependencies (planned changes only)

The agent may edit a dependency declaration the approved plan describes, but
never gets registry access. When the build's diff touches a manifest:

1. **Gate:** the manifest changes must match the plan's dependency changes
   exactly (package, version range); anything else → decision item, and this
   step doesn't run.
2. **Resolve (no agent):** a hub step runs the repository's package manager
   to resolve and install — registries-only network, no credentials, in the
   sandbox — updating the lockfile and the installed packages.
3. **Gate again:** the resulting manifest and lockfile diff is rechecked
   against the approved change (direct dependencies only those planned;
   lockfile changes only from this step).

A fix pass never changes dependencies: a dependency finding is a decision
item.

### Verify

**In this version (2.6.0):** a hub step after the agent (no agent, no
tracker, no GitHub token) commits the agent's changes — the commit the
apply step checks and pushes — then clones exactly that commit into a
clean folder (not the checkout, which something the agent left running could
still change) — sparse like the checkout, so the hub's own test data, whose
content the checkout never fetched, is left out — installs its dependencies
the same way and runs the repository's checks there, each in the [hub's sandbox](#install) with no
network but localhost and its own time limit:

- **Which checks:** the repository's `build/checks.json`
  ([extending.md](../extending.md#the-builds-checks)) if it has one;
  otherwise the `package.json` scripts named `test`, `lint`, `typecheck`
  (or `type-check`) and `build`, run with the repository's package manager
  (`npm run`, `corepack pnpm run`, `corepack yarn run`). Both are read from
  the **plan's base commit**, as the repository was before the agent ran, so
  a build can't change which checks judge it. No checks → noted, not a
  failure.
- **A check that fails or runs out of time: nothing is pushed.** The ticket
  gets the ❌ failure comment naming the checks, then a "🧪 Checks that
  failed" comment with each one's command, result and the end of its output
  (40 lines). The run log names only each check and its result: the output
  could quote ticket text or the repository's code, and the log can be
  public.
- **All pass:** the apply step pushes only that commit (it checks the head
  is the one the checks ran on). The pull request and the ticket show the
  hub's results as authoritative ("Checks run by the hub"), with the checks
  the agent reported running separately.

The agent is told the checks will be re-run and runs them itself first. The
table below is the full design, with the review's second verify (PR 4).

After the build (and the dependency step, if any), and again after the fix
pass:

| Check | How |
|---|---|
| Tests | The repository's test command: the full suite, plus targeted runs for changed areas |
| Lint, type checks, build | The repository's own commands |
| Manual steps (simple checks) | For each manual step in the plan's Testing section, the agent tries what it safely can from the command line — run a CLI command, call a localhost endpoint, inspect a generated file — and records "checked by the agent: how and result" or "needs a person" |
| Service-backed tests (databases, queues, external APIs) | Not in the sandbox; CI is the authority. The pull request says what ran where |

Every check that can run locally must pass before the push. Checks that run
only in CI stay pending until CI and must pass before hand-off. Browser and
end-to-end automation is for later ([Later](#later)).

**Safety for every command**, enforced by the sandbox, not the prompt:
network to localhost only; no credentials in the environment; fixtures only,
never real data; migrations only against a throwaway local database; a time
limit per command; no `sudo`, no Docker; writes only inside the repository
and a temp folder.

### Review (read-only)

A fresh, read-only Claude session in the same job — independence comes from
the session, the tools and the inputs, so the exact unpushed change needs no
transport. It sees the approved plan, the change set, the **whole** diff and
the verification results, never the build's reasoning, and can read the
repository and run tests, but not edit. Large diffs are reviewed in file
groups within the size limits. Every area, every time:

| Area | Checks |
|---|---|
| Plan fidelity | Every criterion met and verified; nothing beyond the plan without a decision-log entry |
| Correctness | Logic, edge cases, error handling, concurrency, data integrity |
| Repository standards | Existing patterns and conventions; no new way of doing what the repository already does |
| Structure | Files in the right places, clear responsibilities |
| Docs | READMEs, docs, comments, changelog updated; nothing left stale |
| Workflows and configuration | Effects on CI, build, deploy config (the agent can't edit `.github/`; the review flags any need) |
| Verification | Every behaviour change verified; manual instructions accurate and complete; **no test weakened to get a pass** |
| Security | Input handling, authentication and authorization, injection, secrets, dependencies, data exposure |
| Scalability, efficiency, stability | Growth, performance, failure modes, timeouts, compatibility |
| Simplicity and necessity | Dead code, duplication, unneeded files, leftovers from abandoned approaches |
| Industry standards | Language and framework idioms; accessibility and internationalization where relevant |
| Anything missed | Migrations, configuration, rollout and rollback, observability |

Each finding has a **severity** (urgency) and a **kind** (what it concerns).
**Severity never decides autonomy; hub policy does:**

| Severity | Meaning |
|---|---|
| Critical | Breaks build, tests or CI; a security hole; data loss; a criterion not met; a merge conflict |
| High | Wrong behaviour in a realistic case; an unverified behaviour change; a standards breach that matters |
| Medium-high | Likely to cause bugs soon; notable duplication; docs made wrong |
| Medium | Worth doing, not blocking |
| Low | Style, nits |

| Policy | Result |
|---|---|
| Kind is correctness, test, documentation, performance or structure — **within the approved plan** — and severity critical, high or medium-high | Fix pass |
| Same kinds, medium or low | Review item (`R`) |
| Kind is dependency, schema or migration, public API or contract, auth or permissions, cryptography, payments or billing, personal data handling, infrastructure or deploy config, workflow or CI, licence, scope expansion, behaviour beyond the plan, test removal | **Decision item (`D`), always a person**, whatever the severity — acting on such a finding is a new decision |

**What plan approval authorises:** a governance change the approved plan
describes (the named dependency, the specific migration, the stated API or
permission change) may be built as described. Anything unplanned, different
or larger — another package, a bigger migration, a new contract, broader
permissions — is a decision item, as is any licence conflict. The
[gates](#gates-deterministic) check this where they can and re-run on every
fix's diff, so a mislabelled kind is still caught when a fix touches a
sensitive path.

Later rounds focus investigation on what changed but judge the whole pull
request, including that earlier fixes still hold. The change set records the
last head the agent reviewed ([Human commits](#human-commits-and-review-coverage)).

### Fix and fix check

A separate pass with the build's permissions applies the fix-pass findings —
**once**. Then a **fix check**: one small targeted pass over all the fixes
(for each: the finding, the fix's diff, the surrounding code, the affected
tests, the criterion) → resolved, unresolved or new concern. Anything not
resolved becomes a review item; there's no second fix loop. The fix check also
examines any test a fix changed. Then Verify runs again.

### Gates (deterministic)

After the build and after every fix, the changed files are compared with the
plan:

- **Expected scope:** the plan's Changes by File — exact files, directories
  or patterns (e.g. `tests/orders/**`). **Incidental:** tests and docs for
  planned files. **Unexpected:** anything else.
- **Governance flags** from the plan: dependencies, schema or migration,
  public API, auth or permissions, sensitive data, infrastructure, workflow or
  CI, configuration. A sensitive path or change of a class the plan didn't
  declare → decision item; a declared class must match what the plan
  describes (an added package must be named in the plan's dependencies;
  migration files must be within its scope), otherwise → decision item.
  Sensitive path patterns come from repository guidance plus defaults
  (manifests, lockfiles, migrations, schemas, configuration, infrastructure).
- **Refused outright** by the apply step, whatever the agent did: `.github/**`,
  `.claude/**`, `CODEOWNERS`, the hub's own files, binaries, symlinks,
  submodule (gitlink) changes, LFS pointers.
- **Decision items by file type:** generated or vendored files
  (`.gitattributes` `linguist-generated`/`linguist-vendored`, plus common
  paths), minified files, a single file over a line limit.
- **Manual companion changes:** if the plan says `.github/**`, `.claude/**` or
  CODEOWNERS must change, the pull request carries those as companion items
  and the hand-off says the change isn't complete without them. They don't
  block hand-off, since only a person can do them. A companion item is cleared
  only when a person makes the change (the run checks the branch contains it)
  or dismisses it with `/skip`.
- A dependency change records package, versions, reason, alternatives, and
  licence and vulnerability results where the repository's tooling provides
  them. A schema change records forward and rollback steps, compatibility and
  locking. The agent never runs migrations against a real environment and
  never deploys.

### Sync with the target branch

Before the push, and at the start of every revision:

- **Mechanical drift** — the target moved, but not in files the pull request
  or plan touch, nor in drift-sensitive paths: update and continue. A merge
  conflict is a critical finding: **2 attempts**, then a person.
- **Semantic drift** — the target changed files the pull request or plan
  touch, or **drift-sensitive paths** (from repository guidance, with
  defaults: manifests, lockfiles, schemas, compiler and build configuration,
  CI configuration, shared types), or the plan's base commit is far behind:
  the plan is **re-validated once**. Still valid: continue. Not: a person
  decides.

Updates are merges (or rebases of hub-only commits) — **never a force-push**.

### CI gate

The repository's CI runs on the pull request (pushes come from the machine
user's token; a workflow's own `GITHUB_TOKEN` doesn't start other workflows).

**CI green** means every check GitHub marks as **required for this pull
request** (`isRequired`, which accounts for branch protection and rulesets
alike) has an acceptable result on the commit GitHub is **currently
evaluating for required checks**: the current test merge commit if it has
statuses, otherwise the pull request's head. The hub reads both rollups — the
head's and `potentialMergeCommit`'s — and selects the evaluation commit by
that rule. It records each check's name, the app that posted it, the SHA and
the conclusion.

| Result | Meaning |
|---|---|
| success | Acceptable |
| skipped, neutral | Acceptable where GitHub itself treats them as passing for a required check |
| failure, timed out, cancelled | Failed |
| action required | A person |
| pending or missing | Not ready; after a time limit, a person (with a note that a path-filtered required workflow may never run) |

The hub doesn't compute requirements from branch rules itself. Results for
prior heads or obsolete merge commits are ignored. Failing checks that aren't
required are reported as `C` items without blocking.

**Classification is conservative.** The no-agent CI-result workflow separates
only cancelled, timed out and known infrastructure failures (→ a person, or a
re-run where the repository allows it) from ordinary failures. Whether an
ordinary failure is in the code or the test is decided by the CI-fix agent
within its **2 attempts per hand-off**, not by pattern matching. Unknown or
flaky → a person; tests are never edited to get a pass.

### Hand-off

**Hand-off eligible** (the hub decides): CI green · the plan still valid (hash
and approval) · the head is the one the hub expects · review, fix and fix check
done · no open decision items (companion items excepted) · no gate failure. Then the pull request is
marked ready, reviewers requested (CODEOWNERS or a setting), and the ticket
moves to **Ready for Review** with the pull request link (its Delivery → Pull
Request section), a summary, the open review items and `needs-human`.

**Merge eligible** is GitHub's decision alone (approvals, conversation
resolution, rulesets, branch protection); the hub doesn't reproduce it.

## The pull request as the record

### Content

Opened as a **draft** at the first push, from a hub template (never
free-form), labelled `agent-hub`. Its **title** is the ticket key and the
ticket's summary — or, where ticket text can't be published, the files the
build changed ("PROJ-1: change src/a.js and src/b.js", "PROJ-1: change 5
files in src/"). Its description covers:

- summary and ticket link
- each acceptance criterion: how it's met, how it's verified
- the decision log
- verification: commands run and results (sandbox, then CI); **how to
  review**: the reviewer's steps in order, each a command to run (or what to
  open) and what they should see, covering every acceptance criterion a
  person can observe, and marked when the build ran it exactly as written and
  saw that result ("the build saw this") or why it couldn't ("not checked by
  the build: …"); preview links where the repository has them (*provisional*)
- findings fixed in review (with the fix check's result); open review and
  decision items; manual companion changes
- scope check results; risk level and governance flags from the plan
- automated review coverage
- cost and time so far

### Publication policy

The hub reads the repository's visibility. **For a public repository**, pull
requests, commits, comments, review findings and logs carry only the ticket
key and content derived from the code itself (diff summary, changed
components, tests and results, code-derived findings). Acceptance-criteria
text, private context and the ticket-derived parts of the decision log stay
out unless a setting opts in. No model-generated "redacted" summary: private
context doesn't cross into a public repository unless explicitly allowed.
Private repositories get the full pull request. A public repository's pull
request still reads on its own: it says the details are on the ticket, lists
each changed file with its line counts, and refers to criteria and checks by
number ("Criterion 1 (on the ticket) — verified by a new test", "Check 1 —
failed (details on the ticket)"). **The ticket always gets everything** — it's
private: a "🔨 Draft pull request opened" comment with the build's whole
report (what changed, how each criterion is verified, the checks and their
results, how to review and what the build saw, its decisions, what's left for
a person), and the work order's Delivery sections filled in: **Pull Request**
(the link, what changed, each file with its line counts) and **Testing
Instructions** (check out the branch, then the reviewer's steps as an open
checklist with what to expect, then the checks the build ran). The comment
also says the ticket stays in Implementation Plan Approved until the
hand-off: a person reviews the draft, then moves it on.

### Change set and state block

When a build starts, the hub records the **change set** — exactly what was
approved — in a hidden block in the pull request description
(`<!-- agent-hub:state … -->`; before the first push it lives in the run):

- the approved plan attachment id, upload time, content hash, approver and
  approval time; the work order's hash
- base commit and target branch; expected scope; risk level; governance flags
- the repository baseline
- the **generation** (incremented by every build or revision run) and the
  branch head after each push; the last head the agent reviewed
- review items with their provenance
- totals: runs, models used, cost, time, attempts (fix, CI, conflicts)
- the schema version, and the hub version per generation

**Facts are re-derived; bookkeeping is protected:**

- **Re-derived on every run, never trusted from the block:** the branch head
  and review threads (GitHub), the plan hash (recomputed from the Jira
  attachment), approvals (Jira's change history), required checks and their
  results (GitHub), the ticket's status (Jira).
- **Kept in the block:** counters, totals, item status — hub bookkeeping.
- **Edit-history check:** GitHub keeps a pull request description's full edit
  history with the editor of each edit. Every edit since the hub's last write
  (all pages of the history) must be the machine user's; otherwise the block
  is untrusted and the run stops for a person. Every write is preceded, in the
  same run, by this check.
- **One writer:** only runs in the per-ticket group write the block.

Agents can't edit it (no token); only people with write access can, and
they're trusted (they can push code; passing a cap already means a person
lifts it). HMAC signing is the documented option if that threat model changes.

**Versions:** a run reads only supported schema versions. An older block is
migrated by a deterministic step where one exists; otherwise the run stops and
asks for `/apply rebuild`. A run uses the hub version it started with.

The pull request is the record: the state block, review threads, and a link
to each run's summary (GitHub deletes run logs after about 90 days). The hub
keeps no store of its own.

### Concurrency and stale runs

By default, GitHub concurrency groups allow one running and one pending run,
and a third trigger cancels the pending one; `queue: max` keeps up to 100
pending runs. So:

- **One per-ticket group** (`agent-hub-<repo>-<ticket>`) for everything that
  changes code or the state block, with `cancel-in-progress: false` and
  `queue: max`: a run is never killed mid-push, wake-ups are kept, and since
  people start every run, queuing is right. (actionlint doesn't know `queue`
  yet; `actionlint.yaml` ignores exactly that message for the build workflow.)
- **Runs act on current state, not on the event that started them.** Dropped,
  duplicate, reordered or stale wake-ups are harmless.
- **One writer:** the relay and CI-result workflows only observe, acknowledge
  (idempotently) and wake the per-ticket run; they never write the state block.
- **Before every external write** (push, pull request change, ticket change):
  the generation, the head the run started from and the plan hash are still
  current. If not, the run is **stale**: it stops, changing nothing.
- **Cancelled or failed runs** leave only disposable local state; cleanup
  (sessions, temp, credential files) runs `if: always()`.

### Human commits and review coverage

The change set records the last head the agent reviewed. If the current head
differs, the pull request shows: "Automated review covers commit abc123.
Current head is def456; commits were added afterward." People can still
merge. The hub doesn't re-review on its own — that stays person-triggered —
and the next revision reviews the whole pull request.

### Branch lifecycle

| Situation | What happens |
|---|---|
| `agent-hub/<KEY>` exists with no hub pull request (e.g. a failed earlier build) | Stop; a person decides |
| Non-descendant history or a force-push | Earlier generation and review provenance invalid; stop; a person |
| Branch deleted | Stop; a person |
| Merged | Branch deleted |
| Closed unmerged | Branch kept; a person decides. A new build needs the branch deleted **and** the plan approved again after the close — closing and deleting say what state it's in (a bot or a branch rule could do either), not that a person wants a new build |

## Review items and `/apply`

One numbered list per pull request, in the state block, shown in the
description, and mirrored to the ticket (one comment per review round,
*provisional*):

| Prefix | Source | Becomes work… |
|---|---|---|
| `R` | Agent review findings not fixed automatically; unresolved fix-check results | When a person applies it |
| `M` | People's pull request review comments | When a person applies it |
| `D` | Decision items | Only when a person applies it **by its id** |
| `C` | CI or conflict problems open after the caps; failing non-required checks | When a person applies it (or fixes it themselves) |

- **Provenance per item:** id, source, author, created time, the commit it was
  made against, status, and once handled the resolution commit and reason. The
  pull request table and the ticket comment are generated from it; ids stay
  stable.
- When a review is submitted, the **relay** workflow (no agent) numbers each
  new comment ("Tracked as M3") and wakes the per-ticket run, which adds it to
  the list.
- **`/apply M3 R2`**, **`/apply all`**, **`/apply all M`** — on the ticket
  (primary) or the pull request (*provisional*). `all` covers only
  agent-eligible items, never `D`. `/revise <text>` remains for requests that
  aren't items.
- Each `/apply` is one revision covering every requested item. Answers carry
  the item id (as change requests carry theirs today); only answered items are
  cleared.
- **Clearing:** each handled item gets a reply on its thread (what changed,
  the commit) and is resolved. One the agent couldn't do gets a reply saying
  why and stays open. A person dismisses one by resolving it or replying
  `/skip`; dismissed items never return.
- **Who can start code changes:** on GitHub, people with write access, only on
  the hub's own pull requests (`agent-hub` label, same-repository branch). On
  Jira, `/apply` — and `/revise` once a pull request exists — requires the
  **approvers group**, the same group the approval transitions require. Comment
  rights alone never authorise code changes. The relay ignores the machine
  user and bots.

## Revisions and reverse paths

| Situation | What happens |
|---|---|
| Plan unclear at validation | Back to Implementation Plan with questions in the plan |
| Approval stale (plan changed after approval) | Back to Implementation Plan for re-approval |
| Change requests | `/apply` or `/revise` → a revision on the same branch (never a force-push) |
| People pushed commits | The branch is the source of truth; review coverage marked stale; revisions build on top |
| Plan revised or re-planned after a pull request exists | Build **superseded**: the pull request is flagged; continuing needs a person (close it, or `/apply rebuild` if nobody else committed) |
| Work order revised after a pull request exists | Plan marked out of date (as today); build superseded |
| `agent-hub-paused` label | The hub doesn't touch the pull request until it's removed |
| Kill switch off | No hub workflow does anything until it's back on |
| Pull request closed unmerged | A comment on the ticket; not Done |
| Merged | Post-merge check, then Done: the pull request was merged (not closed) and its head is the last head the hub recorded. If CI runs on the merge commit, the run waits for it: pass → Done; fail → a comment and `needs-human`, no automatic revert. If none starts within a short window, Done, noting "no post-merge CI". A setting can require post-merge CI |

## Loops, caps and human gates

| Automatic loop | Cap | Past the cap |
|---|---|---|
| Fix pass | 1 per build or revision | Remaining findings → review items |
| Fix check | 1 per fix pass | Unresolved → review items |
| Merge conflicts | 2 attempts | Draft kept, ❌ on the ticket, `needs-human` |
| CI fixes (code and test failures) | 2 per hand-off | Same |
| Semantic-drift re-validation | 1 | A person decides |
| Runs per ticket (all started by people) | 10 (*provisional*) | Nothing more runs until a person lifts it |
| Spend per ticket | $60 (*provisional*) | Same |
| Each pass | Budget and time limit | The run fails with the reason; nothing pushed |
| Changed files / lines | 50 / 2,000, plus a single-file limit (*provisional*) | Draft kept; a person decides |

**No feedback loops:** the machine user's pushes, comments and reviews never
start the relay; the hub's comments never begin with `/revise`, `/apply` or
`/skip`; only the transition to Implementation Plan Approved starts a build;
moves into Ready for Review, Approved or Done start nothing; a person's
revision resets the CI-fix count, so a person is behind every further attempt.

**Human gates:** plan approval · validation answers and re-approval · code
review · every `/apply` · every decision item · anything past a cap or a size
limit · the merge (branch protection; a bot can't approve its own pull
request) · `agent-hub-paused` · the kill switch.

## Safety

### Who can do what

| Actor | Can | Can't |
|---|---|---|
| Build and fix agents | Edit files in the checkout (not refused paths; a dependency declaration only as the plan describes); run commands in the sandbox (localhost network only) | Push, call GitHub or Jira, install packages or reach a registry, read outside the repository, reach the internet, see any credential |
| Review and fix-check agents | Read the repository; run tests in the sandbox | Edit anything |
| Install step (no agent) | Install dependencies from the lockfile (frozen), registries-only network, in the hub's sandbox | Change manifests or lockfiles; read the home folder; see any credential |
| Verify step (no agent) | Commit the agent's changes; run the repository's checks on a clean copy of that commit, in the hub's sandbox, localhost-only network | Push; read the home folder; see any credential; change which checks run (they come from the base commit) |
| Dependency step (no agent) | Resolve and install a dependency change the approved plan describes, updating the lockfile; registries-only network | Run unless the gate confirmed the change matches the plan |
| Apply step (no agent) | Commit, push to `agent-hub/*`, open and update the pull request, write the state block, update the ticket | Merge, approve, push to other branches (branch protection) |
| Relay, CI-result and PR-sync workflows (no agent) | Read metadata, acknowledge idempotently, wake the per-ticket run | Write the state block; check out, run or download pull request code or artifacts; evaluate pull-request-supplied text in a shell |
| People | Approve, review, `/apply`, `/skip`, pause, merge; admins: the kill switch | — |

### Agent tool profiles

Chosen by the hub per pass — never by settings, extensions or tickets:

- **read-only** (the document stages): `--restricted`,
  `--tools "Read,Grep,Glob,WebSearch,WebFetch,Agent,Skill"`, path-scoped allow
  rules, deny rules for write and shell tools — as today.
- **build** (build, fix, CI-fix): `--restricted`, `--tools` with
  `Edit,Write,Bash` and **no WebSearch or WebFetch** (a setting can enable
  them); deny rules (which bind subagents) on refused paths; the **sandbox**
  passed through `--settings` (restricted mode still applies `--settings`, so
  the repository can't loosen it): shell commands and their children read only
  the repository (home denied, checkout re-allowed) and write only the
  repository and a temp folder; network to localhost only; an environment
  scrubbed of secrets; package caches in the temp folder; no unsandboxed
  retries; the run fails if the sandbox can't start.
- **review** (review, fix check): the sandbox with read-only file tools
  (`Bash` sandboxed, no `Edit` or `Write`), no web tools by default.

The exact sandbox setting names are verified against the runner's Claude Code
version with real Claude before anything depends on them. The hub's own
sandbox for the install and verify steps (the same runtime, without an agent)
is probed in the test suite against the real runtime — an install script's
child process can't reach the internet, read the home folder or write outside
the project; a check reaches localhost and nothing else; a command out of
time ends with everything it started (`tests/shared/sandbox.bats`, run in CI
on Linux).

### Credentials

| Credential | Reaches | Never reaches |
|---|---|---|
| Claude login or API key | Agent steps | Apply steps |
| Jira token | Fetch, apply and report steps (a curl config file, removed after) | Agent steps |
| Machine user token (fine-grained: this repository; Contents and Pull requests read/write; no Workflows, no Administration) | Apply, relay, CI-result and PR-sync steps (a git credential file, removed after) | Agent steps; the checkout (`persist-credentials: false`) |
| `GITHUB_TOKEN` | Read-only uses (events, labels) | Pushes (they wouldn't trigger CI) |

### Required GitHub settings

Checked in the pipeline test: branch protection on the target branch with at
least one approval, *require approval of the most recent reviewable push*,
required status checks, and push restrictions excluding the machine user (so
it can't merge or push to the target). Secret scanning with push protection,
and Dependabot or CodeQL, are recommended — the deterministic security gates
are the repository's own (CI, scanners, linters, type checks) plus the hub's
secret scan before every push. **Pull request workflows must not hold deploy
or production secrets**: CI runs agent-written code (keep those in
environments with required reviewers).

### Self-hosted runner hardening

Checkouts cleaned (`git clean -ffdx`) and temp folders per job, verified at
the start of each run · package caches in the job's temp folder · escaping
symlinks and gitlinks refused · **all actions pinned to full commit SHAs**
(GitHub-owned too), kept current by Dependabot · **an exact, pinned Claude Code
version required for the build**, checked against the runner's before any
Claude usage, and no automatic updates during runs · the sandbox check run by
hand (it uses Claude) on a new runner, after every Claude Code upgrade and
after changing the sandbox settings or the runner's setup — a matching version
doesn't prove a runner passed it, and it isn't run before each build ·
sessions, temp and credential files removed `if: always()` (and by each step
as it ends, whatever libraries it loaded) · nothing
an agent leaves in the checkout runs later: the hub runs from a copy made
before the agent, git from metadata copied before it, and the gates and
secret scan check the commit, not the working tree
([architecture.md](../architecture.md#after-an-agent-that-can-edit-the-checkout)).
Ephemeral runners are the first hardening item after v1.

Trust levels are in [architecture.md](../architecture.md#trust-levels).

## Structure

| Piece | What |
|---|---|
| `.github/workflows/agent-hub-build.yml` | Caller: triggers (dispatch from Jira, relay, CI result; manual), the per-ticket concurrency group, limits; one job runs start → validate → build → verify → review → fix → fix check → verify → sync → push |
| `agent-hub-stage.yml` with `code-stage: true` | The shared stage workflow, as for every stage, plus the full history and the machine user's token for the fetch and apply steps only; the install and dependency steps join it as steps that only code stages run, without the token |
| `stages/build/` | `stage.sh`, `prompt.md`, `schema.json`, `settings.sh`, `contract.jq` (the plan's contract), `gates.sh`, `pr-body.jq` (the pull request template); later `fix.md`, `fix-check.md`, `ci-fix.md` |
| `lib/toolchain.sh` | The Node version a repository declares, for the workflow's setup-node step and the fetch step's check |
| `lib/sandbox/` | The hub's sandbox for the install and verify steps: `sandbox.sh` (policies, time limit, a clean environment) and the lockfile `srt` is installed from (once per runner, in its tool cache; Dependabot keeps it current) |
| `stages/pr-review/` | The review's `prompt.md`, `schema.json` (findings: area, severity, kind, file and line, evidence), `policy.json` (kind × severity → fix pass, `R` or `D`), `settings.sh` |
| `lib/github.sh` | The GitHub interface; one `gh_request` function every call goes through (mocked in tests) |
| `lib/runners/claude-code.sh` | Tool profiles (`read-only`, `build`, `review`) and the sandbox settings |
| `agent-hub-relay.yml` | No agent: a review submitted, or a pull request comment `/apply` `/skip` → a numbered acknowledgement; wakes the per-ticket run |
| `agent-hub-ci-result.yml` | No agent: CI completed for an `agent-hub/*` head → wakes the per-ticket run (metadata only) |
| `agent-hub-pr-sync.yml` | No agent: pull request approved, merged or closed → wakes the per-ticket run (post-merge check, Done) |
| Extensions | `build/` and `pr-review/` folders as for every stage; `build/guidance.md` is where a repository says how to install, test and build, and lists sensitive and drift-sensitive paths; `build/checks.json` lists the checks the verify step runs, when the `package.json` scripts aren't the right ones |

**`lib/github.sh` (draft):** `gh_branch_ensure` · `gh_push <branch>
<expected-head>` (refuses non-fast-forward) · `gh_pr_find` ·
`gh_pr_open_draft` · `gh_pr_update_body` · `gh_pr_body_edits` (the full edit
history) · `gh_pr_ready` · `gh_pr_request_reviewers` · `gh_state_read` /
`gh_state_write` · `gh_threads` · `gh_thread_reply` / `gh_thread_resolve` ·
`gh_label` · `gh_pr_checks` (status-check rollups for the head and
`potentialMergeCommit`: name, app, SHA, conclusion, `isRequired`) ·
`gh_repo_visibility` · `gh_dispatch`.

**New settings:** `AGENT_HUB_ENABLED` (the kill switch, every stage) · models
and per-pass budgets (build, review, fix, fix check, CI-fix) · target branch
(default: the repository's default) · reviewers (default: CODEOWNERS) · caps
(runs, spend, files, lines, single-file lines, CI fixes, conflicts) · web tools
in code stages (default off) · publishing ticket content to public
repositories (default off) · sensitive, drift-sensitive, generated and
vendored path patterns · install and test command overrides · post-merge CI
(default: wait if it runs).

**CI result mechanism** (a spike decides): `workflow_run` needs the CI
workflows' names written in YAML, and `check_suite` events aren't delivered
for suites GitHub Actions creates. Options: `workflow_run` with the
repository's CI workflow names written in at install or update time
(recommended), `check_run` events, or a short scheduled poll. Whichever wins
only wakes the per-ticket run, which reads the checks itself.

## Jira

- **Build Requested** rule: on the transition to Implementation Plan Approved,
  remove `needs-human` (closing today's known gap) and dispatch the build.
- **Revision Requested** gets a branch for Ready for Review (`/revise`) and the
  `/apply` and `/skip` commands, with the approvers-group condition for
  commands that start code changes.
- Statuses: the existing Ready for Review → Approved → Done.
- The automation account can't make approval transitions
  ([jira.md](../jira.md#permissions-for-the-automation-account)).

## Testing the stage

| Layer | How | Claude? |
|---|---|---|
| Unit (jq, shell helpers) | bats | No |
| Scenario (whole workflow runs) | Extracted workflow steps, Jira and GitHub mocks, a local bare git remote, the Claude stub replaying recorded outputs; snapshots of every call | No |
| Variants | `run_scenario <name> VAR=value` for one-setting differences | No |
| Gates | A test per class and boundary case (special characters in paths, any letter case, git failing); each fix's test is checked to fail without the fix. An automated mutation check is a later improvement | No |
| Sandbox probes | `tests/shared/sandbox.bats`: the hub's sandbox (install and verify) against the real runtime — network, home folder, writes, time limit; in CI on Linux, skipped locally without the network | No |
| Boundary checks | `scripts/check-sandbox.sh`: real Claude Code against hostile settings and sandbox escape attempts, results checked on disk ([runners.md](../runners.md#checking-the-sandbox)) | Yes, about $0.20, confirmed with `use-claude` |
| Evals | Manual, `use-claude`, capped; one build case on a small fixture repository | Yes |
| Pipeline test | Real systems, the scenarios under [Building it](#building-it) | Yes |

## Cost (estimates to confirm in the pipeline test)

| Pass | Model (proposed) | Cap | Typical |
|---|---|---|---|
| Validate | Opus (with the build, or separate) | $3 | $0.5–1 |
| Build | Opus | $10 | $3–8 |
| Review | Opus | $5 | $1.5–4 |
| Fix | Sonnet | $3 | $0.5–2 |
| Fix check | Sonnet | $1 | ~$0.5 |
| CI fix (up to 2) | Sonnet | $3 each | $0.5–1.5 each |

Verify runs the repository's commands: runner time, no Claude cost. A typical
build to hand-off: **about $6.5–15.5**. The worst case per run is bounded by
the caps (about $28); per ticket by the spend and runs caps. Costs are in the
pull request and the run summary.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Agent-written code runs in CI with secrets | No deploy or production secrets in pull request workflows (checked in the pipeline test); environments with required reviewers |
| Sandbox settings differ by Claude Code version or OS | Verified with real Claude; the run fails if the sandbox can't start; a pinned CLI version |
| Prompt injection via repository content or tickets | Trust levels; tool profiles and the sandbox enforced technically; localhost-only network; no web tools in code stages; credentials never in agent steps; refused paths and file types |
| A plan changed after approval | The approval check against the exact attachment |
| A tampered state block | Facts re-derived; the edit-history check; one writer |
| Dropped, duplicate or reordered events | One per-ticket group with `queue: max`, no cancel-in-progress; runs reconcile current state |
| Runaway cost or loops | Per-pass budgets, per-ticket runs and spend caps, no feedback loops, every further attempt needs a person; the kill switch |
| Severity mislabelled to gain autonomy | Policy by kind; governance flags from the approved plan; gates re-run on fix diffs |
| Tests weakened to pass | The test-change policy; the fix check examines test edits; test removal is a decision item |
| Private ticket content in a public repository | The publication policy |
| A persistent self-hosted runner | Runner hardening; ephemeral runners first after v1 |
| CI result delivery limits | A spike; results only wake the run, which reads the checks itself |
| The machine user account | A fine-grained token, one repository, no workflow or admin access; push restrictions; rotation documented |
| Jira and GitHub disagree | Each authoritative in its area; stale runs stop; an unresolved mismatch goes to a person |

## Decisions

**Settled:** approval bound to the exact plan attachment through Jira's change
history · the state block's facts re-derived, its edits checked, one writer,
no HMAC in v1 · a fix check on every automatic fix · no browser or end-to-end
automation in v1 · all actions pinned to commit SHAs · no ticket text in
public repositories by default · code-changing commands on Jira need the
approvers group · the change set in a hidden block in the pull request
description · the shared stage workflow with a `code-stage` input (changed
in 2.5.0 from a sibling code-stage workflow: the build fits the same fetch,
agent, apply, send-back and report shape, so one workflow and one test
harness serve every stage; code stages add only the full history and the
machine user's token for the fetch and apply steps, which run no repository code) · the review as a fresh read-only
session in the same job · plan approval authorises the governance changes the
plan describes · CI green against GitHub's evaluation commit with GitHub's own
`isRequired` · post-merge CI waited for when it runs · the per-ticket group
never cancelled mid-push, with `queue: max` · the secret scan: pinned,
checksum-verified gitleaks, failing closed (2.4.0) · the hub run from a copy
and git from metadata copied before the agent ([architecture.md](../architecture.md#after-an-agent-that-can-edit-the-checkout)) ·
in 2.6.0: Node from the version the repository declares (setup-node), and
a Node project that declares none isn't built; other toolchains are the
runner's, and the docs say so · the checks from the base commit's
`package.json` scripts or `build/checks.json` · a check that fails means no
push, its output on the ticket only · the install and checks in the sandbox
runtime (`srt`), installed from a hub lockfile · the preview gate kept until
PR 4 (the reason is in [Building it](#building-it)).

**Still open (*provisional* defaults):**

| Decision | Default |
|---|---|
| Which repository the pipeline test builds in | A small separate test repository with code, tests and CI |
| Models and budgets | As under [Cost](#cost-estimates-to-confirm-in-the-pipeline-test) |
| The runner's OS for the sandbox | To confirm |
| `/apply` on the pull request as well as the ticket | Both |
| Runs per ticket | 10 |
| Past the caps | Draft kept, ❌, `needs-human` |
| CI on draft pull requests | Yes, given no deploy secrets in pull request CI |
| Preview environments | Link the repository's own |
| Review items on the ticket | One comment per round |
| Size limits | 50 files, 2,000 lines, plus a single-file limit |
| Spend cap per ticket | $60 |
| The build eval case | One case, its own cap |
| Semantic drift | Re-validate once, then a person |
| Risk level | Informational, plus governance flags and gates |
| CI result mechanism | `workflow_run` with names written at install, after a spike |

## Building it

Each step is a pull request with tests (mocked, parallel), boundary-tested
gates, docs in the same pull request and a changelog entry; real Claude only
where stated and only with the owner's OK.

1. **Existing stages: parity and contracts** (done in 2.2.0) — the kill switch; the approval
   check in the plan stage; new work orders checking the description is
   unchanged since the fetch; the plan's base commit, risk level, governance
   flags, observability, must-not-touch areas, scope patterns and manual
   companion changes; trust levels in every prompt; shared outcome names;
   actions pinned to commit SHAs; the Build Requested rule docs. One plan eval
   case for the prompt change.
2. **Tool profiles and the sandbox** (done in 2.3.0; the install step's
   sandbox comes with the step, in 3) — the build and review profiles, the
   install step's network, web tools off in code profiles; verified first with
   real Claude probes on the runner's OS.
3. **Build foundation**, in two parts:
   - *3a* (done in 2.4.0): `lib/github.sh` with a GitHub mock and a local git
     remote; the state block (re-derived facts, the edit-history check across
     all pages, versions); branch lifecycle; the publication policy; the
     secret scan.
   - *3b* (done in 2.5.0): the shared workflow's `code-stage` input, the
     hub copy and git isolation after the agent, the per-ticket group; start
     (the exact approved plan, its contract, the branch lifecycle, the
     publication policy), validate and build in one agent pass, gates and
     size limits on the commit, the secret scan, the draft pull request from
     the hub's template with its state block; the `playground/` folder.
     Until PR 4 the ticket stays in Implementation Plan Approved with the
     report comment, its Delivery sections filled in and `needs-human`; the
     move to Ready for Review is the hand-off's. A ticket that already has a
     hub pull request isn't built again. Gated
     behind `AGENT_HUB_BUILD_PREVIEW=true` (development only).
   - *3c* (done in 2.6.0): **a known environment, and checks the hub runs
     itself** — the repository's declared Node version set up by the
     workflow and readable in the sandbox, a Node project without one not
     built ([Toolchain](#toolchain)); the install step, frozen, in the hub's
     sandbox with registries-only network, with its probes against the real
     runtime — including that a package's lifecycle scripts and their child
     processes get the same limits as the package manager
     ([Install](#install)); the deterministic verify step: the commit, then
     the repository's checks re-run by the hub on a clean copy of it, a
     failure meaning no push ([Verify](#verify)); per-step time limits; the
     playground declaring its Node version (`playground/.nvmrc`) and its
     checks (`build/checks.json`).
   - *3d*: the dependency step (a planned dependency change resolved by the
     hub — today a decision item); reconciliation of an existing pull
     request; gitleaks cached in the runner's tool cache (still
     checksum-verified) rather than downloaded per run.

   **The preview gate stays until PR 4** (changed in 2.6.0; the earlier plan
   removed it after 3c). With 3c a build no longer depends on what the
   runner happens to have, and the hub checks its own commit — but a person
   is still the build's only reviewer, and nothing yet re-checks a pull
   request after people or later runs push to it. The gate comes off with
   the review, the CI gate and the hand-off, after a dedicated runner user
   or machine ([Later](#later)).
4. **Review, fix, CI gate, hand-off** — the review with its policy table; the
   fix pass, fix check and second verify; review coverage; sync and drift; the
   CI-result workflow, the evaluation commit (head and test merge commit both
   covered), conservative classification and CI fixes; hand-off eligibility.
   **Prerequisites, before the review pass or reconciliation is enabled**
   (from the 2.5.0 reviews):
   - *A read-only review profile, proven.* The review profile drops the
     file-editing tools, but its sandbox doesn't yet deny shell writes to the
     checkout (Claude Code's default allows the working directory). Deny them
     explicitly, keep a temp folder writable for test output, and add a
     review-profile run to the sandbox check (shell redirection, a script or
     child process writing, the file tools).
   - *GitHub's edit-history format, recorded.* `gh_pr_body_versions` reads
     each `userContentEdit.diff` as the whole description after that edit —
     confirmed read-only against the API in 2.4.0, but the test mock encodes
     the same assumption. Record real responses (creation, a person's edit
     outside the state block, an edit to it, deleted history) as fixtures,
     and bind the newest version to the description the API returns, before
     the state block is trusted for reconciliation.
5. **Review items, `/apply`, PR sync, docs** — the relay; `/apply` and
   `/skip` with the approvers-group condition; item clearing; the paused
   label; PR sync with the conditional post-merge check; superseded builds; a
   docs pass and the GitHub and Jira settings checklist.

Then the **pipeline test**, in a separate test repository with real code,
tests and CI: the happy path to Done · a validation question round-trip ·
an approval made stale by a plan upload · review items applied (`R` and `M`) ·
a decision item · a planned dependency added · a manual companion change ·
a CI failure fixed · a merge conflict · a human commit after
review · a plan revised after a pull request exists (superseded) · the paused
label and the kill switch · a pull request closed unmerged · caps reached.
It also checks that required checks are read for GitHub's evaluation commit (a
required check reported on the test merge commit, and one required by a
ruleset), a repository with and without post-merge CI, the GitHub and Jira
settings, and that session files are removed after each run.

## Later

| Item | Notes |
|---|---|
| A dedicated runner user, machine or GitHub-hosted runners | **Before the build runs real tickets** — on a personal machine, sandboxed commands can still reach localhost services, and Claude Code's own process isn't sandboxed ([runners.md](../runners.md#before-running-the-build-on-real-tickets)) |
| Ephemeral runners | The first hardening item after v1 |
| Browser and end-to-end automation | Where the repository has Playwright or Cypress: run the app on localhost, run the relevant specs, screenshots of changed UI, console errors; with a fresh browser profile per run, headless, downloads in temp, artifacts under the publication policy, and browser processes added to the sandbox probes |
| Hub-provided browser tooling | For repositories without an end-to-end framework |
| Merge-queue support | v1 detects a merge queue and says it's unsupported; people merge |
| Resuming a run that reached its budget cap | Today a retry starts the pass again (sessions aren't saved, by design). Keeping a capped build's work-in-progress — privately, for the next run to continue from — would save the spend already made; it needs the same isolation as sessions |
| HMAC-signed state | If lower-trust writers ever appear |
| A durable per-ticket run history beyond the pull request and ticket | Run logs expire after about 90 days |
| Richer repository capability detection | Beyond commands, required checks and visibility |
| An expanded eval suite | Beyond the single build case |
| More than one pull request per ticket | Nothing in v1 assumes one |
| GitHub Projects as the tracker for the build | Follows the Jira version |

**Not planned:** deploys · migrations against real environments · hub-managed
preview environments · automatic reverts · risk-based autonomy (auto-merge) ·
changes across repositories · debating agents · unlimited retries.
