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
    bin/claude           stand-in for the Claude Code CLI (draft and review calls)
    workflow.mjs         reads step scripts out of a workflow file
    validate.mjs         schema checks (Claude output, ADF)
  vendor/              Atlassian's ADF JSON schema (pinned)
  shared/              .github/agents/lib and CI helpers: adf, jira, claude-usage, behaviour-changes
  work-order/          agent-work-order.yml
    scenarios.bats       end-to-end paths (scenarios/<name>/)
    claude-step.bats     Claude step: output validation, tool limits
    schema.bats          output schema and ticket layout
    fixtures/            tickets, comments, transitions, recorded Claude output
    evals/               live evals with the real Claude (not in npm test)
  implementation-plan/ agent-implementation-plan.yml (same layout)
```

## What's covered

| File | Checks |
|---|---|
| `shared/adf.bats` | ADF builders, comment helpers, ADF → Markdown, recognising the `/revise` command |
| `shared/jira.bats` | Ticket-key validation, status checks, request bodies, credentials file, attachments, failure handling |
| `shared/claude-usage.bats` | Claude is only used on demand: Claude-using workflows only run on Jira requests or manual runs; `npm test` excludes the evals; evals refuse to run without `RUN_EVALS=1`, a named stage and a typed `use-claude` confirmation; the Agent Evals workflow is skipped without it and lists every stage; the eval spend cap |
| `shared/behaviour-changes.bats` | Which changes CI's eval notice flags, and which stages' evals they affect (`.github/scripts/agent-behaviour-changes.sh`) |
| `work-order/scenarios.bats` | The checkout hides recorded test data from Claude; step time limits fit the job's; the workflow's steps match the runner; 20 paths: ready (and without a description, and re-run after a failed update), needs details, not in Work Order, moved during run/review, cancelled by a newer request, no Intake transition, Claude fails, Jira rejects the description, Jira unreachable, invalid key, the review changing the outcome, the review failing; and the reverse paths: a `/revise` revision (only the updated sections replaced, every other section unchanged, the change request answered and resolved, the original request not captured again, earlier 🔁 replies left out), a revision with a plan attached (marked out of date), a revision sent back for details, a revision needing a section removed by hand (fails first, naming it), details added in a `/revise` comment |
| `work-order/claude-step.bats` | Only usable Claude output continues (6 kinds of bad output, incl. budget exceeded); ticket passed as data; read-only, repo-scoped tools and Claude isolation (write/shell tools denied, repo settings only, no hooks or MCP); model, fallback, budget; no Jira credentials; the review's inputs, failure and output format; revision mode (only changed sections returned, the revision instructions, the review seeing the whole revised document, the revision formats for every stage) |
| `work-order/schema.bats` | Schema works as a Claude Code `--json-schema`; recorded outputs match it; ticket headings; valid ADF |
| `implementation-plan/scenarios.bats` | 19 paths (the review's outcome change and failure are covered once, by the work-order scenarios, since that logic is shared), with failure reasons on the ticket, including a revision needing a section renamed by hand, a `/revise` revision of the attached plan (only the updated sections spliced in, a person's edit kept, the summary untouched where not updated, stays in Implementation Plan), a revision with the attachment gone, a revision that needs a product decision, the expert review improving the plan or dropping a criterion; and: plan written (attached + summary), needs clarification, not in Work Order Approved, no work order (no Claude usage), moved during run, no transition, summary too large, missing criterion, cancelled, Jira rejects the description, re-plan replaces the previous plan, upload fails |
| `implementation-plan/claude-step.bats` | Only complete plans continue: every acceptance criterion covered, files to modify exist (for revisions, in the sections they change); the plan is never logged; the fallback warning; Opus by default, read-only tools; the review of a revision sees the whole revised plan |
| `implementation-plan/schema.bats` | Plan schema; both renderings (full plan, ticket summary); the summary replaces only the Implementation Plan section; Markdown tables and emphasis; revisions: splicing sections into the attached plan (replace, insert in order, remove, estimate line) and patching the summary |

Every scenario snapshots a **trace** — each step's result and every Jira call
— and checks every document sent to Jira against Atlassian's ADF schema. The
main paths (ready, send back, revise) also snapshot the full request bodies
and the run summary. Claude's prompts aren't snapshotted (the Claude-step
tests check what matters in them), so a prompt edit doesn't touch snapshots.

Claude's recorded answers are kept once per stage (`fixtures/claude/ready.json`
and the like); a scenario that needs a variant — a criterion missing, a
reviewed version — describes it as a jq edit of the recording
(`CLAUDE_FIXTURE_EDIT`, `CLAUDE_REVIEW_FIXTURE_EDIT` in `scenario.env`)
instead of storing a near-copy.

## Snapshots

When a change is intended, update the snapshots and **review the diff** — it
shows exactly how tickets, comments or Jira calls change:

```sh
npm run update-snapshots --prefix tests && git diff tests/
```

Each stage's `workflow-shape.txt` records its workflow's steps and `if:`
conditions. `run_stage` in `lib/helpers.bash` mirrors them, so if that
snapshot changes, update the runner to match.

## Adding a scenario

1. Create `<stage>/scenarios/<name>/scenario.env` (variables are documented
   in `lib/mock-jira.bash`; defaults in `run_scenario`).
2. Add a `@test` calling `run_scenario <name>` to `scenarios.bats`.
3. `npm run update-snapshots --prefix tests`, then check `expected/trace.txt`
   is what the workflow should do.

## Live evals

Why and when to run them: [docs/evals.md](../docs/evals.md).

Each stage's `evals/evals.bats` runs its Claude step (draft and review) with
the **real** Claude Code CLI against sample tickets, in a copy of the
repository without the recorded test data (as the workflow's checkout sees
it). It checks the decision, the output schema, that the review ran, that
Claude made no attempt to reach outside the repository, and — for tickets that
proceed — the rendered ticket and the files it names. It uses Claude (typical
costs: [docs/claude-usage.md](../docs/claude-usage.md)), so it isn't part of
`npm test` and refuses to run unless `RUN_EVALS=1`, which only
`lib/run-evals.sh` sets — after you name a stage and type `use-claude`:

```sh
npm run evals --prefix tests -- work-order                          # one stage
npm run evals --prefix tests -- work-order --filter '^too-vague:'  # one case
```

or **Actions → Agent Evals → Run workflow** with a stage and `use-claude` in
the confirmation box. `lib/run-evals.sh` also enforces the run's spend cap
(`EVALS_MAX_COST_USD`, default 10). Keep each stage to about two cases
([why](../docs/evals.md#keeping-the-suite-small)).

To add a work-order case: `work-order/evals/cases/<name>/case.env` (`TITLE`,
`EXPECT_STATUS`, optional `EXPECT_CODEBASE`), `description.txt` (one
paragraph per line), and a `@test` in `evals.bats`. Plan cases use
`work-order.json` (a work order in the work-order stage's format) and optional
`EXPECT_CHANGES` instead.

## For new agent stages

Add `tests/<stage>/` alongside `work-order/` and `implementation-plan/`. Its
`helpers.bash` only sets `WORKFLOW`, `STAGE_DIR`, `FIXTURES` and
`BOUNCE_STATUS`; `lib/helpers.bash` provides `extract_stage`, `run_stage` and
`run_scenario` for every stage with the standard step layout. Add the folder
to the `test` and `update-snapshots` scripts in `package.json`; evals in
`<stage>/evals/` are found automatically, and the stage goes in the Agent
Evals workflow's `stage` options (a test checks the list).
