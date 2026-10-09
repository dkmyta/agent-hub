# Build (`agent-hub-build.yml`) — design

> **Status: being built** ([Building it](#building-it)). **Not enabled for
> real tickets:** it runs only with `AGENT_HUB_BUILD_PREVIEW=true`, for
> development, until the review and CI gate (PR 4). Since 2.5.0 an approved
> plan becomes a **draft pull request** — start, validate, build, gates,
> secret scan, push — that a person reviews. Since 2.6.0 the build runs in a
> known environment — the Node version the repository declares, its
> dependencies installed from the lockfile — and the hub runs the
> repository's checks on the build's commit itself, pushing nothing if one
> fails ([Toolchain](#toolchain), [Install](#install), [Verify](#verify)).
> Since 2.7.0 the plan's dependency changes are applied and checked by the
> hub before the agent starts ([Dependencies](#dependencies-planned-changes-only)). Since 2.9.0 a
> fresh, read-only session reviews every build's commit, and its findings
> become the pull request's review and decision items ([Review](#review-read-only));
> since 2.10.0 the serious ones within the plan are fixed once, checked, and
> kept only if the build still passes ([Fix and fix check](#fix-and-fix-check)).
> Since 2.11.0 a build whose pull request already exists **reconciles** it
> instead of stopping: people's commits are verified, reviewed and, where
> the review allows, fixed once ([Branch lifecycle](#branch-lifecycle)).
> Since 2.12.0 it also **syncs** with a target branch that moved: merged in,
> verified, and reviewed again unless the drift is mechanical; a conflict
> goes to a person ([Sync with the target branch](#sync-with-the-target-branch)).
> Since 2.13.0 the **CI gate and hand-off** are built (4d-1): once every
> required check passes on exactly the head the hub verified, the pull
> request is marked ready and the ticket moves to Ready for Review
> ([CI gate](#ci-gate), [Hand-off](#hand-off)). Since 2.14.0 a required check
> that fails gets a **CI fix** — the fix pass's path, with the failed checks as
> its findings — up to 2 per hand-off (4d-2). Built against the
> [Contracts](#contracts) (2.10.2).
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
   the work order (the description) mustn't have been edited since — except by
   the automation account, whose only edit after an approval is the build's
   own Pull Request section (2.16.1: before, every run after a build took it
   for a change to the work order). The
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

### Baseline

Since 2.6.3, the rehearsal also runs the repository's checks on the base
commit, before the agent: a check that already fails there would fail the
verify step too, after Claude had run. `AGENT_HUB_BUILD_BASELINE` decides
what happens then:

| Setting | A check already failing on the target branch |
|---|---|
| `stop` (default) | Nothing is built and Claude isn't used: the ❌ comment names the checks, and "🧪 Checks that failed" has their output |
| `warn` | The build goes ahead, with a warning in the run log — for a plan that fixes a failing check. The checks must still pass on the build's commit for anything to be pushed; the failure comment says which also failed before the agent |
| `off` | No baseline (no extra runner time for a slow test suite) |

A failing check runs once more before it counts, in case a test is flaky.
The checks run in the sandbox, without the network: a repository whose
tests need the network or a service fails its baseline every time — the
message says to list the checks that can run offline in `build/checks.json`
([extending.md](../extending.md#the-builds-checks)), and let CI run the rest.
The baseline costs runner time (the checks run once more per build), never
Claude usage.

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

Since 2.7.0 the plan names each dependency change exactly, and **the hub
applies them before the agent starts** (`stages/build/dependencies.sh`, in
the install step) — the way dependency bots do it — so the agent writes code
and runs its tests with them installed, and never reaches a registry.

**The plan's list.** Scope & Governance has a **Dependency changes** list:
for each, the folder holding the package.json (`.` for the root), the
package, add, update or remove, the version range to save (from the npm
registry: no URL, git or file reference) and runtime or dev. The build reads
it back strictly (`contract.jq`): an entry it can't apply exactly is a
problem, and nothing is built. A dependency change outside an npm project
goes in the plan's Manual changes, for a person.

**The process**, in order — every step before the agent, so a failure costs
no Claude usage:

1. **Check every change first** (nothing is changed unless all can be): the
   folder is an npm project with a package.json and package-lock.json
   (lockfile version 2 or 3), no workspaces, not a hub-managed path; a
   package to update or remove is there, and none is an optional or peer
   dependency.
2. **Write the plan's ranges** into package.json, exactly (npm on its own
   rewrites them: `7.x` would be saved as `^7.0.0`).
3. **Resolve the lockfile** with npm, without install scripts, in the hub's
   sandbox (only the registries reachable), choosing only versions published
   by the cut-off (npm's `--before`); an update then moves to the newest such
   version in range.
4. **Check every version the lockfile adds or changes** — direct and
   transitive — against the registry, independently of npm's choice.
5. **Record** the manifest's and lockfile's blob ids.
6. **Install** (`npm ci`, sandboxed: new packages' install scripts run with
   the install step's limits), then **check** that the install consumed
   exactly the recorded files, the signatures, the vulnerabilities and the
   licences.
7. **Gate** the commit: its manifest and lockfile must be byte for byte the
   recorded ones.

**The policy**, check by check:

| Check | Rule | If it fails |
|---|---|---|
| Release age | Every package version the lockfile adds or changes, direct and transitive, was published on or before the cut-off: **published_at ≤ now − N × 24 h**, N = `AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS` (3; `0` turns it off), now = the step's start, in UTC. published_at is the registry's own publication time for that version (its metadata's `time` field, read from the registry, never a cache) | Nothing is built. A range only newer releases satisfy can't be built until they're old enough |
| Registry source | Every such version comes from the npm registry (`registry.npmjs.org`) — bundled packages ship inside their parent's tarball and are checked with it | Nothing is built: a git, URL or other-registry package's age and signature can't be checked |
| Lockfile determinism | The install consumes exactly the files step 5 recorded: `npm ci` never writes them, and the step checks it; the verify step's copy installs the committed files; the gates compare the commit's files with the recorded ids | Nothing is built (the install changed them), or a decision item (changed after the step, e.g. by the agent) |
| Signatures | Every installed package's registry signature verifies (`npm audit signatures`; with no packages installed, there's nothing to verify) | Nothing is built: a signature that doesn't verify, is missing, or can't be checked |
| Provenance | A package that publishes provenance must have it verify; one that publishes none is allowed and counted ("N packages, M with provenance") | Nothing is built (provenance that doesn't verify) |
| Vulnerabilities | Advisories (npm audit) are compared one by one, before the change and after it. A **new** high or critical advisory blocks; a new moderate, low or info one is for a person; existing ones are reported | Nothing is built (new high or critical; or the audit couldn't run, before or after — the change can't be shown not to add one), or a decision item (new, lower) |
| Licences | Every package version the lockfile adds or changes, direct and transitive, has a licence on the allowed list (`AGENT_HUB_BUILD_ALLOWED_LICENSES`, SPDX ids: permissive licences by default — MIT, MIT-0, ISC, BSD-2-Clause, BSD-3-Clause, 0BSD, Apache-2.0, Unlicense, CC0-1.0, BlueOak-1.0.0, Zlib, Python-2.0). An SPDX expression passes if it allows one on the list (one side of an OR, every side of an AND). The licence is the package's own package.json field, as the lockfile records it | A decision item, naming the packages: a person decides (a licence is a governance question, never the agent's) |
| Lockfile format | npm keeps the lockfile's format version | A decision item (a new format rewrites every entry) |

**Which folders are installed** — never a folder just because it has a
package.json: the repository root (as before); the folders of the plan's
dependency changes (the approved plan names them); and the folders the
repository's `build/checks.json` lists under `install` (its own
configuration, read from the base commit like the checks, and reviewed like
code). Nothing else.

The pull request and the ticket list each change with the version it
resolved to and its licence, and per folder: the lockfile's added, changed
and removed packages, the cut-off, the signatures (and how many with
provenance), the advisories before and after (and any new), and any licences
outside the list.

**npm only, in this version.** pnpm's and Yarn's equivalents of the minimum
release age exist only in their newest versions, and the signature check is
npm's: a plan whose dependency changes are in a pnpm or Yarn project stops
before Claude, saying so. A plan from before 2.7.0 (no Dependency changes
list) keeps the earlier behaviour: its dependency changes are decision items.

**Decided in review (2.7.0)**, after an external review of the plan, each
point checked against npm and the code before acting on it:

| Point | Decision |
|---|---|
| The age rule must be exact, cover transitive versions, and use registry times | **Adopted.** npm's `--before` already uses registry times across the tree (npm's documentation), but a test couldn't show it for a transitive package, so the hub now checks every added or changed version itself, against the registry — the guarantee doesn't rest on npm's internals |
| The install must not silently change the resolved lockfile | **Adopted** — a real gap: the files were recorded *after* the install, so a changed lockfile would have been accepted as the hub's. They're now recorded after resolving and checked after every install |
| Signature and provenance failures need explicit semantics | **Adopted**, with one difference: **absent provenance is allowed** (and counted), not blocking. Most packages publish none — including long-standing ones like `is-number` — so requiring it would block nearly every dependency |
| Licences need a policy, not just collection | **Adopted** — the first version had a short denylist (GPL, AGPL, SSPL, none) for direct packages only, which let other licences (MPL, BUSL, commercial ones) and every transitive package through. Now an allowlist, for every new package, that the repository can replace |
| Vulnerabilities by advisory and severity, not counts | **Adopted** — counts hid a new critical advisory behind removed low ones |
| Unsupported package managers rejected before the step changes anything | **Adopted**: every change is checked before any is applied |
| Installs limited to the plan's package roots | **Already so** (no recursive installs); the root and `checks.json`'s `install` list are installed too — repository configuration, from the base commit |
| Evals for every dependency case (malformed entries, pnpm, several roots, …) | **Partly.** Those are decided by the hub's code, not the model, and are covered by deterministic tests (`contract.bats`, the build scenarios, real-registry probes). The plan eval checks what the model decides: an ordinary npm addition listed exactly, and nothing listed when nothing changes |

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
table below is the full design; the second verify, after the fix pass, is
built (2.10.0, *Verify fix*).

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
repository and run tests, but not edit. Since 2.18.0 it works in **its own
clean copy** of exactly the verified commit (dependencies installed from the
lockfile, as the verify step's), never the checkout the build agent left —
whose ignored files (`node_modules`, say) could steer what its tests show —
and its sandbox keeps it from writing to that copy. Its guidance
(`CLAUDE.md`, the extensions) is the target branch's from when the run
started, never what the build agent wrote. Findings in the `security` area
are always a person's decision, whatever their kind (`policy.json`,
`decision_areas`). The fix check, likewise, judges the fix pass's candidate
**committed** (the Fix step commits it; Verify fix checks that commit) in its
own clean copy. A diff over 400 KB is replaced by
its list of files, which the reviewer then reads itself (reviewing in file
groups is a refinement for later, if real builds need it). Every area, every
time:

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

**As built (2.9.0, `stages/build/review.sh`):** the *Review* step runs
after Verify, on the commit the checks passed on, with the review profile
(commands in the sandbox, nothing written to the repository: proven by the
sandbox check), the shared review model (`AGENT_HUB_REVIEW_MODEL`) and its
own budget (`AGENT_HUB_BUILD_REVIEW_MAX_BUDGET_USD`, $5). Its inputs are the
ticket and plan, the hub's check results and the diff the hub computed from
the git metadata copied before the agent ran — never git in the checkout.
The hub, not the agent, sorts each finding by `review/policy.json`; since
2.10.0 the fix-eligible ones go to the fix pass.
The pull request lists every item; a public repository's shows only each
finding's kind, severity and area (its text is on the ticket, with the
evidence and suggestion). The review never costs the build: the step
continues on error, and a review that fails, times out, reaches its budget
or names a file outside the repository is itself a decision item on the
draft.

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

**Fix invariant:** an automatic fix never puts a person's decision into a
pushable commit. Verify fix keeps a fix only if, compared with the reviewed
commit, it adds no refused file, **no decision item** (outside the plan's
scope, a must-not-touch area, a dependency file, the size limits…) and no
hard link, and every check passes; otherwise the whole candidate is
discarded — the commit, its gate results, its checks' copy and output —
and the reviewed commit is pushed exactly as it was (2.10.1).

**As built (2.10.0, `stages/build/fix.sh`):** the *Fix* step runs the fix
pass (the build profile; `AGENT_HUB_BUILD_FIX_MODEL`, Sonnet, capped by
`AGENT_HUB_BUILD_FIX_MAX_BUDGET_USD`, $3) only when the review found
fix-eligible findings, then the fix check (the review profile, the same
model, `AGENT_HUB_BUILD_FIX_CHECK_MAX_BUDGET_USD`, $1) on exactly the diff
the fix made, as the hub computed it. *Verify fix* — no agent — commits the
fix on top of the reviewed commit and **keeps it only if the gates refuse
nothing and the repository's checks pass on it**; otherwise it resets to the
reviewed commit, which is pushed as it was. A fix the check couldn't judge,
or a fix pass that changed nothing, isn't kept either. Both steps continue
on error, and Apply drops a fix that never finished verifying, so the fix
pass can't cost the build or push an unchecked commit. On the pull request,
a resolved finding is listed as fixed; an unresolved one, or any when the
fix wasn't kept, stays open; the fix check's new concerns are sorted by the
same policy into decision or review items (never fixed: there's no second
loop). Its eval: `tests/build/evals` ([evals.md](../evals.md)).

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

*Built* (2.12.0, `_reconcile_sync` in `stages/build/reconcile.sh`) for a
pull request that already exists: when the target branch has moved past
where the pull request last met it, a run merges it in — in the fetch step,
before anything reads the code or Claude runs. The drift is classified first,
from paths alone (the target's changes since that point, both sides of a
rename):

- **Mechanical drift** — the target changed no file the pull request or the
  plan's Changes by File touch, and no drift-sensitive path: the merge is
  verified (install, the repository's checks on exactly the merge commit)
  and the **earlier review still applies** — no Claude, so the run isn't
  admitted against the caps or counted. The status section is left as it
  was; the record and a comment say what happened.
- **Semantic drift** — the target changed a file the pull request or plan
  touch, or a **drift-sensitive path** (`BUILD_DRIFT_SENSITIVE` in
  `gates.sh`: the gates' sensitive kinds — manifests and lockfiles, schemas,
  infrastructure, CI, configuration — plus compiler and build configuration,
  shared types and the hub-managed paths): the merge is verified and the
  **whole change is reviewed again** on the merged commit, and fixed once
  where the review allows — as for people's commits. (Decided 2026-10-08:
  re-checked by the code review, not a separate plan re-validation pass.)
- **A merge conflict** — the merge is abandoned and nothing is pushed: a
  comment on the pull request and the ticket lists the conflicting files,
  the ticket gets `needs-human`, and a person merges the target and
  resolves them (outcome *blocked*). The next run re-checks what they
  pushed. (Decided 2026-10-08: a person, not an agent — a later item.)

The merge is the machine user's (`Merge <target> into <branch>`), and the
base the gates and the review compare with becomes the target's head, so
they see the pull request's own changes only. Updates are merges — **never
a rebase or a force-push**; the push is rejected if anyone pushed meanwhile.
A merge that brings in changes to `.github/workflows/` can't be pushed with
the build token (no Workflows permission, by design): the run says so and a
person merges it. Not built: repository guidance adding drift-sensitive
paths, and treating a base that's far behind as semantic on its own; a new
build always starts from the target's head, and the sync runs for existing
pull requests (a revision, step 5, will reuse it).

### CI gate

*Built* (2.13.0, 4d-1: `stages/build/handoff.sh`, `lib/ci.sh`,
`stages/build/sweep.sh`; CI fixes are 4d-2). As built:

- **Woken by the CI sweep** (`agent-hub-ci-sweep.yml`, every 10 minutes, no
  agent; decided 2026-10-08 after a spike, instead of `workflow_run` events,
  which fire only for named Actions workflows, while `check_suite` and
  `check_run` never fire for Actions' own checks, and waiting inside the
  build would hold a single self-hosted runner that the repository's CI
  then can't use). It requests the build (`wake: ci`) for each of the hub's
  draft pull requests whose required checks have finished on the head the
  hub last recorded — or waited past `AGENT_HUB_BUILD_CI_WAIT_MINUTES`
  (120) — and whose result the build hasn't handled yet. It leaves alone a
  paused or superseded pull request, and one with commits the hub hasn't
  recorded (a person pushed: a run they start re-checks it). Events can make
  it faster after v1.
- **A run the sweep requested does only the CI gate.** Anything else it
  finds — an untrusted record, a newer plan, people's commits — is for a run
  a person starts, so it ends quietly (the reason in the run summary only),
  never repeating a comment every sweep. It doesn't sync a moved target
  either: GitHub's own rules decide whether a merge needs the branch up to
  date.
- **Read with the workflow's own token** (`GITHUB_TOKEN`, granted `checks:
  read` and `statuses: read`; the build's fetch and apply steps only). A
  fine-grained token can't be given the Checks permission, so the machine
  user's can't read check runs in a private repository.
- **What's required** comes from the target branch's protection and its
  rulesets, with the app that must post each check, so a required check
  that never reported counts as missing. **Each result** is the latest run
  of that check (from that app) on exactly the head, and commit statuses.
  Nothing required on the target means the hub can't tell when CI passed: a
  person.
- **Each result is reported once per head** (the state block's `ci`
  record): pending → nothing (until the wait limit: a person); failed → a
  CI fix (below), or a person; green → the hand-off, or a person told why
  it isn't eligible.
- **CI fixes** (2.14.0, 4d-2): when every failed required check ran and
  failed (conclusion `failure` — not timed out, cancelled, needing action or
  erroring, which a code fix can't address: a person), and fewer than
  `AGENT_HUB_BUILD_CI_FIX_ATTEMPTS` (2) were made since the last full review
  (so a person's commits, reviewed again, start a new count), the run
  becomes a CI fix. The attempt is recorded first, before any Claude, so a
  run that stops part-way is never repeated by the sweep. The failed checks
  become the fix pass's findings, with what each reported — the check run's
  own summary and, for an Actions job, the end of its log (read with the
  workflow's token, `actions: read`; to the agent only, as information) —
  and from there it's **the fix pass's own path**, no more and no less
  permissive: its `ci-fix/prompt.md` instructions (find the cause; never
  weaken a test), the fix check, Verify fix (no new refused file or decision
  item, no hard link, and every one of the repository's own checks the hub
  runs — not GitHub's — passing in the sandbox on exactly that commit), the
  secret scan and a push that's never forced. Only failed *required* checks
  start one (a check that isn't required is never seen); the pushed fix is a
  new SHA, so the hand-off waits for every currently required check to pass
  on it. A kept fix is
  recorded as `kind: ci-fix`, verified on exactly its commit, and CI runs
  again on it; one that wasn't kept changes nothing and a person takes
  over. Admitted on the fix pass and its check ($4 of budgets by default, $6
  with the per-pass overshoot allowance).
- **v1 reads the pull request's head only**, where GitHub Actions posts a
  pull request's checks; CI that reports only on the test merge commit, and
  `C` items for failing checks that aren't required, are after v1.

The design, for reference:

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

*Built* (2.13.0, 4d-1). As built, a pull request is handed off only if, read
again just before anything is written:

1. **The record is trusted** — its edit history shows only the hub's edits.
2. **The head is exact** — the branch's head on GitHub, the last head the
   record lists, and the commit whose required checks all passed are the
   same commit.
3. **Everything after the last full review is accounted for** — every head
   the record lists after `review.head` is the hub's and either a fix
   (`kind: fix`) or a merge of the target with mechanical drift (`kind:
   sync`), each with its verification recorded **for exactly that commit**
   (`verified.head` equal to its own `head`; a flag can't carry over to
   another commit). A person's commit, a semantic sync or anything else
   needs a full review first — green CI doesn't make it eligible.
4. **The rest** — the review finished, no decision item is open, the plan
   and its approval still stand, and the ticket is in Implementation Plan
   Approved.

Then the hub records the hand-off, marks the pull request ready for review
(CODEOWNERS are requested by GitHub then), moves the ticket to **Ready for
Review** with `needs-human`, and comments on both. A hand-off that stops
part-way is finished by the next run (each write is safe to repeat) — the CI
sweep wakes one recorded but still a draft (2.19.0). A
record from before 2.13.0 doesn't list the reviewed commit, so it's never
handed off — a person reviews it. Reviewers from a setting are after v1.

The design, for reference:

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

- **One per-ticket group** (`agent-hub-<repo>-<ticket>`) shared by every
  stage — the work order, the plan and the build (since 2.12.1; the document
  stages used to cancel an older run) — with `cancel-in-progress: false` and
  `queue: max`: nothing for a ticket runs in parallel, so no two runs update
  its state or its Claude usage record at once; a run is never killed
  mid-push; wake-ups are kept, and since people start every run, queuing is
  right. (actionlint doesn't know `queue` yet; `actionlint.yaml` ignores
  exactly that message for those three workflows.)
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
| The hub's pull request is open (2.11.0, `stages/build/reconcile.sh`) | **Reconciled:** with the `agent-hub-paused` label, nothing; a record (state block) someone else edited, or a branch that no longer builds on the hub's last push, stops for a person; built from an earlier plan than the one approved now, superseded — a comment on the pull request and the ticket, `needs-human`, a person decides; nobody pushed since the hub and the target hasn't moved, nothing to do; a target that moved is merged in (2.12.0: mechanical drift keeps the review and uses no Claude, semantic drift is reviewed again, a conflict goes to a person — [Sync](#sync-with-the-target-branch)); otherwise people's commits are verified, the whole change reviewed again and fixed once where allowed, the fix pushed without force (rejected if anyone pushed meanwhile), and the description's status section and record rewritten — the rest of it kept — with a comment on the pull request and the full report on the ticket. No build pass: admitted on the review, fix and fix check ($9 of budgets by default, $12 with the per-pass overshoot allowance). A run a person starts for a ticket already in Ready for Review or Approved reconciles its pull request the same way — a person's commits after the hand-off are checked again (2.19.0); a new build starts only from Implementation Plan Approved |
| `agent-hub/<KEY>` exists with no hub pull request (e.g. a failed earlier build) | Stop; a person decides |
| Non-descendant history or a force-push | Earlier generation and review provenance invalid; stop; a person |
| Branch deleted | Stop; a person |
| Merged | Branch deleted |
| Closed unmerged | Branch kept; a person decides. A new build needs the branch deleted **and** the plan approved again after the close — closing and deleting say what state it's in (a bot or a branch rule could do either), not that a person wants a new build |

## Review items and `/apply`

*Built* (step 5, agreed 2026-10-08 with an external review): **`/skip`**
(2.16.0, 5b-1) and **`/apply`** (2.17.0, 5b-2) on the ticket
(`stages/build/commands.sh`, the tracker's Build Command rule). As built:

- **Commenting on a ticket never authorises a change** (a permanent rule):
  the commenter must be in `AGENT_HUB_APPROVERS_GROUP`, checked by the hub
  from the tracker; unset, or not checkable, and nothing is done. A comment
  someone else edited (Jira's "Edit All Comments") isn't its author's
  command, and is refused (2.18.0). `/apply comments` takes review threads
  only from people GitHub says have write access (2.18.0) — not from every
  org member or read-only collaborator.
- **Only item ids.** The command's first paragraph may hold only the command
  and ids; anything else refuses the whole command — item commands aren't a
  way to give the agent instructions.
- **Only open items in the pull request's current record**; every command is
  answered once, on the ticket (the comment marked resolved with what was
  done, or why not).
- **`/skip`:** a decision item is *accepted*, any other *skipped*; the
  description's items are rewritten from the review the hub keeps on the
  ticket (the private `agent-hub-review` property: findings' full text a
  public pull request can't hold), the pull request gets a comment, and who
  did what, when, on which head, is kept on the ticket (`agent-hub-items`).
  The CI gate's last result is cleared, so the CI sweep runs it again — a
  pull request whose only blocker was a decision item is then handed off.
- **`/apply R2 D1`, `/apply all`, `/apply comments`:** a fix of exactly the
  requested items, **through the fix pass's own path** — R item / review
  thread → a bounded finding → the fix pass (`apply/prompt.md`) → the fix
  check → the Verify-fix gate → a push never forced. Never a free-text
  instruction. `all` is every open R item, never a decision (a decision only
  by its id); `comments` is the pull request's unresolved review threads
  from people with write access, as read when the run starts — the snapshot
  the fix is attributed to. Each finding comes from the review the hub kept
  (a decision as the gates flagged it); a manual change, the "review didn't
  finish" decision or an item without a kept finding can't be applied.
- **Only on the head the hub last recorded and reviewed:** after anyone
  else's push, `/apply` is refused: run the build again (Actions → Agent
  hub: Build → Run workflow, with the ticket key — also for a ticket in
  Ready for Review or Approved, since 2.19.0) to have it reviewed, then apply
  what that review lists. One `/apply` per run.
- **What follows:** a kept fix is the hub's (`kind: fix`, verified on exactly
  its commit, with the `/apply` it answers); each item the fix check found
  resolved is closed as *fixed*; each thread gets a reply — the commit, or
  that it wasn't applied (Claude's words only on the ticket) — and is
  resolved when applied; the `/apply` is answered on the ticket item by
  item. CI and the hand-off gate run again on the new SHA. A pull request
  that was already handed off goes **back to draft**, the ticket staying in
  Ready for Review (the hub never moves a ticket back into Implementation
  Plan Approved: its own move there wouldn't be an approval); the CI gate
  and hand-off also run for a ticket in Ready for Review, and mark it ready
  again. Admitted on the fix pass and its check ($6 with the overshoot
  allowance).
- **Deferred** (after v1, only if real use shows the need): a relay numbering
  each pull request comment as an `M` item, commands on the pull request
  itself, a reviewers setting, post-merge CI.

The design, for reference:

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
| Pull request closed unmerged | A comment on the ticket; never Done. *Built* (2.15.0) |
| Merged | *Built* (2.15.0, without post-merge CI — after v1): **a ticket reaches Done only from a hub pull request the hub handed off and GitHub reports merged.** Merged after the hand-off → Done (if people pushed after it, still Done, with a note: the person who merged owns those); merged without the hub's hand-off, or with a record that can't be trusted → not Done, a comment and `needs-human`. The no-agent `agent-hub-pr-closed.yml` (`pull_request_target: closed`; no checkout, no repository code) only requests the build (`wake: closed`); the build (`closed.sh`) re-reads GitHub and the ticket. The design: post-merge check, then Done: the pull request was merged (not closed) and its head is the last head the hub recorded. If CI runs on the merge commit, the run waits for it: pass → Done; fail → a comment and `needs-human`, no automatic revert. If none starts within a short window, Done, noting "no post-merge CI". A setting can require post-merge CI |

## Loops, caps and human gates

| Automatic loop | Cap | Past the cap |
|---|---|---|
| Fix pass | 1 per build or revision | Remaining findings → review items |
| Fix check | 1 per fix pass | Unresolved → review items |
| Merge conflicts | None: a person resolves them (decided 2026-10-08) | Nothing pushed, the files listed, `needs-human` |
| CI fixes (code and test failures) | 2 per hand-off | Same |
| Semantic drift | The whole change reviewed again on the merged commit (decided 2026-10-08), with its one fix pass | As for a review |
| Runs per ticket that used Claude, every stage (all started by people; since 2.8.0) | 10 (*provisional*) | Nothing more uses Claude until a person lifts it ([claude-usage.md](../claude-usage.md#per-ticket-caps)) |
| Spend per ticket, every stage (since 2.8.0) | $60 (*provisional*) | Same |
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

## Contracts

The rules every part of the build — built or planned — must keep, written
down before 4c and 4d are built so they're built and reviewed against them
(agreed after the 2.10.0 review, with an external review). Each says whether
it's **built** (and since when) or **planned** (and for which part). Where a
section above describes the same thing at more length, this is the summary
that wins.

### Rules that hold everywhere

1. **Fail before Claude.** Anything deterministic that can be established
   before Claude runs is established before Claude runs, and stops the run
   if it fails (*built*, 2.1.0–2.10.1): the kill switch and preview gate; settings (sizes, times,
   budgets, caps); the pinned Claude Code version; the approval (the exact
   plan file, approved by a person, the work order unchanged since); the
   plan's contract; the branch and pull request state; the declared
   toolchain; the dependencies and the plan's dependency changes with their
   supply-chain checks; a rehearsal of Verify; the baseline; budget
   admission. Every new check that can run before Claude goes here.
2. **Agents propose; deterministic gates decide; only verified candidates are
   published.** No agent output reaches a push, a pull request or a ticket
   except through the hub's checks: Verify, the gates, the secret scan, the
   publication policy. *Built.*
3. **Publication policy.** A public repository's pull requests and commits
   carry only hub-derived facts and publication-safe fields (ids, kinds,
   severities, counts, paths the hub computed, the hub's own reason texts),
   never Claude-written text, unless ticket content may be published.
   *Built* (2.5.0; the review's and fix pass's fields 2.9.0–2.10.0,
   canary-tested since 2.10.1).
4. **People merge.** The hub never approves or merges; it observes the
   merge (D3). *Built* as a rule; observing the merge is step 5.
5. **Budget: three limits, in order** — the ticket's cap; **run admission**:
   a run may invoke Claude only if `ticket_spend_to_date + run_max_budget <=
   cap`, where `run_max_budget` is the sum of the configured maximum of
   every pass the run may execute (a build: build + review + fix + fix check
   = $19 by default); then each pass's own `--max-budget-usd`. A run that
   isn't admitted is **blocked** (`agent-hub-over-cap`, `needs-human`), not
   failed; a person lifts the cap; nothing resumes automatically.
   *Built* (2.8.0; admission 2.10.1). A CI fix (4d) and an `/apply` run
   (step 5) are runs like any other: each is admitted with its own maximum.

### Freshness

Two kinds, never confused: **input freshness** — what a pass works from —
and **publication freshness** — what must still be true at the moment
anything is written. A pass may work from an earlier commit (the review
works from the verified commit, the fix check from the fix's diff); nothing
is ever *published* from anything but the exact commit the hub verified.

| Pass | Works from (input) | Publishes only if (publication) | |
|---|---|---|---|
| Build | The approved plan file (exact checksum), the approval (Jira's history), the work order unchanged since; the target branch's head at the start (the base) | Apply: the same plan and approval still stand, the ticket is still in Implementation Plan Approved, the branch is absent (a new build) | *Built* |
| Review | The verified commit, and the hub's diff and check results for it | Its findings apply to that commit only; Apply uses them only for the pushed commit or a kept fix's parent | *Built* (2.9.0) |
| Fix | The reviewed commit and that review's fix-eligible findings | Its candidate is kept only once verified (below); pushed only as the exact commit verified | *Built* (2.10.0) |
| Fix check | The hub's diff of exactly the fix | — (no output of its own is published) | *Built* (2.10.0) |
| Apply (push) | The verified commit | That commit is `HEAD` and the one the checks passed on; the plan and approval re-checked; the push is never forced, and a new branch must not exist; an existing one must still be at the head the run started from (a push that isn't a fast-forward is rejected) | *Built* (existing branches 2.11.0) |
| Sync | The target branch's current head and the pull request's head the run recorded | The remote branch still at the recorded head (a push that isn't a fast-forward is rejected); merges only, never a force-push. **A sync is a code change:** it resets verification freshness, and review freshness unless the drift is mechanical (below) | *Built* (2.12.0) |
| CI fix | The CI failure for the current evaluation commit (which must be the current head) | As Fix, on the current head; the head unchanged since the failure was read | *Built* (2.14.0; the head only) |
| Hand-off | The current pull request head | The head is the last head the hub verified; required checks green for exactly that evaluation commit; the provenance rule holds; no open decision items; the plan and approval still stand | *Built* (2.13.0; the head only, see [CI gate](#ci-gate)) |
| `/apply` | The current pull request head and its current items | As a revision build: admitted, verified, gated; only items still valid on the current head are applied (below) | *Planned* (step 5) |

**What invalidates freshness** (from the state block's recorded heads;
*built* 2.11.0–2.12.0): any commit after the last head the hub verified — a
person's push, a sync merge — makes that head's review and verification
stale for hand-off. A sync merge whose target changes touch nothing the
plan or the pull request touches, and no drift-sensitive path, keeps the
review but still needs Verify (and CI) on the merged commit; anything else
needs the next run to review again. The hub never concludes "the target
changed, we merged it, so we're fine".

### Candidate eligibility (any automatic change)

One contract for every commit an agent's work becomes — the build's, the
fix pass's (*built*, 2.10.0–2.10.1), and a CI fix's (*built*, 2.14.0, through
the same code path as the fix pass, no more and no less permissive). A
candidate is pushed only if:

- it contains no hard link (one check: `build_hard_linked_files`) and no
  file the gates refuse;
- for a fix or CI fix: it adds **no decision item** compared with the
  commit it was made on (scope, must-not-touch, dependency files, size) —
  an automatic fix never puts a person's decision into a pushable commit;
- every repository check passes on exactly that commit, in a clean copy;
- the secret scan, over exactly the commits the push sends, finds nothing.

Otherwise the candidate is **discarded entirely** — the commit, its gate
results, its checks' copy and output — and the previous verified commit is
what's pushed (for the build itself: nothing is pushed).

### Review coverage and provenance

- The state block records the last head that received a **full review**
  (`review.head`) and every later head with its provenance (`heads[].by`:
  the hub, or people; a sync's merge also records `sync: {target,
  target_head, drift}`). *Built* (2.11.0, syncs 2.12.0).
- **Each head says what it is** (since 2.13.0): `kind` (`build`, `fix`,
  `sync`, `people`, `ci-fix`) and, for the hub's, `verified:
  {head, by}` — which check verified exactly which commit — and `at`.
- **Hand-off rule:** every commit after the last full review is a
  hub-generated commit with a passing fix check (a fix or CI fix), or a
  sync merge whose drift was mechanical and which passed Verify — each
  verified on exactly its own commit. Otherwise — a person's commit, a sync
  that changed relevant code — the pull request shows what the review
  covered and isn't handed off until a run reviews the current head.
  *Built* (2.13.0; [Hand-off](#hand-off)).

### CI semantics

Only GitHub's own result counts, for the exact commit being handed off.
*Built* (2.13.0; CI fixes 2.14.0) except where noted: v1 reads the head
only.

| Situation | Result |
|---|---|
| Every check GitHub marks required (`isRequired`) succeeded on the evaluation commit (the test merge commit if it has statuses, else the head) | Green |
| A required check succeeded on an older head or an obsolete merge commit | Doesn't count |
| Pending | Wait; past a time limit, a person (noting a path-filtered required workflow may never run) |
| Required check never appears | As pending |
| Failure | The CI-fix path (2 per hand-off, each a full candidate as above), then a person |
| Timed out, cancelled | A person (or a re-run where the repository allows it); never a CI fix on its own |
| Skipped, neutral | Acceptable only where GitHub itself treats them as passing for a required check |
| Action required | A person |
| GitHub's API fails | Retried (2.7.3), then the run stops without deciding; the next wake-up reads current state |
| Branch protection or rulesets change while waiting | Each wake-up re-reads what's required now; nothing is cached |

### Decision items: ownership

| Item | Created by | Belongs to | Closed by |
|---|---|---|---|
| Gate decision (`D`) | The gates, on a generation's head | The (path, reason) on that head | The change no longer having it on a later head, or a person accepting it (`/apply D3` or a resolution); an accepted one stays accepted unless that path changes again |
| Review or fix-check decision (`D`) | The review or fix check of a generation | That finding | A person (`/apply` by id, or dismissing it) |
| "Review didn't finish" (`D`) | The hub | That generation | A later run that reviews the current head |
| Manual change (`C`, from the plan) | The approved plan | The plan | A person making the change (the branch contains it) or `/skip` |
| Review items (`R`, `M`) | The review, fix check, people's review comments | Their finding or comment | `/apply` or `/skip`; resolved items never return |

Ids are never reused. An item from an older generation is carried forward
only if it still holds on the current head (marked "since generation N"),
otherwise closed as resolved by a change — an old unresolved item never
silently disappears, and a resolved one never blocks. Hand-off needs no open
`D` items (manual changes excepted: the hand-off says they're outstanding).
*Built:* items and their ids (2.5.0, review items 2.9.0); *planned:*
carrying across generations and closing (2.11.0, `reconcile_items`), `/apply` and `/skip` (step 5).

### `/apply` freshness

An `/apply` is valid only against the pull request's **current head** and
the item list derived for it. A run started by `/apply` first re-derives the
items on the current head (a person may have pushed since), then applies
only the requested items that still hold there; any that don't get a reply
("no longer applies at <commit>") and nothing else changes. It never applies
an old finding blindly to newer code. *Planned* (step 5).

### Failure classes

Every stop names its class — in the outcome, the failure comment's "To try
again" line and the run summary — so the way forward fits the cause.

| Class | Examples | Outcome | The way forward |
|---|---|---|---|
| Transient | An API failing after its retries, a runner problem | failed | Retry the run |
| Setup or settings | A missing tool, the Claude Code version, the sandbox unavailable, an invalid setting | failed, before Claude | Fix the runner or setting, then retry |
| Base already broken | The repository's checks fail on the target (baseline) | failed, before Claude | Fix the repository first |
| Plan or approval changed | A plan uploaded or the work order edited after approval | stale (sent back) | Revise and approve again |
| A person must decide | Questions; decision items | sent back; items on the pull request | Answer or resolve, then approve or apply |
| The agent couldn't finish | No usable result, a pass's budget cap, a criterion not covered | failed | Retry; raise that pass's budget if it recurs |
| The build's checks failed | The repository's checks on the build's commit | failed (output on the ticket) | Retry, or revise the plan |
| Supply chain or security | A dependency too new, unsigned, vulnerable or unlicensed; a secret found; a hard link; a refused file | failed | **Investigate** — don't simply retry |
| Budget exhausted | Run admission | blocked | A person lifts the cap |
| Existing branch or pull request | A previous build's branch or pull request | failed (exact instructions) | As the comment says |

*Built:* the outcomes and per-reason instructions (2.7.2, blocked 2.8.0).
*After v1:* the class named explicitly in the comment and summary ([After v1](#after-v1)).

## Safety

### Who can do what

| Actor | Can | Can't |
|---|---|---|
| Build and fix agents | Edit files in the checkout (not refused paths; a dependency declaration only as the plan describes); run commands in the sandbox (localhost network only) | Push, call GitHub or Jira, install packages or reach a registry, read outside the repository, reach the internet, see any credential |
| Review and fix-check agents | Read the repository; run tests in the sandbox | Edit anything |
| Install step (no agent) | Install dependencies from the lockfile (frozen), registries-only network, in the hub's sandbox | Change manifests or lockfiles; read the home folder; see any credential |
| Verify step (no agent) | Commit the agent's changes; run the repository's checks on a clean copy of that commit, in the hub's sandbox, localhost-only network | Push; read the home folder; see any credential; change which checks run (they come from the base commit) |
| Dependency step (no agent, before the agent) | Apply exactly the plan's dependency changes (npm): write their ranges, resolve the lockfile without install scripts and with a minimum release age, then check signatures and provenance; registries-only network (and Sigstore's trust metadata for the signature check), in the hub's sandbox | Apply anything the plan doesn't list; run install scripts while resolving; read the home folder; see any credential |
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
(GitHub-owned too), kept current by Dependabot in the hub's repository and
reaching others with hub releases · **an exact, pinned Claude Code
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
| `stages/build/` | `stage.sh`, `prompt.md`, `schema.json`, `settings.sh`, `contract.jq` (the plan's contract), `gates.sh`, `pr-body.jq` (the pull request template), `wording.jq` (wording the pull request and the ticket's report share, and the items); later `ci-fix/` |
| `stages/build/fix.sh`, `stages/build/fix/`, `stages/build/fix-check/` | The fix pass, the fix check and Verify fix (2.10.0); each pass's `prompt.md` and `schema.json` |
| `stages/build/closed.sh`, `.github/workflows/agent-hub-pr-closed.yml` | A hub pull request closed (2.15.0): Done only if the hub handed it off and it was merged; otherwise a comment |
| `stages/build/commands.sh`, `stages/build/apply/` | Item commands from the ticket (2.16.0–2.17.0): `/skip` and `/apply`, the approvers check, the `/apply` fix's instructions |
| `stages/build/ci-fix/` | The CI-fix pass's instructions (2.14.0); its schema is the fix pass's |
| `stages/build/handoff.sh`, `lib/ci.sh` | The CI gate and the hand-off (2.13.0): the required checks for exactly the head, the hand-off rule (`handoff_problems`), reporting to a person once per head |
| `stages/build/sweep.sh`, `.github/workflows/agent-hub-ci-sweep.yml` | The CI sweep (2.13.0): every 10 minutes, requests the build (CI gate only) for the hub's draft pull requests whose checks have finished |
| `stages/build/reconcile.sh` | Reconciling an existing pull request (2.11.0): integrity, superseded, people's commits, the state and status rewrite; syncing with a moved target (2.12.0): the merge, drift, conflicts |
| `lib/toolchain.sh` | The Node version a repository declares, for the workflow's setup-node step and the fetch step's check |
| `stages/build/dependencies.sh` | The dependency step: the folders installed, the plan's dependency changes applied and checked, the result for the gates and the report |
| `lib/sandbox/` | The hub's sandbox for the install and verify steps: `sandbox.sh` (policies, time limit, a clean environment) and the lockfile `srt` is installed from (per job, from npm's download cache in the runner's tool cache, checked against the lockfile every time; Dependabot keeps it current in the hub's repository, and hub releases carry it to others) |
| `stages/build/review.sh`, `stages/build/review/` | The code review step (2.9.0), and its `prompt.md`, `schema.json` (findings: area, severity, kind, file and line, evidence) and `policy.json` (kind × severity → fix pass, `R` or `D`), `settings.sh` |
| `lib/github.sh` | The GitHub interface; one `gh_request` function every call goes through (mocked in tests) |
| `lib/runners/claude-code.sh` | Tool profiles (`read-only`, `build`, `review`) and the sandbox settings |
| `agent-hub-relay.yml` | No agent: a review submitted, or a pull request comment `/apply` `/skip` → a numbered acknowledgement; wakes the per-ticket run |
| `agent-hub-ci-result.yml` | No agent: CI completed for an `agent-hub/*` head → wakes the per-ticket run (metadata only) |
| `agent-hub-pr-sync.yml` | No agent: pull request approved, merged or closed → wakes the per-ticket run (post-merge check, Done) |
| Extensions | The `build/` folder as for every stage (its `review.md` is the code review's and fix check's checklist; [architecture.md](../architecture.md#agent-passes)); `build/guidance.md` is where a repository says how to install, test and build, and lists sensitive and drift-sensitive paths; `build/checks.json` lists the checks the verify step runs, when the `package.json` scripts aren't the right ones |

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
  remove `needs-human` (closing the known gap in [jira.md](../jira.md)) and dispatch the build.
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
| Boundary checks | `scripts/check-sandbox.sh`: real Claude Code against hostile settings and sandbox escape attempts, results checked on disk ([runners.md](../runners.md#checking-the-sandbox)) | Yes, about $0.30, confirmed with `use-claude` |
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
PR 4 (the reason is in [Building it](#building-it)) · for 4c (decided 2026-10-08): **a merge conflict when syncing goes to a
person** (an agent resolving conflicts is a later item), and **semantic
drift is re-checked by the code review on the merged commit**, not a
separate plan re-validation pass · in 2.8.0: **per-ticket caps across every stage**,
kept by the tracker on the ticket (a Jira issue property), not in the state
block — a run that never opens a pull request, and the document stages,
count too; a person lifts them by removing the over-cap label · in 2.7.2: **people
merge, on GitHub**, under branch protection; the hub has no merge
capability. It observes the merge, checks the merged head is the one it
recorded (the post-merge check under
[Revisions and reverse paths](#revisions-and-reverse-paths)) and moves the
ticket to Done. Automating more of that is a [later](#later) item.

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
   - *3d-1* (done in 2.6.3): the [baseline](#baseline) before Claude;
     gitleaks' release archive kept in the runner's tool cache and checked
     against its pinned checksum on every job; the sandbox runtime installed
     per job from npm's download cache (checked against the lockfile on
     every install), instead of trusting a copy another job on the runner
     could have changed.
   - *3d-2* (done in 2.7.0): the dependency step, resolved **before** the agent (changed in
     2.6.3 from resolving after it, which left the agent writing code against
     a package it couldn't install or test). The plan names each change
     exactly — manifest folder, package, version range, runtime or dev, add,
     update or remove — and the install step applies exactly those with the
     package manager, in the sandbox with registries-only network: resolved
     without install scripts, then installed in the sandbox (where new
     packages' scripts get the install step's limits). The agent starts with
     them installed; the gate then requires the commit's manifest and
     lockfile to be byte-for-byte what the hub produced. Also: a minimum
     release age (3 days by default) for every resolved version, refusing —
     a decision item — where the package manager can't enforce it; registry
     signatures checked, and provenance where a package publishes it; the
     release age, the registry source and the licence (an allowlist) checked
     for every new version, transitive ones too; vulnerabilities compared
     advisory by advisory (a new high or critical one blocks); the install
     proven not to change the resolved lockfile; a lockfile format change a
     decision item, and the lockfile's added, changed and removed packages
     counted in the pull request (the policy, and what an external review
     changed: [Dependencies](#dependencies-planned-changes-only)). A plan with the
     dependency flag but no exact list stays a decision item. **Built for
     npm only** (planned for npm, pnpm and Yarn): pnpm's and Yarn's release
     age settings exist only in their newest versions and the signature
     check is npm's, so — rather than resolve without the guards — a pnpm or
     Yarn project's changes stop the build before Claude ([Dependencies](#dependencies-planned-changes-only)).
     With it, the install covers subfolder projects (the dependency
     changes' folders, and `build/checks.json`'s `install` list), which
     3c's install step didn't.
   - *Moved to PR 4:* reconciliation of an existing pull request. Until the
     review, fixes and the CI gate, nothing happens to a hub pull request
     after it opens except a person closing it, which the build already
     handles; and reconciliation trusts the state block, which needs the
     recorded edit-history fixtures below first.

   **The preview gate stays until PR 4** (changed in 2.6.0; the earlier plan
   removed it after 3c). With 3c a build no longer depends on what the
   runner happens to have, and the hub checks its own commit — but a person
   is still the build's only reviewer, and nothing yet re-checks a pull
   request after people or later runs push to it. The gate comes off with
   the review, the CI gate and the hand-off, and **only once the runner is a
   dedicated user, machine or GitHub-hosted** — a blocker, not a
   recommendation ([Later](#later)). Since 2.7.2 a run warns when the
   runner's user also runs Claude Code outside the runner.
4. **Review, fix, CI gate, hand-off** — the review with its policy table; the
   fix pass, fix check and second verify; review coverage; sync and drift; the
   CI-result workflow, the evaluation commit (head and test merge commit both
   covered), conservative classification and CI fixes; hand-off eligibility.
   With it, reconciliation of an existing pull request (moved from 3d).
   In four parts (decided after the pre-PR 4 review): *4a* (2.8.0, 2.8.1) the
   prerequisites below; *4b* the review (2.9.0: findings become items, no
   automatic changes), then the fix pass, fix check and second verify, with
   its eval case (2.10.0); *4c* an existing pull request — reconciliation,
   integrity, superseded builds, people's commits and review coverage
   (4c-1, 2.11.0), then syncing with a moved target and drift (4c-2, 2.12.0); *4d* the CI gate (after
   a spike on the CI-result mechanism) and the hand-off (4d-1, 2.13.0), then CI fixes (4d-2, 2.14.0). The
   preview gate comes off after 4d, once the runner blockers are met.
   2.10.1 fixed the post-4b review's findings; 2.10.2 wrote down the
   [Contracts](#contracts) 4c, 4d and step 5 are built and reviewed against —
   each of their pull requests says which contracts it implements, and adds
   tests for them.
   **Prerequisites, before the review pass or reconciliation is enabled**
   (from the 2.5.0 reviews):
   - *A read-only review profile, proven* (done in 2.8.1). The review profile drops the
     file-editing tools, but its sandbox didn't deny shell writes to the
     checkout (Claude Code's default allows the working directory). Since
     2.8.1 it denies the repository explicitly (a temp folder stays writable
     for test output: tests that write into the repository fail in the
     review, which then reports it), and the sandbox check runs the review
     profile (a shell redirect, `touch`, a child process, the file tools):
     all held on Claude Code 2.1.285, macOS.
   - *A spend cap per ticket* (done in 2.8.0, 4a). Each run has its own
     budget, but a ticket's runs (retries, revisions, the review and fix
     passes) added up with nothing stopping them. The hub now records each
     run's cost on the ticket and stops before Claude at the caps
     ([claude-usage.md](../claude-usage.md#per-ticket-caps)).
   - *GitHub's edit-history format, recorded* (done in 2.8.1).
     `gh_pr_body_versions` reads each `userContentEdit.diff` as the whole
     description after that edit, and the test mock assumed the same. Real
     responses recorded from a scratch pull request (creation, an edit
     outside the state block, an edit to it, a third, and a revision deleted
     in the web page) confirmed it byte for byte
     (`tests/shared/fixtures/github-edit-history`), and showed that a deleted
     revision keeps its entry with its text replaced by `deleted` — now
     treated as history that can't be checked, so the block isn't trusted.
     The newest version must equal the description the API returns. Still
     unrecorded: a machine user's and a person's edits side by side (needs
     the machine user).
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
| Merge, branch clean-up and the Jira moves after a person's approval | v1: a person merges on GitHub, deletes the branch (or GitHub's "Automatically delete head branches" setting does) and the hub moves the ticket to Done. Worth automating **if it can be done safely and securely**: the merge would still follow a person's approval and GitHub's own rules (required reviews, checks, rulesets), never the hub's judgement, and the token able to merge would be scoped to that alone. Investigate after v1, alongside merge-queue support. Distinct from risk-based autonomy (Not planned), where the hub would decide |
| Merge-queue support | v1 detects a merge queue and says it's unsupported; people merge |
| Resuming a run that reached its budget cap | Today a retry starts the pass again (sessions aren't saved, by design). Keeping a capped build's work-in-progress — privately, for the next run to continue from — would save the spend already made; it needs the same isolation as sessions |
| HMAC-signed state | If lower-trust writers ever appear |
| A durable per-ticket run history beyond the pull request and ticket | Run logs expire after about 90 days |
| Richer repository capability detection | Beyond commands, required checks and visibility |
| An expanded eval suite | Beyond the single build case |
| More than one pull request per ticket | Nothing in v1 assumes one |
| GitHub Projects as the tracker for the build | Follows the Jira version |
| Other AI providers (a second agent runner: OpenAI's Codex CLI, Google's Gemini CLI, …) | **A dedicated task after PR 4**, once every workflow is in place: the agent runner interface (`lib/runners/`) already lets one be added; the plan will list what's Claude-specific today (restricted mode, the agent's sandbox, plugins, prompts, budgets, evals), set the guarantees any runner must give as a written, tested contract, and assess each provider's CLI against it. Until then the pre-PR 4 review only flags anything that would make it harder |

### After v1

v1 is the minimum that completes the flow; it's hardened once the pipeline
test shows it works (agreed 2026-10-08, after an external review of the
plan). These are deferred, not dropped — v1 keeps the data they'd build on
stable (the state block's identity, generation, heads and provenance):

| Item | Notes |
|---|---|
| A written state model | The states and transitions across Jira, the pull request and runs, as a table |
| An invariants section | The rules that hold everywhere, in one place (no silent scope expansion; unverifiable outside state changes nothing; a stale run changes nothing; tests are evidence, not authority) |
| A failure and recovery matrix | Every failure — including a runner dying, a cancelled run, Jira or GitHub down — with its outcome and whether a rerun is safe; the class named in each failure comment |
| A production checklist | What must hold before the preview gate comes off, checked item by item |
| Hand-off without CI (opt-in) | A setting to hand off on the hub's own Verify when the target requires no checks, saying so on the pull request and ticket; today such a pull request is never handed off (decided 2026-10-08: as-is for v1) |
| Evidence and retention | What's kept, where and for how long (today: the state block, the ticket's comments and its usage record are durable; prompts, responses and sessions aren't kept; run logs expire) |
| Adversarial, race and recovery tests | Prompt injection in the ticket and repository, an unauthorised `/apply`, duplicate and stale events, cancellation mid-run |

**Never** (complexity v1 and later don't need): a general locking system
(one queue per ticket is the rule) · a state-machine framework · an audit
platform (the pull request, git, the ticket and run summaries are the
record) · CI failure categories that don't change what happens (fixable by
the CI-fix pass, or a person) · automatic recovery from unknown failures (a
person) · more tokens without a concrete privilege boundary to enforce ·
atomic budget accounting (the queue serialises a ticket's runs).

**Not planned:** deploys · migrations against real environments · hub-managed
preview environments · automatic reverts · risk-based autonomy (auto-merge) ·
changes across repositories · debating agents · unlimited retries.
