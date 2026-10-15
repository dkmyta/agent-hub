# Live tests

A repeatable procedure for testing the agent hub end to end against real
systems: a real tracker, GitHub, the runner, its sandbox and Claude. The
automated suite (`.github/agent-hub/tests/`) proves the hub's logic against
mocks, and makes no live tracker, GitHub or model calls; only a live test
shows the integration works: permissions, tracker rules, real API
behaviour, the sandbox on the real runner, and real model output.

This folder is for the hub's own repository. It sits outside
`.github/agent-hub/`, so `update.sh` never installs it into a project.

    README.md                 this file: how a live test runs
    journeys/                 the journeys: steps and what to check, in tracker-neutral terms
    trackers/<tracker>.md     what each tracker action means in that tracker
    fixtures/                 the tickets and planted changes the journeys use
    evidence-template.md      what each run records

## When to run one

- Before the build's preview gate comes off, and before a release that
  changes how the hub talks to a tracker, GitHub or the runner.
- After setting up a new tracker, to show it matches the ones already
  verified: run the same journeys against it.
- Not for every change: the automated suite and CI are the merge gate
  (`.github/agent-hub/CONTRIBUTING.md`).

## Who does what

- **A person** creates the tickets, approves, comments the commands, merges
  pull requests, and makes the planted commits as a person. Approvals must
  be a person's: the hub checks that.
- **The stages** use Claude. Nothing in this folder does: no script here
  calls Claude, and the journeys never start Claude by any other route.
- **Stages are started by hand where they can be** (`gh workflow run`), to
  save tracker automation. That doesn't stop the tracker's rules: every
  comment and update the hub writes still starts the tracker's triggers,
  and they count towards its automation allowance even when their conditions
  stop them.

## Where it runs

In a **separate test repository** with the hub installed by `update.sh`
(for example `dkmyta/agent-hub-live-test`, with the playground copied in),
never the hub's own repository:

- Its main branch can take throwaway changes, which the journeys need (a
  moving target, a conflict), without changing the hub's history.
- It exercises the installed copy: `update.sh`, the install record and the
  consumer contract checks.
- Its own runs, pull requests and checks keep test evidence apart from real
  work.

It shares the tracker project with real work, so **the tracker must send
each ticket to exactly one repository**: test tickets carry the
`agent-hub-live-test` marker and go only to the test repository; every other
ticket only to the hub's. How that's set up for a tracker is in its file under
`trackers/`, and the first journey checks it before anything else.

## Vocabulary

The journeys say what to do and what to check in these terms; each
tracker's file says what they mean there.

**Actions**

| Term | Meaning |
|---|---|
| `create-ticket <fixture>` | A new ticket from a ticket fixture, with the live-test marker from the start |
| `edit-request` | Change the ticket's request text (the description) |
| `comment <text>` | A comment on the ticket, as a person (`/revise …`, `/skip …`, `/apply …`) |
| `approve-work-order` | Move the ticket to Work Order Approved |
| `approve-plan` | Move the ticket to Implementation Plan Approved |
| `send-back <status>` | Move the ticket back to an earlier status |
| `start <stage>` | Start a stage by hand for the ticket (`gh workflow run`), when the tracker's rule isn't what's being tested |

**Observations**

| Term | Meaning |
|---|---|
| `status` | The ticket's status (the hub's status names) |
| `labels` | The ticket's labels: `needs-human`, `needs-details`, `needs-clarification`, `agent-hub-over-cap` |
| `comment "<marker>"` | A comment the hub posted, found by its marker ("⏳ Generating work order", "✅ Resolved", "🔁 Change requests …") |
| `section <name>` | A section of the work order in the description |
| `plan file` | The plan attached to the ticket, and its summary in the work order |
| `hub records` | What the hub keeps on the ticket: the usage ledger, the kept review, the handled commands |
| `run` | A GitHub Actions run: workflow, run name, conclusion, attempt, the repository it ran in |
| `pull request` | Draft or ready, head commit, the state block's fields (heads, review, items, ci, handoff), comments, threads |

## Running a journey

1. Check what it needs first (each journey's **Before you start**).
2. Copy `evidence-template.md` to a new file outside the repository (it can
   hold ticket content; ticket text never goes into the repository).
3. Follow the steps in order. After each, check every observation and
   record it: passed, failed, waiting, blocked or inconclusive, with the run
   ids and commits.
4. A failed observation stops the journey unless the step says otherwise.
   Record what happened, then decide: fix the hub, or fix the journey.

## Cost

Each journey lists an estimate, not a cap: the tickets' own caps
(`AGENT_HUB_TICKET_MAX_RUNS`, `AGENT_HUB_TICKET_MAX_COST_USD`) are the hard
limit. The estimates come from the October 2026 manual tests (one ticket
from request to merge, with a conflict, took four Claude runs and a build:
about $1.55, API-equivalent) and are refined from each run's evidence.
Tracker automation runs are listed per journey too.

## Adding a tracker

1. Write `trackers/<tracker>.md`, mapping every action and observation
   above, plus its routing and its permissions.
2. Run the journeys against it. A journey whose steps can't be expressed
   in that tracker is a gap in the tracker's support, not in the journey.
3. Add the tracker to each journey's **Trackers verified** line, with the
   date and hub version.
