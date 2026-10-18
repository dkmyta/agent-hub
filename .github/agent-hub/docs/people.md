# Working tickets with the agent hub

For the people on the tickets — requesters, delivery leads, approvers and
reviewers — not for setting the hub up ([setup.md](setup.md)). What happens
to a ticket, what the hub's comments mean, who can do what, and what to do
when something needs you. The details behind each answer are in
[jira.md](jira.md) and the [workflow pages](workflows/).

## The life of a ticket

| Status | What's happening | What you do |
|---|---|---|
| **Intake** | You fill in the request (the description's template). The hub checks it has enough to go on | Add details if a ⚠️ *Needs details* comment asks |
| **Work Order** | The hub writes a work order into the description (⏳ while it works) | Review it; `/revise` what should change, or edit it yourself |
| **Work Order Approved** | An approver moved it here; the hub writes an implementation plan | Wait, or answer its questions if it sends the ticket back |
| **Implementation Plan** | The plan is attached (`KEY-implementation-plan.md`) and summarised on the ticket | Review it; `/revise`, or edit and upload the file yourself |
| **Implementation Plan Approved** | An approver moved it here; the hub builds it as a **draft pull request** (🔨), reviews and fixes its own work, and waits for your CI | Act on its items if any need you (below) |
| **Ready for Review** | Every required check passed and nothing blocks it: the pull request is marked ready (✅) | Review the code and merge it on GitHub |
| **Done** | The hub saw the pull request merged after its hand-off | Nothing |

People approve each stage and merge; the hub never approves, and never
merges.

## Who can do what

| | Who |
|---|---|
| `/revise` | The people your Jira rule allows (the approvers group, or a wider group of contributors) |
| Moving a ticket to Work Order Approved or Implementation Plan Approved | Approvers (the `agent-hub-approvers` group) |
| `/skip`, `/apply` | Approvers — anyone else's command is answered, naming them, and nothing is done |
| A review comment that `/apply comments` takes | Anyone with write access to the repository, the token's owner included |
| Merging | People with merge rights, under the repository's branch protection |

## Items on the pull request

The pull request's description lists **Items for a person**, each with an
id that's never reused:

- **D — a decision.** Something the hub won't decide for you: a change
  outside the approved plan, a removed test, the review not finishing.
  **An open D item blocks the hand-off.** Fix it (`/apply D1`) or accept it
  as it is (`/skip D1`).
- **R — a review finding.** Advisory: it doesn't block. Fix it
  (`/apply R2`, or `/apply all` for every open R item) or `/skip R2`.
- **C — a manual change** the plan says a person makes (a setting, a
  secret). Make it; the hand-off says it's outstanding.

Statuses: **open**, **fixed** ("fixed in `<commit>`, checked" — by the hub's
fix pass or an `/apply`), **skipped** or **accepted** (by an approver, who
and when kept on the ticket), **closed** (a later change resolved it).

**After new commits, the hub reviews the code again.** Since 2.28.0 the
review is told what approvers already skipped or accepted, so it doesn't
raise those again unless the code they concern changed; a new item that
looks like one you decided says so ("like R5, skipped by …"), and you
decide again only if it's really new.

## Commands

Comment on the **ticket**, as a **new** comment (an edited comment isn't a
new command). The first paragraph holds only the command and its ids; a
reason can go in a following paragraph, for people.

| Command | When | What happens |
|---|---|---|
| `/revise <what to change>` | Intake to Implementation Plan | The work order or plan is revised; each request is answered (🔁) and marked ✅ Resolved. `/revise` on its own retries a failed run |
| `/skip D1 R2` | Once the pull request exists | The items are closed — a D *accepted*, any other *skipped*. No Claude. A pull request whose only blocker was a D item can then be handed off |
| `/apply R2 D1` | Once the pull request exists | Those items are fixed, checked and pushed |
| `/apply all` | Once the pull request exists | Every open R item (never a D) |
| `/apply comments` | Once the pull request exists | The pull request's unresolved review threads from people with write access; each gets a reply and is resolved when fixed. Resolve the ones you don't want first |

Every command is answered once, on the ticket: the comment is marked ✅
*Resolved* with what was done (or why not), struck through so it isn't read
again. Combine them: `/apply R2 comments`.

## What the hub's comments mean

| | Means |
|---|---|
| ⏳ | Working on it (replaced or removed when it's done) |
| 🔨 | The draft pull request is open, with the build's report |
| ✅ | Done: *Ready for review*, *Resolved* (a command or request), *Done*, *Answered* |
| 🔁 | Something was revised or re-checked: change requests handled, a pull request re-checked after new commits, or synced with the target branch |
| ↩️ | *Back to draft*: commits after the hand-off undid it until checks pass again |
| ⚠️ | Needs you: *Needs details*, *Needs clarification*, *Merge conflict*, *Build superseded*, … — the comment says what |
| ❌ | A run failed: its **Why:** line says why, and how to retry |
| ⛔ | The ticket's Claude usage cap is reached: a person decides whether to raise it |
| 🔍 | *No change needed*: the build found the plan's change is already there |

## What do I do when…

- **A D item blocks the hand-off** — read it under *Items for a person*,
  then `/apply D1` to fix it or `/skip D1` to accept it.
- **CI failed on the hub's commit** — the hub tries to fix it (up to two
  attempts by default) and says so. If it can't, a person fixes the cause:
  push a commit to the branch, then run the build (next item).
- **I pushed a commit to the pull request** — the hub reviews people's
  commits when the build next runs: **Actions → Agent hub: Build → Run
  workflow** with the ticket key. A pull request already handed off goes
  back to draft (↩️) until the review is done and CI passes on it.
  `/apply` is refused until then (it only works on code the hub reviewed).
- **The target branch moved on** — the next run merges it in. If nothing it
  changed touches the pull request, that's all; if it overlaps, the whole
  change is reviewed again.
- **⚠️ Merge conflict** — the hub stops updating the pull request. Merge the
  target branch into the pull request's branch, resolve the conflicts, push,
  then run the build.
- **My command was refused** — its answer says why: not an approver, not an
  item id, the item isn't open, the pull request is paused, or someone
  pushed since the last review.
- **The Testing Instructions look out of date** — since 2.28.0, a note says
  so when code changed after they were written (by people's commits, a
  merge, a CI fix or an `/apply`): check each step against the current code.
- **I edited the ticket after the plan was approved** — a change to its
  title, the work order or the plan file means the approval no longer
  covers it: the build stops, and says why, until it's approved again.
  Comments and the hub's own Delivery sections don't count.
- **I want the hub to leave the pull request alone** — add the
  `agent-hub-paused` label; remove it to let it carry on.
- **The pull request was closed without merging** — the ticket gets a
  comment and never moves to Done.
- **I need the current state** — the pull request's description (status,
  items, what changed) and the newest hub comments on the ticket; each run's
  summary on GitHub has the details and costs.

Reverse paths for the work order and plan (sending a ticket back, starting a
plan over, approved by mistake): [jira.md](jira.md#reverse-paths-sending-back-and-asking-for-changes).
