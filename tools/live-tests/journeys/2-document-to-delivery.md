# Journey 2: from document to delivery

From an approved plan to a merged pull request and a finished ticket: the
build, its review, the CI gate, the hand-off, the merge.

| | |
|---|---|
| Covers | Plan approval checked; build, verify, review, fix pass; the draft pull request and its record; the CI gate; hand-off; merge → Done; the branch deleted |
| Mocks already cover | Every path (`tests/build/`); live adds the runner's sandbox, real Claude Code, GitHub's branch protection and checks, the CI sweep's schedule, the tracker's transitions and permissions |
| Estimated cost | About $0.50–2 of Claude: the build, its review and fix pass. 3–5 tracker automation runs |
| Trackers verified | — (written 2026-10-15, hub 2.24.0) |

## Before you start

- **The setup checker passes in the test repository** (`.github/agent-hub/scripts/check-setup.sh --jira-project <KEY>`): nothing blocked; anything unverified checked by hand. Keep its output with the evidence.
- [Journey 1](1-planning-and-revision.md) finished on this ticket, or any
  ticket in Implementation Plan with a plan for
  [reverse-words](../fixtures/tickets/reverse-words.md).
- The test repository: `AGENT_HUB_BUILD_PREVIEW=true`; the build token is a
  machine user's, not yours (with your own, `/apply comments` in journey 3
  can't be tested); main protected with required checks (the playground's
  tests and **Agent hub: Test**).
- The runner's sandbox check passed on this Claude Code version
  (**Agent hub: Sandbox check**, or `scripts/check-sandbox.sh`).

## Steps

**1. Build.** `approve-plan`.

- `run` "Build: <KEY>" in the test repository, success.
- `pull request` draft on `agent-hub/<KEY>`; its record lists one head (the
  build's, verified on exactly that commit), a finished review of that
  head, and the items found.
- The run summary shows each pass's cost (build, review, fix and fix check
  if there were findings).
- `status` still Implementation Plan Approved; only the progress comment
  changed on the ticket.

**2. Review and fix pass.** (The same run.)

- Each review finding is either fixed by the fix pass (a `kind: fix` head,
  verified on its own commit) or listed as an item for a person (R, D or C).
- No refused file changed (`.github/`, `.claude/`, `CODEOWNERS`).

**3. CI gate.** Wait for the pull request's checks to finish, then run the
CI sweep by hand (`gh workflow run agent-hub-ci-sweep.yml -R <test repo>`:
its schedule is often hours late).

- `run` "Build: <KEY> (CI gate)".
- If any item for a person is open: not handed off, and the pull request
  says why. Close it with `comment` `/skip <ids>` and run the sweep again.
  If CI failed on the hub's commit: a CI fix (a `kind: ci-fix` head), then
  CI again.

**4. Hand-off.**

- `pull request` ready for review; its record's hand-off `complete` on the
  head whose checks passed.
- `status` Ready for Review; `labels` `needs-human`; a comment on the ticket
  and on the pull request.

**5. Merge.** Approve and merge the pull request in GitHub, as a person.

- `run` "Build: <KEY> (pull request closed)".
- `status` Done; no `needs-human`; the branch deleted.
- `section` Pull Request: "#<n> — merged (<commit>), on <date>".

**6. Records.** The `hub records` list each run, the commands handled, and
who skipped what; no reservation left pending.
