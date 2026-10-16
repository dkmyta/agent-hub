# Jira setup

Everything the agent hub pipeline needs from a Jira project, in one place: the
board, work type, statuses and transitions, labels, the automation rules in
full, how to send a ticket back or ask for changes, permissions, and
recommendations. Names shown are the defaults; status
and label names can be changed per repository with variables (see
[setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)).

Jira is the supported tracker. GitHub Projects is a possible alternative, not
yet decided ([trackers.md](trackers.md)). For the people working the tickets:
[people.md](people.md).

The examples assume a **team-managed** project. In a company-managed project
the same settings live in the workflow scheme and permission scheme.

## Board, work type and intake template

- **Work type:** the pipeline handles **Task** tickets. Every rule checks for
  it, so other types (bugs, epics, …) are left alone.
- **Intake template:** the Task type's description template holds only the
  fields the requester fills in:

  ```
  Original Request:
  What's Needed:
  Why / Context:
  Workstream:
  Known Constraints:
  Source / Email Thread:
  ```

  The work order replaces it once written; the original is kept as a comment.
- **Board columns**, one per status, in pipeline order:
  **Intake** (the initial status new tickets land in) → **Work Order** →
  **Work Order Approved** → **Implementation Plan** → **Implementation Plan
  Approved** → **Ready for Review** → **Approved** → **Done**.
  Board → ⋯ → Configure board → Columns.

## Statuses

| Status | Who moves the ticket here | `needs-human`? |
|---|---|---|
| **Intake** | New tickets start here; the work-order stage returns tickets needing detail | No — waiting on the requester |
| **Work Order** | The Work Order Requested rule (has details); the Revision Requested rule (details added in a comment); the plan stage returns tickets needing clarification | Yes, once the work order is written |
| **Work Order Approved** | A person, after reviewing the work order | No — the rule removes it |
| **Implementation Plan** | The plan stage (a revision keeps it here) | Yes |
| **Implementation Plan Approved** | A person, after reviewing the plan | No — the [Build Requested](#rule-build-requested) rule removes it and starts the build; the build adds it back when its draft pull request needs a person, or when it can't go ahead |
| **Ready for Review** | The build, when its pull request passes every required check and is handed off (since 2.13.0) | Yes — a person reviews the code |
| Approved | A person, after approving the pull request (optional) | — |
| **Done** | The build, when the hub's pull request it handed off is merged (since 2.15.0) | No — the build removes it |

**The names must match exactly**, capitals included: the hub finds
statuses by name, so a status called "Ready For Review" isn't "Ready for
Review", and the hand-off fails with "no transition to 'Ready for Review'".
Rename the status in Jira (the workflow editor, or the board column's **⋯ →
Rename status** in a team-managed project; renaming keeps its tickets and
transitions), or set the matching repository variable to your name:
`AGENT_HUB_INTAKE_STATUS`, `AGENT_HUB_WORK_ORDER_STATUS`,
`AGENT_HUB_WORK_ORDER_APPROVED_STATUS`, `AGENT_HUB_IMPLEMENTATION_PLAN_STATUS`,
`AGENT_HUB_IMPLEMENTATION_PLAN_APPROVED_STATUS`,
`AGENT_HUB_READY_FOR_REVIEW_STATUS`, `AGENT_HUB_APPROVED_STATUS`,
`AGENT_HUB_DONE_STATUS` ([setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)).
To check the names: [Checking the setup](#checking-the-setup).

## Transitions

| From → To | By |
|---|---|
| Intake → Work Order | Automation (Work Order Requested rule, or Revision Requested rule) |
| Work Order → Intake | Automation (needs details) |
| Work Order → Work Order Approved | People |
| Work Order Approved → Implementation Plan | Automation (plan written) |
| Work Order Approved → Work Order | Automation (needs clarification) |
| Implementation Plan → Work Order Approved | People — to re-plan from scratch (e.g. after the code changed) |
| Implementation Plan → Work Order | People — to change the work order first; automation — a plan revision that needs a product decision |
| Work Order → Intake, Implementation Plan → Intake | People — the request itself changed (see [Reverse paths](#reverse-paths-sending-back-and-asking-for-changes)) |
| Implementation Plan → Implementation Plan Approved | People |
| Implementation Plan Approved → Implementation Plan | Automation (the build has questions, or the plan changed after its approval); people — to revise the plan |
| Implementation Plan Approved → Ready for Review | Automation — the build's hand-off (since 2.13.0; the status is `AGENT_HUB_READY_FOR_REVIEW_STATUS`) |
| Ready for Review → Done, Approved → Done | Automation — the build, when the pull request it handed off is merged (since 2.15.0; `AGENT_HUB_DONE_STATUS`) |

In a team-managed project, **"Allow all statuses to transition to this one"**
on each status is the simplest way to allow these (an "Any status → <status>"
transition per status). Then restrict the two approvals to people:
[Restrict approvals to people](#restrict-approvals-to-people).

**Setting them up:**
- **Where the workflow is.** Check which kind of project you have: the
  bottom of the project's sidebar says *team-managed* or *company-managed*.
  - **Team-managed:** **Project settings → Work types → Task → Edit
    workflow**, or from the board: **⋯ → Manage workflow**. Save with
    **Update workflow**.
  - **Company-managed:** **Project settings → Workflows**, then edit the
    Task workflow. Save with **Publish**.
- **Adding one:** **Add transition**, then pick **From** and **To**; or
  select a status and tick **Allow all statuses to transition to this one**.
- **Names don't matter to the hub.** It picks the transition into the status
  it needs (the hand-off takes any transition into Ready for Review), so
  name each for the people who see it as a button: "Ready for Review",
  "Done", "Back to Implementation Plan". A name Jira left over from an older
  workflow ("Done 2", "In Review") still works; rename it for clarity.
- **No conditions or screens** on the transitions the hub makes (into Work
  Order, Intake, Implementation Plan, Ready for Review and Done): the service
  account makes them, and a condition or screen would stop it. Only the two
  approvals are restricted.
- **One transition per target status from each status.** With two, the hub
  takes the first Jira lists.
- **Check them** from a ticket in each status: [Checking the
  setup](#checking-the-setup).

## Labels

| Label | Meaning | Added by | Removed by |
|---|---|---|---|
| `needs-details` | The request can't be worked from yet | Work Order Requested rule, or the work-order stage | Work Order Requested or Revision Requested rule, on resubmission |
| `needs-human` | Waiting for a person to act: review and approve, answer questions, or deal with a failed run | Work-order stage (work order written), plan stage (plan written or clarification needed), either stage when a run fails | The rule for each "…Approved" transition; Revision Requested and Work Order Requested rules (the agent is working); the work-order stage when it returns a ticket to Intake |
| `agent-hub-over-cap` | The ticket reached its Claude usage caps; nothing more uses Claude for it ([claude-usage.md](claude-usage.md#per-ticket-caps)) | Any stage, before using Claude | A person, to lift the caps (then retry) |
| `needs-clarification` | The plan needs a product or scope decision | Plan stage | Implementation Plan Requested rule on re-approval; the work-order stage when a revision settles the plan's questions; plan stage when a plan is written |

## Rule: Work Order Requested

Turns a filled-in Task in Intake into a work order request. **Project settings
→ Automation**.

| Part | Setting |
|---|---|
| **Trigger** | *Multiple work item events*: **Work item created**, **Work item updated** |
| **Trigger conditions** | Status = **Intake**; Work type = **Task** |
| **Block 1** | If Sprint is empty → Edit work item: set Sprint to the current sprint |
| **Block 2 — gate** (If, match **any**) | Smart values condition `{{#changelog.description}}changed{{/}}` equals `changed` · Smart values condition `{{changelog}}` equals *(empty)*. Only new tickets and description edits get through; edits to other fields are ignored |
| → **If** it has details | Smart values condition (below) does not equal *(empty)* → Edit work item: Labels **remove** `needs-details` and `needs-human` → Transition to **Work Order** → Send web request |
| → **Else** | Comment (**only once**, see text below) → Edit work item: Labels **add** `needs-details` |
| **Rule details** | Allow rule trigger **off**; notify on error **on** |

**"Has details"** — strips headings, empty `Label:` lines, dividers and empty
bullets from the description, so an untouched template counts as empty:

```
{{issue.description.replaceAll("(?m)^(\s*h[1-6]\..*|[\s*_#-]*[^:\n]{1,80}:[\s*_]*|\s*-{4,}\s*|\s*[*#-]+\s*)$", "").trim()}}
```

**Else comment** — must match the work-order stage's text exactly
(`NEEDS_DETAILS_MESSAGE` in `stages/work-order/settings.sh`), so it's recognised
and marked resolved later:

```
*Needs details* — flagged by Jira automation.

This ticket doesn’t have enough detail to generate a work order, so it’s in Intake until more is added. Update the description, or add the details in a comment starting with /revise, to resubmit it automatically.
```

**Web request** — see [Web requests](#web-requests): workflow
`agent-hub-work-order.yml`, body:

```json
{"ref": "main", "inputs": {"ticket_key": "{{issue.key}}"}}
```

## Rule: Implementation Plan Requested

Requests a plan when a person approves a work order.

| Part | Setting |
|---|---|
| **Trigger** | *Work item transitioned*, **to** status **Work Order Approved**; *from* status left empty, so re-planning (Implementation Plan → Work Order Approved) triggers it too |
| **Condition** | Work type = **Task** (no status condition — the trigger guarantees it) |
| **Action** | Edit work item: Labels **remove** `needs-human` and `needs-clarification` |
| **Action** | Send web request |
| **Rule details** | Allow rule trigger **off**; notify on error **on** |

**Web request** — workflow `agent-hub-implementation-plan.yml`, body:

```json
{"ref": "main", "inputs": {"ticket_key": "{{issue.key}}"}}
```

## Rule: Revision Requested

Lets anyone ask an agent to revise its output — or retry a failed run, or
resubmit a ticket with details added in a comment — by commenting `/revise`
followed by what to change. One rule for every stage: it dispatches the stage
that owns the ticket's current status.

| Part | Setting |
|---|---|
| **Trigger** | *Work item commented* |
| **Condition** | *Smart values condition*: `{{comment.body.trim().toLowerCase()}}` **matches regular expression** `(?s)^/revise(\s.*)?$` — only comments starting with the word `/revise` |
| **Condition** | Work type = **Task** |
| **Condition** | *User condition*: the comment's author (**Initiator**) is in group **`agent-hub-approvers`** (your `AGENT_HUB_APPROVERS_GROUP`), or a wider group of the people who work these tickets |
| **If/else block** | |
| → **If** Status = **Intake** | Edit work item: Labels **remove** `needs-details` and `needs-human` → Transition to **Work Order** → Send web request to `agent-hub-work-order.yml` (as in Work Order Requested) |
| → **Else if** Status = **Work Order** | Edit work item: Labels **remove** `needs-human` → Send web request to `agent-hub-work-order.yml` |
| → **Else if** Status is one of **Work Order Approved**, **Implementation Plan** | Edit work item: Labels **remove** `needs-human` → Send web request to `agent-hub-implementation-plan.yml` (as in Implementation Plan Requested) |
| → **Else** | Comment: `*Revision not started* — /revise works while the ticket is in Intake, Work Order, Work Order Approved or Implementation Plan.` |
| **Rule details** | Allow rule trigger **off**; notify on error **on**. The workflows' own comments (posted through the API) do start this rule, but never begin with `/revise`, so the condition stops them |

The workflows decide what to do from the ticket: a work order already in the
description, or a plan in Implementation Plan, is **revised** (only the
sections the requests touch); otherwise it's written new, with the comments
as input. `/revise` on its own (no text) retries. How revisions work:
[architecture.md](architecture.md#revisions-and-reverse-paths-every-stage).

**What counts, and limits:**
- The comment must **start** with the word `/revise` (any case) — "/revised",
  "please /revise" or a bold "**/revise**" don't count.
- Only **new** comments trigger it: editing an old comment to add `/revise`
  does nothing (Jira has no trigger for comment edits) — post a new one.
- Every unresolved `/revise` comment on the ticket is handled in the next
  run, oldest first, so several can be posted before one run picks them up;
  a `/revise` while a run is going waits for it (one queue per ticket), then
  handles whatever that run didn't see — or, if it saw them all, ends before
  Claude with nothing to revise.
- Description edits never start a revision (outside Intake) — they're manual
  changes, kept as they are.
- Each run uses Claude, so the *User condition* limits who can start one:
  the approvers group, or a wider group of contributors. Without it, anyone
  who can comment on a ticket spends Claude usage on it, up to its caps.
- The command word is the `AGENT_HUB_REVISE_COMMAND` variable (default `/revise`);
  if you change it, change this rule to match. Later stages add their
  statuses to this rule.

## Reverse paths: sending back and asking for changes

| Situation | Do this in Jira | What happens |
|---|---|---|
| The request lacks details (Needs details) | Edit the description, **or** comment `/revise` with the details | Resubmitted; a work order is written from the form plus the comment |
| The work order needs a change you'll make yourself | Edit the description | Nothing runs; your version is what's approved and planned from, and later revisions keep your edits |
| The work order needs changes | In Work Order, comment `/revise` and what to change | Revised in place; a 🔁 comment says how each request was handled; the request is marked ✅ Resolved; `needs-human` again |
| The plan asked questions (`needs-clarification`) | Answer in a comment or the work order — or comment `/revise` with the answers, so the work order records them — then move to **Work Order Approved** | A `/revise` that settles every question clears `needs-clarification` and resolves the questions comment, so the ticket only waits for approval. Approving writes a new plan, using the answers |
| The plan needs changes | In Implementation Plan, comment `/revise` and what to change | Only the affected sections of the attached plan are revised (the rest, including your edits, is kept); stays in Implementation Plan; 🔁 comment; request resolved |
| The plan needs a change you'll make yourself | Download the **newest** `KEY-implementation-plan.md` (check its *Version* line), edit, upload with the same name | Nothing runs; the newest file is the plan that's approved, revised and built from. Editing an older download would undo later changes; each revision's 🔁 reply names the file it started from |
| A change request needs a product decision | *(nothing — the agent handles it)* | Sent back to Work Order with questions (plan) or to Intake with Needs details (work order); the request stays open |
| The plan should start over (e.g. the code changed) | Move Implementation Plan → **Work Order Approved** | A fresh plan replaces the attached one |
| The work order must change after the plan | Move to **Work Order**, then `/revise` (or edit), then approve again | The revised work order marks the old plan out of date; approving writes a new plan |
| The request itself changed | Move back to **Intake** and edit the description (or `/revise`) | The existing work order is revised against it; the original request isn't captured twice |
| A run failed (❌ comment) | Read its **Why:** line; fix the cause if it's on your side, then comment `/revise` | The stage runs again for the ticket's current status |
| A section heading was removed by hand, and a revision needs it | Put the heading back (same name and level), then `/revise` | Until then the run fails without changing anything, and the ❌ comment names the missing section |
| Approved by mistake | Move it back to the review status | A run already started stops without writing (it checks the status first); `needs-human` has to be re-added by hand |
| Abandon the ticket | Move it out of the pipeline (e.g. Done / Won't do) | No rule fires; `/revise` replies that nothing was started |

Every change request stays on the ticket (struck through once handled), so
the history of what was asked and how it was handled is kept.

**When editing by hand, keep the headings.** Change anything inside a section
of the work order or plan, but don't rename or remove its headings (or the
Delivery sections, which later stages fill in): the workflows find sections
by heading. If one goes missing, a revision that needs it stops with a ❌
comment naming it, until it's put back. Revisions themselves never change
headings.

**Requests go in comments, not in the document.** Only a Jira comment
starting with `/revise` asks the agent for a change; nothing inside the
description or the plan file is read as a request (text there — "TODO", or
even "/revise" — is treated as part of the work order or plan). A revision
works from the current version: the description for a work order, the newest
`KEY-implementation-plan.md` attachment for a plan.

## When a stage can't go ahead

| Stage | Not enough to go on | Needs a decision | Technical questions |
|---|---|---|---|
| Intake → work order | Blank or template-only: the Work Order Requested rule keeps it in Intake (Needs details, Jira). Filled in but vague: Claude returns it to Intake with *what's missing* (Needs details, Claude). The requester edits the description or comments `/revise` with the details | Listed in the work order's Open Questions; a person decides before approving | Researched and answered in the work order where they matter |
| Work order → plan | The work order stops being plannable (no acceptance criteria or plan section): fails before Claude runs, with the reason | Back to Work Order with the questions (`needs-clarification`); answer, then approve again | Answered by Claude from the code and documentation, listed in Resolved Technical Questions |
| Plan → build | The plan can't be read as a contract, or names no changes: fails before Claude runs, with the reason | Back to Implementation Plan with the questions in a new plan version and a comment (`needs-clarification`); revise, then approve again | Claude resolves them from the code; the decision log in the pull request records each judgement call |
| A revision (any stage) | A vague request is answered with what's needed, and nothing changes for it | The stage's usual send-back, with the request left open | Researched and answered in the 🔁 reply (and recorded in the output where useful) |

## Automation usage

The workflows' own changes start rule triggers too: each comment they post
starts *Work item commented* (Revision Requested), and each description or
label update starts *Work item updated* (Work Order Requested). The rules'
conditions stop them, but depending on your Jira plan's usage model those
triggers can still count towards the automation quota. The workflows keep
their changes few — label changes go in the same update as the description,
or together in one — and Project settings → Automation → **Usage** shows
what's being used.

Each rule's conditions are listed cheapest and most selective first — the
comment's pattern, then status and work type, the user condition (a group
lookup) last — and Jira stops at the first that fails. The order doesn't
change what a rule does; set them up in the order shown.

### If the automation quota runs out

Jira stops running the rules until the quota resets, and nothing starts by
itself. The workflows still work, started by hand: **Actions → the stage's
workflow → Run workflow**, with the ticket key, after doing what the rule
would have done:

| Instead of | Do this, then run |
|---|---|
| Work Order Requested | Move the ticket to **Work Order** and remove `needs-details` and `needs-human` → *Agent hub: Work order* |
| Implementation Plan Requested | Approve the work order as usual, remove `needs-human` and `needs-clarification` → *Agent hub: Implementation plan* |
| Build Requested | Approve the plan as usual, remove the same labels → *Agent hub: Build* |
| Revision Requested | Comment `/revise …` as usual (the run reads every unresolved one) → the workflow of the stage that owns the ticket's status |
| Build Command | Comment `/skip …` or `/apply …` as usual → *Agent hub: Build* with **wake** `command` |

The approvals are still checked by each run (who moved the ticket, and
since when nothing changed), so starting a run by hand authorises nothing:
it's refused like any other run when the ticket isn't approved. Starting
runs needs write access to the repository. What doesn't depend on Jira's
rules keeps working: the CI sweep, the hand-off, and a merged or closed pull
request's handling.

## Web requests

Every rule starts a stage's workflow directly (since 2.20.0), with the same
token, the **dispatch token**:

| Setting | Value |
|---|---|
| URL | `https://api.github.com/repos/<owner>/<repo>/actions/workflows/<workflow>/dispatches` — the workflow file each rule names (`agent-hub-work-order.yml`, `agent-hub-implementation-plan.yml` or `agent-hub-build.yml`) |
| Method | POST, custom body (each rule's, above) |
| Header | `Authorization: Bearer <token>` — mark **hidden** |
| Header | `Accept: application/vnd.github+json` |
| Header | `Content-Type: application/json` |

In each body, `"ref"` is your repository's **default branch** (`main` in the
examples): the workflow runs as that branch has it. A request GitHub accepts
gets **204** with no body.

The dispatch token is a fine-grained GitHub token for this repository only,
with **Actions: Read and write** and nothing else (Metadata: read is added
by GitHub), owned by you in v1 ([who owns the tokens](setup.md#6-plan-for-credential-expiry)). Name it
`agent-hub-dispatch-<repo>` in GitHub, so it isn't confused with the build's
token ([the two GitHub tokens](setup.md#the-two-github-tokens)).

**What the token can do:** start, re-run and cancel this repository's
workflows (any of them, with any inputs they take), enable or disable them,
and delete their runs, logs, artifacts and caches. It **can't** push code,
open pull requests, read secrets or variables, or change settings. Anyone
who has it can start a stage for any ticket key; each run still checks the
ticket's status and approvals itself, and uses Claude only within the
ticket's caps — so keep it hidden in every rule, and revoke it if it leaks.

**Before 2.20.0** the rules called `…/repos/<owner>/<repo>/dispatches` with
`{"event_type": "agent-hub-<stage>-requested", "client_payload": {...}}`
and a token with **Contents: Read and write** — which can also push code.
For example, Work Order Requested changes from

```
URL:  https://api.github.com/repos/<owner>/<repo>/dispatches
Body: {"event_type": "agent-hub-work-order-requested", "client_payload": {"ticket_key": "{{issue.key}}"}}
```

to

```
URL:  https://api.github.com/repos/<owner>/<repo>/actions/workflows/agent-hub-work-order.yml/dispatches
Body: {"ref": "main", "inputs": {"ticket_key": "{{issue.key}}"}}
```

and each other rule likewise, with its own workflow file (above). The
headers stay as they are.

**The token: edit it, or make a new one.** Token names are unique per
account, so a new token needs another name. Editing the existing one is
simpler and keeps the rules' headers as they are: add **Actions: Read and
write**, keep **Contents** while you switch the rules (the old and new
requests then both work), and once every rule uses the new URL, set
**Contents** to **No access**. To check the result — two codes, nothing
changed, the token never on a command line:

```sh
read -rsp "Dispatch token: " T; echo
cfg=$(umask 077 && mktemp); printf 'header = "Authorization: Bearer %s"\n' "$T" > "$cfg"; unset T
curl -s -o /dev/null -w 'Actions: %{http_code} (expect 200)\n' -K "$cfg" https://api.github.com/repos/<owner>/<repo>/actions/workflows
curl -s -o /dev/null -w 'Contents write: %{http_code} (expect 403)\n' -K "$cfg" -X POST \
  -d '{"ref":"refs/heads/agent-hub-permission-probe","sha":"0000000000000000000000000000000000000000"}' \
  https://api.github.com/repos/<owner>/<repo>/git/refs
rm -f "$cfg"
```

(422 instead of 403 means it can still write contents: only the invalid
commit stopped it.)
**Since 2.22.0 the workflows no longer accept those requests**: a rule
still on the old URL starts nothing (GitHub answers 204, but no run
appears). To change:
create the new token, update every rule's URL, body and header, check each
rule once (the audit log shows 204), then delete the old token.

**It lives in Jira only.** Jira sends it, so Jira holds it: never add it to
GitHub's secrets, where nothing would read it and it would only be one more
copy to leak or forget when rotating. Every **Send web request** action sends
the same token in its `Authorization` header (`Bearer <token>`, marked
**hidden**) — seven of them: one each in Work Order Requested,
Implementation Plan Requested, Build Requested and Build Command, and three
in Revision Requested (one per status block). When you regenerate the token,
update all seven. (The build's own
token, `AGENT_HUB_GITHUB_TOKEN`, is a different one and never goes in Jira.)
A rule whose header is missing or wrong gets **404** from GitHub (for a public
repository; 401 for a token GitHub doesn't recognise), and one whose `ref` or
inputs are wrong gets **422**, shown in the rule's audit log.

Ownership, expiry and alerts: [setup.md](setup.md#6-plan-for-credential-expiry).

## Rule: Build Requested

Starts the build when a person approves a plan
([workflows/build.md](workflows/build.md)). Before 2.5.0 this rule was
*Implementation Plan Approved* and only removed the label: add the web
request to it and rename it.

| Part | Setting |
|---|---|
| **Trigger** | *Work item transitioned*, **to** status **Implementation Plan Approved** |
| **Condition** | Work type = **Task** |
| **Action** | Edit work item: Labels **remove** `needs-human` and `needs-clarification` |
| **Action** | Send web request |
| **Rule details** | Allow rule trigger **off**; notify on error **on** |

**Web request** — workflow `agent-hub-build.yml`, body:

```json
{"ref": "main", "inputs": {"ticket_key": "{{issue.key}}"}}
```

The build checks the approval itself: it builds only from the newest plan
file, and only if a person (not the automation account) made the move here —
with `AGENT_HUB_APPROVERS_GROUP` set, one of its members (since 2.18.0; the
plan stage checks who approved the work order the same way) —
the plan file predates it, and since then no plan file was added or removed
and the work order (the description) wasn't edited by anyone but the
automation account (whose only edit after an approval is the build's own Pull
Request section) — checked again before it
pushes or sends the ticket back. To retry a build, move
the ticket back to Implementation Plan and approve it again.

## Rule: Build Command

Since 2.16.0. Wakes the build when someone comments **`/skip`** or
**`/apply`** (2.17.0) on a ticket whose pull request the build opened
— to act on its items (the pull request's **Items for a person**: `D1`,
`R2`, `C1`). The rule only wakes the build; the build reads the ticket's
open commands itself and answers each one, and **acts only for members of
`AGENT_HUB_APPROVERS_GROUP`** — commenting on a ticket never authorises a
change ([build.md](workflows/build.md#review-items-and-apply)).

| Part | Setting |
|---|---|
| **Trigger** | *Work item commented* |
| **Condition** | *Smart values condition*: `{{comment.body.trim().toLowerCase()}}` **matches regular expression** `(?s)^/(skip|apply)(\s.*)?$` |
| **Condition** | Status is one of **Implementation Plan Approved**, **Ready for Review**, **Approved** |
| **Condition** | Work type = **Task** |
| **Condition** | *User condition*: the comment's author (**Initiator**) is in group **`agent-hub-approvers`** (your `AGENT_HUB_APPROVERS_GROUP`) |
| **Action** | Send web request |
| **Rule details** | Allow rule trigger **off**; notify on error **on** |

**Web request** — workflow `agent-hub-build.yml`, body:

```json
{"ref": "main", "inputs": {"ticket_key": "{{issue.key}}", "wake": "command"}}
```

The user condition only saves work: the build checks the group itself and
refuses anyone else's command, naming them, before any Claude. Without it,
every `/skip` or `/apply` from someone outside the group still uses an
automation run and a short GitHub run to be refused.

How to use them: `/skip D1 R2` closes those items — a decision (`D`) is
**accepted** — with no Claude, and the build's CI gate runs again (so a pull
request whose only blocker was a decision item can be handed off). The line
holds only the command and item ids; anything else and the whole command is
refused (a reason can go in a following paragraph, for people). Who accepted
or skipped what is kept on the ticket, not on the pull request.

`/apply R2 D1` fixes those items; `/apply all` every open R item (never a
decision); `/apply comments` the pull request's unresolved review threads
from people with write access — yours too when the build token is your own
(the hub skips only its own marked replies; [the build token](setup.md#the-build-token-and-branch-protection))
— and they can be combined: `/apply R2 comments`.
The fix goes through the same checks as the review's fix pass, CI runs again
on it, and a pull request already handed off goes back to draft until it's
handed off again — the ticket stays in Ready for Review. `/apply` works only
on the commit the hub last checked: after someone else's push, re-run the
build first.

## Permissions for the automation account

The account behind `AGENT_HUB_JIRA_EMAIL`: Browse Projects, Edit work items, Transition
work items, Add comments, Delete own comments, **Edit all comments** (to mark
people's `/revise`, `/skip` and `/apply` comments — and the rules' comments —
as handled), Create attachments, Delete own attachments (to replace its own
earlier plan files; a person's upload is never deleted, so Delete all
attachments isn't needed). **The team-managed Member role has all of these
except Edit all comments** (Member can edit only its own comments): give the
account the **Agent hub automation** role instead
([Adding the service account](#adding-the-service-account), step 2). Without
it, the hub's edit of a person's command comment is refused (Jira answers
400), so the command is acted on but its answer is lost — the run log says
"Couldn't mark comment N as handled". Edit work items also covers the hub's records on each ticket —
its Claude usage ([claude-usage.md](claude-usage.md#per-ticket-caps)), the
latest review's findings and who acted on which items — kept as issue
properties. For the item commands (`/skip`, `/apply`), the account also needs
the global **Browse users and groups** permission, to check the commenter is
in `AGENT_HUB_APPROVERS_GROUP`; without it, every command is refused.

**Required: a dedicated service account.** Use an account that is only the
automation — not a person's — for three reasons:

1. **The automation never approves.** People approve work orders and plans
   (and, with the build stage, code). Restrict both "…Approved" transitions to
   your approvers, which the service account isn't one of — see
   [Restrict approvals to people](#restrict-approvals-to-people). With a
   person's account that's impossible: the person approves. The build also
   refuses to build from a move to Implementation Plan Approved the service
   account made, and commands that start code changes will need the approvers
   group.
2. **People's plan files are kept.** The hub replaces only its own earlier
   plan files, recognised by the uploader's account. With a person's account,
   a plan file that person uploads by hand looks like the hub's, so the next
   re-plan or plan revision can delete it (after building from it, so its
   content isn't lost from the plan — only the file).
3. **The history shows who did what.** Comments, edits, transitions and
   notifications come from the account; with a person's, the automation's
   actions and theirs can't be told apart.

**Testing the document stages with your own account** works: the workflows
never approve (no code does). The three points above are what you give up
until you switch — keep a local copy of any plan file you edit by hand. **The
build doesn't work that way:** it refuses an approval made by the automation
account, and when that account is yours, so is your approval. To try the
build, use the service account (or have someone else approve). Switching is
only the two secrets (`AGENT_HUB_JIRA_EMAIL`, `AGENT_HUB_JIRA_API_TOKEN`), the
service account's project access, and the approval restriction below.

### Adding the service account

1. Create an Atlassian account for the automation, with an email you control
   (e.g. `you+agenthub@example.com`). It counts as a user on your plan.
2. Give it a role with what it needs, then invite it to the project. The
   regular contributor role is almost right but can't edit other people's
   comments, which the hub must do to mark people's commands as handled — so
   make a role for it (custom roles in team-managed projects depend on your
   Jira plan; without them, see the note below):
   1. **Project settings** → **Access** → **Manage roles** → **Create role**
      (or duplicate **Member**), named **Agent hub automation**.
   2. Give it everything **Member** has, plus **Edit all comments** (under
      Comments). Don't add any "Delete all …" permission, or anything
      administrative.
   3. Save. Then **Access** → **Add people** → its email → role **Agent hub
      automation**. (Company-managed projects: **People**, and a project role
      with the permissions above in the project's permission scheme.)

   Never make it an administrator. Give it **Jira** only: no other products,
   no admin roles. Every invite also lists the account in your organisation's
   directory (admin.atlassian.com); that grants nothing by itself — the
   product access and project role are what count. *No custom roles on your
   plan:* the account needs Edit all comments some other way — in a
   company-managed project through its permission scheme; in a team-managed
   one only the Administrator role has it, which is broader than the hub
   needs (it could change the project's settings), so prefer a
   company-managed project there.
3. Sign in as it once (a private window) to accept the invite.
4. **Create its API token signed in as the service account — not as
   yourself.** The token and the email in the secrets must belong to the
   same account; a token from your own account fails every run (Jira treats
   the mismatched pair as anonymous: "Could not fetch <KEY>", 404), and
   would make the hub act as you if your email were used with it.
   1. Open a **private/incognito window** (so your own sign-in doesn't carry
      over) and sign in at id.atlassian.com **as the service account**.
   2. **Check the avatar** (top right) is the service account's.
   3. Go to https://id.atlassian.com/manage-profile/security/api-tokens →
      **Create API token** (the classic kind, without scopes: the hub signs
      in with email and token), named for its use (e.g.
      `agent-hub-jira-<repo>`), with an expiry you'll track
      ([setup.md](setup.md#6-plan-for-credential-expiry)).
   4. Put the service account's email and this token in the
      `AGENT_HUB_JIRA_EMAIL` and `AGENT_HUB_JIRA_API_TOKEN` secrets, in the
      `agent-hub` environment ([setup.md](setup.md#3-add-secrets)).

   **To revoke a token:** the same page, signed in as the account that owns
   it → **Revoke**. A token made on a person's account by mistake should be
   revoked: it can do everything that person can.

### Restrict approvals to people

The two approvals — moving a ticket to **Work Order Approved** and to
**Implementation Plan Approved** — are people's decisions. Restrict both
transitions so only your approvers can make them, and keep the service account
out of that set. Every other transition stays open (the automation moves
tickets between the other statuses).

**Team-managed project** (transitions as "Any status → <status>"):

1. Board → **⋯** → **Manage workflow** (or **Project settings** → **Work
   types** → **Task** → **Edit workflow**).
2. Select the **Any status → Work Order Approved** transition → **Add rule** →
   **Restrict who can move a work item** → **Only people in these roles** →
   **Administrator** (or **Only these people** → your approvers).
3. The same for **Any status → Implementation Plan Approved**.
4. **Update workflow**.

This works when your approvers are the project's administrators and the
service account isn't one (its role is **Agent hub automation**, as
[above](#adding-the-service-account)) — never add that role to these rules.

**Company-managed project:**

1. At admin.atlassian.com → **Directory** → **Groups**, create
   `agent-hub-approvers` with your approvers — not the service account.
2. **Project settings** → **Workflows** → edit the workflow; on the
   transitions into **Work Order Approved** and **Implementation Plan
   Approved**, add the condition **User Is In Group** → `agent-hub-approvers`.
3. **Publish draft**.

**Check it:** signed in as the service account (a private browser window),
the two "…Approved" statuses are missing from a ticket's status menu; signed
in as an approver, they're there. The automation rules need no change: these
moves trigger them, but they never make them.

### The approvers group

`AGENT_HUB_APPROVERS_GROUP` names the Jira group whose members approve. Set,
the hub checks it itself: a work order or plan approved by someone outside
it isn't an approval, and only its members can use `/skip` and `/apply`
([setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)).
Optional for the document stages, **required before the build runs real
tickets** ([build-design.md](workflows/build-design.md#production-checklist)).

1. **Create the group** (site administrators): admin.atlassian.com → your
   organisation → **Directory → Groups → Create group**, e.g.
   `agent-hub-approvers`. Add your approvers — **never the service
   account**. Product access isn't needed for the group: it's only checked
   for membership.
2. **Let the service account read groups.** Jira grants global permissions
   to **groups only**, never to one person. Open **⚙ Settings → System →
   Global permissions** (under Security), or
   `https://<site>.atlassian.net/secure/admin/GlobalPermissions!default.jspa`,
   and look at the groups on the **Browse users and groups** row. Usually it's
   granted to `jira-users-<site>`, which every user with Jira access is in —
   then the service account already has it and there's nothing to add.
   Otherwise put the service account in a group that has it (or add the
   permission for a group it's in; never the approvers group). Without it,
   every approval and command check stops with "couldn't check". To check:
   in a private window signed in as the service account,
   `https://<site>.atlassian.net/rest/api/3/mypermissions?permissions=USER_PICKER`
   shows `"havePermission": true`.
3. **Set the repository variable** `AGENT_HUB_APPROVERS_GROUP` to the group's
   exact name (GitHub: Settings → Secrets and variables → Actions →
   **Variables**).
4. **Keep the transitions in step:** restrict the two "…Approved" transitions
   to the same people ([above](#restrict-approvals-to-people)) — the group
   itself where your project's workflow allows it (company-managed: **User
   Is In Group**), otherwise the role or people who are in it. Then Jira's
   buttons and the hub agree on who approves.

## Checking the setup

**The setup checker** checks most of this for you, read-only:
`.github/agent-hub/scripts/check-setup.sh --jira-project <KEY>`
([setup.md](setup.md#8-check-it)). By hand:

Jira's API answers in a browser where you're signed in, as read-only JSON —
enough to check the setup without any tool (replace the site, project key
and ticket):

- **Status names** (they must match the hub's exactly):
  `https://<site>.atlassian.net/rest/api/3/project/<KEY>/statuses`
- **The moves a ticket can make now**, from its current status — what the hub
  reads before it moves a ticket:
  `https://<site>.atlassian.net/rest/api/3/issue/<KEY-1>/transitions`. From
  Implementation Plan Approved, expect one into **Ready for Review** and one
  into **Implementation Plan**; from Ready for Review or Approved, one into
  **Done**. `isConditional: true` marks the restricted approvals.
- **The rules:** **Project settings → Automation → ⋯ → Export rules** gives
  every rule as JSON (secure headers are blanked), to compare with this page.
- **A rule's last run:** the rule's **Audit log** shows GitHub's answer to
  its web request: **204** started the workflow; 401, 404 or 422 are
  explained in [Web requests](#web-requests).
- **The hub's credentials** (the three Jira secrets) — when a run stops at
  its first step with "Could not fetch <KEY> from Jira". Jira answers a
  request it can't authenticate as if the ticket didn't exist, so this
  usually means the token and email don't belong to the same account, or
  the domain isn't exactly `<site>.atlassian.net` (no `https://`, no `/`).
  Secrets can't be read back, so test the values you entered — in a terminal;
  it asks for each, never shows the token or puts it on a command line, and
  changes nothing:

  ```sh
  read -rp  "Jira domain: " D; read -rp "Jira email: " E; read -rsp "Jira API token: " T; echo
  cfg=$(umask 077 && mktemp); printf 'user = "%s:%s"\n' "$E" "$T" > "$cfg"; unset T
  curl -s -K "$cfg" -w ' [%{http_code}]\n' "https://$D/rest/api/3/myself" | sed -E 's/.*"displayName":"([^"]*)".*\[/\1 [/'
  rm -f "$cfg"
  ```

  Expect the **service account's name and [200]**. [401] means the token and
  email don't match; your own name means the token is yours.

## Checklist for a new installation

- [ ] Task work type with the intake template
- [ ] Statuses and board columns above; transitions allowed
- [ ] A dedicated service account with the permissions above: the **Agent
      hub automation** role (Member + **Edit all comments**), Jira access
      only ([how](#adding-the-service-account))
- [ ] Status names exactly as the hub's (or its variables set), checked
      ([how](#checking-the-setup))
- [ ] The transitions above, with no conditions or screens on the ones the
      hub makes ([setting them up](#transitions))
- [ ] Both "…Approved" transitions restricted to approvers
      ([how](#restrict-approvals-to-people))
- [ ] Rules: Work Order Requested, Implementation Plan Requested, Revision
      Requested, Build Requested and Build Command
- [ ] The approvers group: created, in `AGENT_HUB_APPROVERS_GROUP`, and
      Browse users and groups for the service account
      ([how](#the-approvers-group))
- [ ] The dispatch token (Actions: read and write only) in every rule's
      `Authorization` header, hidden; each rule's URL naming its workflow,
      and `"ref"` your default branch
- [ ] Revision Requested and Build Command limited by their User condition
      (the approvers group, or for Revision Requested a wider group of the
      people who work the tickets)
- [ ] Each rule's conditions in the order shown (cheapest first)

## Recommended: do these in Jira, not in the workflows

Jira automation is the right place for anything about people and process;
the workflows keep what needs the code or Claude (writing and checking
content). Worth adding when you can:

1. **Notify reviewers when `needs-human` is added.** Rule: *Field value changed
   → Labels*, condition *labels contains needs-human* → email or Slack the
   assignee / delivery lead with the ticket link. Tickets otherwise sit
   unnoticed.
2. **Assign a reviewer** on entering Work Order and Implementation Plan (the
   delivery lead, or a round-robin of reviewers).
3. **Restrict approvals** — required, see
   [Restrict approvals to people](#restrict-approvals-to-people).
4. **Block approving while flags are open.** Workflow *validators* that
   refuse Work Order → Work Order Approved while `needs-details` or
   `needs-clarification` is present.
5. **Remind about stale reviews.** Scheduled rule: JQL
   `labels = needs-human AND updated <= -3d` → comment or notify.
6. **Board quick filters**: `labels = needs-human` (waiting for review),
   `labels in (needs-details, needs-clarification)` (waiting on the requester
   or delivery lead).

Keep in the workflows (not Jira): anything that reads the code, generates or
reviews content, or needs checks that must pass before the ticket changes.
