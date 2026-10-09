# Build — design record

The record behind the [build workflow](build.md): what it set out to do,
the contracts it's built against, the decisions and their reasons, the
risks and costs, how it was built, what comes after v1 — and what must hold
before it runs real tickets. [build.md](build.md) describes the stage as
built; where the two differ, build.md and the code are right, and this
record is history. Each release's changes are in the
[CHANGELOG](../../CHANGELOG.md).

## Production checklist

The preview gate (`AGENT_HUB_BUILD_PREVIEW`) comes off only once all of
these hold, checked one by one:

- [ ] **The manual test:** every path of the stage on a real ticket and a
      real repository — build, review and fix, CI gate and hand-off, a CI
      fix, `/skip` and `/apply`, a person's commits, a moved target branch,
      merge to Done — with the "couldn't assess" items from the reviews
      checked on the runner (agent writes to `.git/`, `.github/`, `.claude/`;
      Windows line endings after a browser edit; a burst of queued requests;
      the model ids; Jira's user groups endpoint).
- [ ] **The runner:** a dedicated runner user, machine or GitHub-hosted
      runners, not a personal account
      ([runners.md](../runners.md#before-running-the-build-on-real-tickets));
      the sandbox check passed on it.
- [ ] **Setup** ([setup.md](../setup.md)): the secrets in the `agent-hub`
      environment, limited to the default branch, and no repository-level
      copies; read-only default workflow permissions; required checks bound
      to the app that posts them (the CI gate warns about any that aren't);
      the dispatch token with Actions: read and write only.
- [ ] **Jira** ([jira.md](../jira.md#checklist-for-a-new-installation)):
      `AGENT_HUB_APPROVERS_GROUP` set — required for real tickets: without
      it every item command is refused and approvals rest on the workflow's
      conditions alone — with the service account able to read groups; both
      approval transitions restricted to people; Revision Requested limited
      to the people who work the tickets; the five rules on the
      `workflow_dispatch` URLs.
- [ ] **The CI sweep and the closed-pull-request workflow change with the
      gate:** both run only while `AGENT_HUB_BUILD_PREVIEW` is `true`
      (`agent-hub-ci-sweep.yml`, `agent-hub-pr-closed.yml`). When the gate
      comes off, change their condition in the same release, or hand-offs
      and Done stop silently.
- [ ] **The credentials' expiry dates** in a calendar, and someone who reads
      failed-run notifications ([setup.md](../setup.md#6-plan-for-credential-expiry)).

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
[Revisions and reverse paths](build.md#revisions-and-reverse-paths)) and moves the
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
     built ([Toolchain](build.md#toolchain)); the install step, frozen, in the hub's
     sandbox with registries-only network, with its probes against the real
     runtime — including that a package's lifecycle scripts and their child
     processes get the same limits as the package manager
     ([Install](build.md#install)); the deterministic verify step: the commit, then
     the repository's checks re-run by the hub on a clean copy of it, a
     failure meaning no push ([Verify](build.md#verify)); per-step time limits; the
     playground declaring its Node version (`playground/.nvmrc`) and its
     checks (`build/checks.json`).
   - *3d-1* (done in 2.6.3): the [baseline](build.md#baseline) before Claude;
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
     changed: [Dependencies](build.md#dependencies-planned-changes-only)). A plan with the
     dependency flag but no exact list stays a decision item. **Built for
     npm only** (planned for npm, pnpm and Yarn): pnpm's and Yarn's release
     age settings exist only in their newest versions and the signature
     check is npm's, so — rather than resolve without the guards — a pnpm or
     Yarn project's changes stop the build before Claude ([Dependencies](build.md#dependencies-planned-changes-only)).
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
| Other AI providers (a second agent runner: OpenAI's Codex CLI, Google's Gemini CLI, …) | **A dedicated task after v1**, once every workflow is in place: the agent runner interface (`lib/runners/`) already lets one be added; the plan will list what's Claude-specific today (restricted mode, the agent's sandbox, plugins, prompts, budgets, evals), set the guarantees any runner must give as a written, tested contract, and assess each provider's CLI against it. Until then reviews only flag anything that would make it harder |

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
| Support for any device | Today the hub runs on Linux and macOS runners, and its tests on Linux and macOS: Windows runners — and Windows contributors running the tests — aren't supported (the hub is Bash with a Linux or macOS sandbox; WSL is untested). For everyone who sets it up, whatever their machine: a supported Windows path, with its sandbox and its tests in CI |
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

## Designs behind the steps

The first designs of three steps, kept for the reasoning; [build.md](build.md) describes them as built.

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

### Review items and `/apply`


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

## Structure as first planned

What the first design listed and the build didn't need (the CI sweep and
the closed-pull-request workflow replaced the relay, CI-result and sync
workflows):

| Piece | What |
|---|---|
| `agent-hub-relay.yml` | No agent: a review submitted, or a pull request comment `/apply` `/skip` → a numbered acknowledgement; wakes the per-ticket run |
| `agent-hub-ci-result.yml` | No agent: CI completed for an `agent-hub/*` head → wakes the per-ticket run (metadata only) |
| `agent-hub-pr-sync.yml` | No agent: pull request approved, merged or closed → wakes the per-ticket run (post-merge check, Done) |

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
