<!--
Template for an agent workflow's page. Copy to docs/workflows/<stage>.md and
fill in every section; write "None" rather than deleting one. Keep it to
what's specific to this stage: shared behaviour (the review, revisions,
failure reasons, safety, known gaps shared by every stage) is described once
in docs/architecture.md, and everything done in the tracker — rules, reverse paths —
in docs/jira.md and docs/github-projects.md; link there rather than repeating it. Keeping this page
current is part of the definition of done (CONTRIBUTING.md).
-->

# <Stage> (`agent-hub-<stage>.yml`)

<One or two sentences: what the workflow does and for whom.>

| | |
|---|---|
| Trigger | `workflow_dispatch` of `agent-hub-<stage>.yml` (Jira: <rules>, [web requests](../jira.md#web-requests)), or **Run workflow** with a ticket key |
| Runs on | `AGENT_HUB_RUNS_ON` — see [runners.md](../runners.md) |
| Model | <draft model>; review `AGENT_HUB_REVIEW_MODEL` |
| Stage files | `stages/<stage>/` |
| Extensions | `.github/agent-hub-extensions/<stage>/` and `shared/`, optional — see [extending.md](../extending.md) |
| Tests | `tests/<stage>/` |

## Ticket lifecycle

<Diagram, then one short bullet per outcome: what changes on the ticket and
what the person does next, including how to retry.>

## Revisions

<What's specific to this stage's revisions: what counts as the current
output, the unit of a section, where the ticket stays, what else it updates
or marks out of date, and what happens when an input is missing.>

## How it runs

<Typical run time; the tracker rule in one sentence (link jira.md); then the
workflow steps — fetch and its checks, Claude, apply (in the order changes
are made) or return, cleanup/failure.>

## What it produces

<A table of the output's sections and what each contains, which are
optional, and where each piece goes (description, comment, attachment).>

## Settings

<The repository variables this stage reads (link setup.md for all) — its own
are `AGENT_HUB_<STAGE>_<setting>` (`MODEL`, `FALLBACK_MODEL`, `MAX_BUDGET_USD`,
`REVIEW_MAX_BUDGET_USD`, `REVISION_MAX_BUDGET_USD`; add a column for the stage
to setup.md's per-stage table) — and any text fixed in the stage's settings
that must match a tracker rule. Add the stage's rule to jira.md, and its
statuses to the Revision Requested rule.>

## Constraints

<Limits specific to this stage: size limits, run time, model needs.>

## Edge cases

| Situation | Behaviour |
|---|---|

## Known gaps

<This stage's gaps and workarounds; link architecture.md for the shared ones.>

## Testing

<Which suites cover it and which eval cases exist.>

## Test in Jira

<Numbered checks on a real test ticket for each path, forward and reverse,
with what to expect — run after setting up or changing the stage.>
