# Jira setup

Everything the agent hub pipeline needs from a Jira project, in one place: the
board, work type, statuses and transitions, labels, the automation rules in
full, how to send a ticket back or ask for changes, permissions, and
recommendations. Names shown are the defaults; status
and label names can be changed per repository with variables (see
[setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)).

Using GitHub Projects instead? See [trackers.md](trackers.md) and
[github-projects.md](github-projects.md) — the statuses, labels and `/revise`
requests are the same.

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
  Approved** → *(later stages: Ready for Review → Approved → Done)*.
  Board → ⋯ → Configure board → Columns.

## Statuses

| Status | Who moves the ticket here | `needs-human`? |
|---|---|---|
| **Intake** | New tickets start here; the work-order stage returns tickets needing detail | No — waiting on the requester |
| **Work Order** | The Work Order Requested rule (has details); the Revision Requested rule (details added in a comment); the plan stage returns tickets needing clarification | Yes, once the work order is written |
| **Work Order Approved** | A person, after reviewing the work order | No — the rule removes it |
| **Implementation Plan** | The plan stage (a revision keeps it here) | Yes |
| **Implementation Plan Approved** | A person, after reviewing the plan | No — the [Build Requested](#rule-build-requested) rule removes it and starts the build; the build adds it back when its draft pull request needs a person, or when it can't go ahead |
| Ready for Review → Approved → Done | *Later stages* | Ready for Review: yes |

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

In a team-managed project, **"Allow all statuses to transition to this one"**
on each status is the simplest way to allow these (an "Any status → <status>"
transition per status). Then restrict the two approvals to people:
[Restrict approvals to people](#restrict-approvals-to-people).

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

**Web request** — see [Web requests](#web-requests); body:

```json
{"event_type": "agent-hub-work-order-requested", "client_payload": {"ticket_key": "{{issue.key}}"}}
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

**Web request** body:

```json
{"event_type": "agent-hub-implementation-plan-requested", "client_payload": {"ticket_key": "{{issue.key}}"}}
```

## Rule: Revision Requested

Lets anyone ask an agent to revise its output — or retry a failed run, or
resubmit a ticket with details added in a comment — by commenting `/revise`
followed by what to change. One rule for every stage: it dispatches the stage
that owns the ticket's current status.

| Part | Setting |
|---|---|
| **Trigger** | *Work item commented* |
| **Condition** | Work type = **Task** |
| **Condition** | *Smart values condition*: `{{comment.body.trim().toLowerCase()}}` **matches regular expression** `(?s)^/revise(\s.*)?$` — only comments starting with the word `/revise` |
| **If/else block** | |
| → **If** Status = **Intake** | Edit work item: Labels **remove** `needs-details` and `needs-human` → Transition to **Work Order** → Send web request with the `agent-hub-work-order-requested` body (as in Work Order Requested) |
| → **Else if** Status = **Work Order** | Edit work item: Labels **remove** `needs-human` → Send web request with the `agent-hub-work-order-requested` body |
| → **Else if** Status is one of **Work Order Approved**, **Implementation Plan** | Edit work item: Labels **remove** `needs-human` → Send web request with the `agent-hub-implementation-plan-requested` body (as in Implementation Plan Requested) |
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
- Anyone who can comment can start a run, and each run uses Claude. To limit
  it, add a *User condition* to this rule (e.g. the commenter is in the
  project's reviewers group or role), before the If/else block.
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

## Web requests

Every rule calls the same GitHub endpoint with the same token, the
**dispatch token**:

| Setting | Value |
|---|---|
| URL | `https://api.github.com/repos/<owner>/<repo>/dispatches` |
| Method | POST, custom body (above) |
| Header | `Authorization: Bearer <token>` — mark **hidden** |
| Header | `Accept: application/vnd.github+json` |
| Header | `Content-Type: application/json` |

The dispatch token is a fine-grained GitHub token for this repository only,
with **Contents: Read and write**, ideally owned by a machine user. Name it
`agent-hub-dispatch-<repo>` in GitHub, so it isn't confused with the build's
token ([the two GitHub tokens](setup.md#the-two-github-tokens)).

**It lives in Jira only.** Jira sends it, so Jira holds it: never add it to
GitHub's secrets, where nothing would read it and it would only be one more
copy to leak or forget when rotating. Every **Send web request** action sends
the same token in its `Authorization` header (`Bearer <token>`, marked
**hidden**) to the same URL (`…/dispatches`) — six of them: one each in Work
Order Requested, Implementation Plan Requested and Build Requested, and three
in Revision Requested (one per status block). When you regenerate the token,
update all six. (The build's own
token, `AGENT_HUB_GITHUB_TOKEN`, is a different one and never goes in Jira.)
A rule whose header is missing or wrong gets **404** from GitHub (for a public
repository; 401 for a token GitHub doesn't recognise), shown in the rule's
audit log.

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

**Web request** body:

```json
{"event_type": "agent-hub-build-requested", "client_payload": {"ticket_key": "{{issue.key}}"}}
```

The build checks the approval itself: it builds only from the newest plan
file, and only if a person (not the automation account) made the move here,
the plan file predates it, and since then no plan file was added or removed
and the work order (the description) wasn't edited — checked again before it
pushes or sends the ticket back. To retry a build, move
the ticket back to Implementation Plan and approve it again.

## Permissions for the automation account

The account behind `AGENT_HUB_JIRA_EMAIL`: Browse Projects, Edit work items, Transition
work items, Add comments, Delete own comments, Edit all comments (to resolve
the rule's comments), Create attachments, Delete own attachments (to replace
its own earlier plan files; a person's upload is never deleted, so Delete all
attachments isn't needed). In team-managed projects the Member role has these
by default. Edit work items also covers the hub's record of each ticket's
Claude usage, an issue property ([claude-usage.md](claude-usage.md#per-ticket-caps)).

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
2. Invite it to the project: **Project settings** → **Access** (team-managed)
   or **People** (company-managed) → **Add people** → its email → role
   **Member** (or your project's regular contributor role) — never an
   administrator. Give it **Jira** only: no other products, no admin roles.
   Every invite also lists the account in your organisation's directory
   (admin.atlassian.com); that grants nothing by itself — the product access
   and project role are what count.
3. Sign in as it once (a private window) to accept the invite.
4. As it, create an API token at id.atlassian.com → **Security** → **API
   tokens**, named for its use (e.g. `agent-hub-jira-<repo>`), and put the
   email and token in the `AGENT_HUB_JIRA_EMAIL` and `AGENT_HUB_JIRA_API_TOKEN`
   secrets ([setup.md](setup.md#3-add-secrets)). Note the token's expiry
   ([setup.md](setup.md#6-plan-for-credential-expiry)).

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
service account is a **Member** (as [above](#permissions-for-the-automation-account)).

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

## Checklist for a new installation

- [ ] Task work type with the intake template
- [ ] Statuses and board columns above; transitions allowed
- [ ] A dedicated service account with the permissions below (Member, Jira
      access only)
- [ ] Both "…Approved" transitions restricted to approvers
      ([how](#restrict-approvals-to-people))
- [ ] Rules: Work Order Requested, Implementation Plan Requested, Revision
      Requested and Build Requested
- [ ] The token in every rule's `Authorization` header, hidden

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
