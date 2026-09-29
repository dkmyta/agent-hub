<!--
Template for an agent workflow's page. Copy to docs/workflows/<stage>.md and
fill in every section; write "None" rather than deleting one. Keep it current:
updating this page is part of the definition of done (CONTRIBUTING.md).
-->

# <Stage> (`agent-<stage>.yml`)

<One or two sentences: what the workflow does and for whom.>

| | |
|---|---|
| Trigger | `repository_dispatch` `<stage>-requested` (Jira), or **Run workflow** with a ticket key |
| Runs on | <runner> — see [runners.md](../runners.md) |
| Model | <model> (`CLAUDE_MODEL`) |
| Agent files | `.github/agents/<stage>/` |
| Tests | `tests/<stage>/` |

## Ticket lifecycle

<Diagram and a short description of each outcome: what changes on the ticket,
what the user sees, how to retry.>

## Jira setup

### Automation rule
<Trigger, conditions, actions, web request body — enough to rebuild it.>

### Statuses, labels and text the workflow depends on
| Setting | Value | Used for |
|---|---|---|

### Secrets and permissions
<Repository secrets; Jira permissions the API user needs.>

## Edge cases
| Situation | Behaviour |
|---|---|

## Known gaps
<What doesn't work or isn't handled yet, and the workaround.>

## Testing
<Which suites cover it, which eval cases exist, how to run them.>
