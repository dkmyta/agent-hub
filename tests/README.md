# Agent workflow tests

Tests for the agent workflows (`.github/workflows/agent-*.yml`) and their
shared code (`.github/agents/`), written with
[bats-core](https://bats-core.readthedocs.io) and
[bats-assert](https://github.com/bats-core/bats-assert). They run the
workflows' **real step scripts**, read straight from the workflow files, with
Jira mocked and Claude stubbed — no network, no Jira, no Claude usage. A step
refuses to run if `claude` doesn't resolve to the stub, so a test can never
reach a real Claude login.

## Running

```sh
npm ci --prefix tests --ignore-scripts  # once
npm test --prefix tests                # everything (~20s on macOS, faster on Linux)
npx --prefix tests bats tests/shared   # one folder or file
npm run update-snapshots --prefix tests
```

Needs `bash`, `jq` and Node 22. The pre-push hook and CI run the same suite;
CI runs it on jq 1.7 (GitHub-hosted runners) and 1.8 (the self-hosted runner).

## Layout

```
tests/
  lib/                 shared test helpers
    helpers.bash         run workflow steps, snapshots, ADF validation
    mock-jira.bash       replaces jira() — logs calls, serves fixtures
    bin/claude           stand-in for the Claude Code CLI
    workflow.mjs         reads step scripts out of a workflow file
    validate.mjs         schema checks (Claude output, ADF)
  vendor/              Atlassian's ADF JSON schema (pinned)
  shared/              .github/agents/lib: adf.bats, jira.bats
  work-order/          agent-work-order.yml
    scenarios.bats       end-to-end paths (scenarios/<name>/)
    claude-step.bats     Claude step: output validation, tool limits
    schema.bats          output schema and ticket layout
    fixtures/            tickets, comments, transitions, recorded Claude output
    evals/               live evals with the real Claude (not in npm test)
```

## What's covered

| File | Checks |
|---|---|
| `shared/adf.bats` | ADF builders, comment helpers, ADF → Markdown |
| `shared/jira.bats` | Ticket-key validation, status checks, request bodies, failure handling |
| `shared/claude-usage.bats` | Claude is only used on demand: Claude-using workflows only run on Jira requests or manual runs; `npm test` excludes the evals; evals refuse to run without `RUN_EVALS=1` |
| `shared/behaviour-changes.bats` | Which changes trigger CI's eval reminder (`.github/scripts/agent-behaviour-changes.sh`) |
| `work-order/schema.bats` | Schema works as a Claude Code `--json-schema`; recorded outputs match it; ticket headings; valid ADF |
| `work-order/claude-step.bats` | Only usable Claude output continues (5 kinds of bad output); ticket passed as data; read-only, repo-scoped tools; no Jira credentials |
| `work-order/scenarios.bats` | The checkout hides recorded test data from Claude; step time limits fit the job's; 13 paths: ready (and without a description, and re-run after a failed update), needs details, not in Work Order, moved during run/review, cancelled by a newer request, no Intake transition, Claude fails, Jira rejects the description, Jira unreachable, invalid key |

Every scenario snapshots a **trace** — each step's result and every Jira call
— and checks every document sent to Jira against Atlassian's ADF schema. The
two main paths (`ready`, `needs-details`) also snapshot the full request
bodies, Claude's prompt and the run summary.

## Snapshots

When a change is intended, update the snapshots and **review the diff** — it
shows exactly how tickets, comments or Jira calls change:

```sh
npm run update-snapshots --prefix tests && git diff tests/
```

`work-order/workflow-shape.txt` records the workflow's steps and `if:`
conditions. `run_work_order` in `work-order/helpers.bash` mirrors them, so if
that snapshot changes, update the runner to match.

## Adding a scenario

1. Create `work-order/scenarios/<name>/scenario.env` (variables are documented
   in `lib/mock-jira.bash`; defaults in `run_scenario`).
2. Add a `@test` calling `run_scenario <name>` to `scenarios.bats`.
3. `npm run update-snapshots --prefix tests`, then check `expected/trace.txt`
   is what the workflow should do.

## Live evals

Why and when to run them: [docs/evals.md](../docs/evals.md).

`work-order/evals/evals.bats` runs the Claude step with the **real** Claude
Code CLI against sample tickets, in a copy of the repository without the
recorded test data (as the workflow's checkout sees it), and checks the decision, the output schema,
that Claude made no attempt to reach outside the repository, and — for ready
tickets — the rendered ticket and its codebase map. It uses Claude usage
(typical costs: [docs/claude-usage.md](../docs/claude-usage.md)), so it isn't part of `npm test`
and refuses to run unless `RUN_EVALS=1` (which `npm run evals` sets):

```sh
npm run evals --prefix tests
npm run evals --prefix tests -- --filter '^readme-docs:'
```

or **Actions → Agent Evals → Run workflow**. Run it after changing a prompt,
schema or model. To add a case: `evals/cases/<name>/case.env` (`TITLE`,
`EXPECT_STATUS`, optional `EXPECT_CODEBASE`), `description.txt` (one paragraph
per line), and a `@test` in `evals.bats`.

## For new agent stages

Add `tests/<stage>/` alongside `work-order/`, with its own `helpers.bash`,
scenarios, Claude-step and schema tests, fixtures and evals, reusing `lib/`.
