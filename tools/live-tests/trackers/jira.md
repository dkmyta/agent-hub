# Jira

What the journeys' terms mean in Jira. The hub's setup is in
[jira.md](../../../.github/agent-hub/docs/jira.md); this file only adds
what a live test needs.

## Routing test tickets

Only for a separate test repository ([Where it runs](../README.md#where-it-runs));
in the hub's own repository every AGENTHUB ticket already goes there.

Every rule's **Send web request** names one repository in its URL
(`…/repos/<owner>/<repo>/actions/workflows/<workflow>/dispatches`), so all of
the project's tickets go to that repository. To send test tickets to the
test repository instead, each of the seven web requests (one each in Work
Order Requested, Implementation Plan Requested, Build Requested and Build
Command, and three in Revision Requested) becomes an **If / else** block:

| Branch | Condition | Web request |
|---|---|---|
| If | *Work item fields condition*: **Labels** contains `agent-hub-live-test` | The test repository's URL, with the test repository's dispatch token |
| Else | — | The hub repository's URL, as today |

- **The dispatch token is per repository** (a fine-grained token for one
  repository, with Actions: Read and write). The test repository gets its
  own, `agent-hub-dispatch-<test repo>`, in the If branch only, marked
  hidden like the other.
- **The test repository's hub settings:** the same Jira site and service
  account (the secrets `AGENT_HUB_JIRA_DOMAIN`, `AGENT_HUB_JIRA_EMAIL`,
  `AGENT_HUB_JIRA_API_TOKEN`), the same `AGENT_HUB_APPROVERS_GROUP`, and
  `AGENT_HUB_BUILD_ENABLED=true`; its own build token and runner settings
  ([setup.md](../../../.github/agent-hub/docs/setup.md)).
- **Set the label when creating the ticket**, before its description is
  saved: Work Order Requested runs as soon as a ticket has details.
- Undo it after the live tests by removing the If branches, or keep them:
  without labelled tickets they never match.

**Checking the routing** (journey 1, step 1): create a labelled ticket and
let Work Order Requested send it. Then:

- the test repository has a new **Agent hub: Work order** run for the
  ticket (`gh run list -R <test repo> -w agent-hub-work-order.yml`);
- the hub's repository has none
  (`gh run list -R dkmyta/agent-hub -w agent-hub-work-order.yml`);
- the rule's audit log (Project settings → Automation → the rule → Audit
  log) shows 204 from the test repository's URL;
- after the run, the ticket still has the `agent-hub-live-test` label.

The Else branch is checked by the next real ticket's audit log.

## Actions

| Term | In Jira |
|---|---|
| `create-ticket <fixture>` | Create a **Task** in the project with the fixture's fields in the intake template and the label `agent-hub-live-test`, set in the create dialog |
| `edit-request` | Edit the description and save |
| `comment <text>` | Add a comment as yourself (a member of the approvers group, unless the step says otherwise) |
| `approve-work-order` | Move the card to **Work Order Approved** (starts Implementation Plan Requested) |
| `approve-plan` | Move the card to **Implementation Plan Approved** (starts Build Requested). The build accepts the approval only if, since, no plan file was added or removed, the title wasn't changed, and nothing in the description before its Delivery sections was edited |
| `send-back <status>` | Move the card to that status |
| `start <stage>` | `gh workflow run agent-hub-<stage>.yml -R <repo> -f ticket_key=<KEY>` (with `-f wake=command` to have the build read new commands) |

## Observations

| Term | Where in Jira |
|---|---|
| `status`, `labels` | The ticket's status and labels |
| `comment "<marker>"` | The ticket's comments; ✅ Resolved comments are the hub's edits of people's comments (the account needs the **Agent hub automation** role: [Permissions](../../../.github/agent-hub/docs/jira.md#permissions-for-the-automation-account)) |
| `section <name>` | The description's h4 sections |
| `plan file` | The newest `<KEY>-implementation-plan.md` attachment; the summary under Delivery → Implementation Plan |
| `hub records` | Entity properties: `agent-hub-ledger` (usage), `agent-hub-review` (the kept review), `agent-hub-items` (handled commands and who did what). Read them with your own account: `GET /rest/api/3/issue/<KEY>/properties/<name>` |

## Allowance

Each journey lists its Jira automation runs. Check them in Project settings
→ Automation → **Usage** before starting: a rule that can't run leaves the
ticket waiting, which reads like a hub failure.

## Trackers verified

Jira is the reference tracker: the journeys were written from its manual
tests (AGENTHUB-59 and AGENTHUB-60, hub 2.21).
