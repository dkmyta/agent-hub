# GitHub Projects setup

The foundations for using GitHub Projects as the tracker instead of Jira:
where tickets live, the board and its statuses, views, labels, the intake
template and access. Choosing between the two: [trackers.md](trackers.md).

> **Status:** foundations only. **The agent stages aren't connected to GitHub
> issues yet**, so a ticket on this board doesn't start a work order or plan.
> Connecting them mirrors the Jira setup and is documented here once it's
> built. Until then, use [Jira](jira.md) for the full pipeline.

The statuses and labels are the same as Jira's, so both trackers read the
same way.

## Where tickets live

Tickets are GitHub **issues**; the **Project** is the board that shows them.
A project belongs to your account or organisation, not to a repository, and
can show issues from any repository linked to it.

**Issues are as public as their repository.** In a public repository anyone
can read every ticket, even if the project is private. Keep real tickets
(client requests, internal work) in a **private** repository.

## Board and statuses

1. Your profile (or organisation) → **Projects** → **New project** →
   **Board**. Name it (e.g. "Agent pipeline"); it's **private** by default.
   Don't import items.
2. Edit the **Status** field (column ⋯ → *Edit field*) so the columns are, in
   order:

   | Status | Description |
   |---|---|
   | Intake | New request; waiting for enough detail |
   | Work Order | Work order written; waiting for review |
   | Work Order Approved | Approved; implementation plan being written |
   | Implementation Plan | Plan written; waiting for review |
   | Implementation Plan Approved | Approved; ready to build |
   | Ready for Review | Pull request ready; waiting for review |
   | Approved | Pull request approved; ready to merge |
   | Done | Merged and finished |

   Remove "Todo" and "In Progress". The names match the Jira statuses
   ([jira.md](jira.md#statuses)).
3. Name the board view **Pipeline**, and on it: view ▾ → **Fields** → tick
   **Labels** and **Assignees** → **Save**.
4. ⋯ → Settings → **README** (optional): a line saying what the board is,
   linking to these docs.
5. ⋯ → Settings → **Linked repositories**: add the repository that holds the
   tickets.

## Views

Saved filters, like Jira quick filters. **+ New view** → **Table**, rename,
type the filter, press Enter, **Save**:

| View | Filter | Shows |
|---|---|---|
| Needs review | `label:needs-human` | Everything waiting on a person |
| Waiting on requester | `label:needs-details,needs-clarification` | Tickets blocked on details or a decision |

No space after the comma — `label:a, b` searches for the text "b" instead.

## Labels

The same labels as Jira's ([jira.md](jira.md#labels)). Create them in the
tickets' repository: **Issues → Labels → New label**.

| Label | Description |
|---|---|
| `needs-details` | The request can't be worked from yet: waiting on the requester |
| `needs-clarification` | The plan needs a product or scope decision |
| `needs-human` | Waiting for a person to act: review, approve, answer or fix a failure |

## Intake template

`.github/issue_template.md` is the GitHub version of the Jira intake template —
the same fields, pre-filled in every new issue once it's on the repository's
default branch (copy it to the tickets' repository if that's a different
one). It follows the same single-file pattern as `pull_request_template.md`.

As with Jira's template, GitHub can't make these fields required in a
single-file template. They're enforced the way Jira does it: when the stages
are connected, a new issue gets the same "has details" check as the Jira rule
(an untouched template is sent back with Needs details), and the work-order
stage sends back anything too vague to work from.

## Built-in project workflows

GitHub's own simple automations (⋯ → **Workflows**), which keep the board
tidy:

| Workflow | Set to | |
|---|---|---|
| Item added to project | Status: **Intake** | Recommended: new tickets land in the first column |
| Item closed | Status: **Done** | Recommended |
| Pull request merged | Status: **Done** | Optional, for the build stage |
| Auto-add to project | Filter: `is:issue` | Optional: only if the linked repository holds nothing but tickets; otherwise add issues to the board from the issue's sidebar (**Projects**) |

## Access

⋯ → Settings → **Manage access**: keep the project **private** and add the
people who use it (*Read* to watch, *Write* to move cards, *Admin* for
settings). Repository access is separate: people need access to the tickets'
repository to see and comment on its issues.

## Checklist for a new installation

- [ ] A repository for the tickets (private for real work), linked to the project
- [ ] Project with the Status columns above; the Pipeline board view showing
      Labels and Assignees; the two views
- [ ] Labels created in the tickets' repository
- [ ] The intake template on that repository's default branch
- [ ] Built-in workflow: Item added → Intake (and Item closed → Done)
- [ ] Access for the people using the board
