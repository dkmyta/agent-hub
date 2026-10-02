# Agent hub tests

Tests for the agent hub — the stages, their shared code, and the workflows
(`.github/workflows/agent-hub-*.yml`) — written with
[bats-core](https://bats-core.readthedocs.io) and
[bats-assert](https://github.com/bats-core/bats-assert). They run the
stages through the shared stage workflow's **real step scripts**, read
straight from the workflow file, with
the tracker (Jira) mocked and Claude stubbed — no network, no tracker, no
Claude usage. A step
refuses to run if `claude` doesn't resolve to the stub, so a test can never
reach a real Claude login.

## Running

```sh
npm ci --prefix .github/agent-hub/tests --ignore-scripts  # once
npm test --prefix .github/agent-hub/tests                # everything (~20s on macOS, faster on Linux)
npx --prefix .github/agent-hub/tests bats .github/agent-hub/tests/shared   # one folder or file
npm run update-snapshots --prefix .github/agent-hub/tests
```

Needs `bash`, `jq` and Node 22. The pre-push hook and CI run the same suite;
CI runs it on jq 1.7 (GitHub-hosted runners) and 1.8 (the self-hosted runner).

## Layout

```
tests/
  lib/                 shared test helpers
    helpers.bash         run workflow steps and stages, snapshots, ADF validation
    mock-jira.bash       replaces the Jira tracker's requests — logs calls, serves fixtures
    bin/claude           stand-in for the Claude Code CLI (draft and review calls)
    workflow.mjs         reads step scripts out of a workflow file
    validate.mjs         schema checks (Claude output, ADF)
  vendor/              Atlassian's ADF JSON schema (pinned)
  shared/              the shared stage workflow, lib/, trackers/ and CI helpers
    stage-workflow-shape.txt  the stage workflow's steps and conditions (snapshot)
  work-order/          stages/work-order
    scenarios.bats       end-to-end paths (scenarios/<name>/)
    claude-step.bats     the agent step: output validation, tool limits
    schema.bats          output schema and ticket layout
    fixtures/            tickets, comments, transitions, recorded Claude output
    evals/               live evals with the real Claude (not in npm test)
  implementation-plan/ stages/implementation-plan (same layout)
```

## What's covered

| File | Checks |
|---|---|
| `shared/adf.bats` | ADF builders, comment helpers, ADF → Markdown, recognising the `/revise` command |
| `shared/jira.bats` | Ticket-key validation, status checks, request bodies, credentials file, attachments, failure handling |
| `shared/claude-usage.bats` | Claude is only used on demand: Claude-using workflows only run on tracker requests or manual runs; `npm test` excludes the evals; evals refuse to run without `RUN_EVALS=1`, a named stage and a typed `use-claude` confirmation; the Agent hub: Evals workflow is skipped without it and lists every stage; the eval spend cap |
| `shared/settings.bats` | Settings: the defaults with no repository variables, overrides (empty ones ignored), per-stage variables, values kept as text, malformed variables falling back to defaults; `lib/load.sh` refusing an unknown part |
| `shared/stage-workflow.bats` | The shared stage workflow: its steps and conditions match `run_stage`; the checkout hides recorded test data from Claude; for every stage, step time limits fit the job's; every stage has its files, step functions and a caller workflow with its `agent-hub-<stage>-requested` event and a per-ticket concurrency group; the repository's extensions are named for a stage or `shared` and hold only what an extension may (and that check catches misnamed folders and disallowed files) |
| `shared/trackers.bats` | Every tracker and agent runner defines its interface; Jira and GitHub Projects stay in step: the GitHub issue form has the Jira template's fields, adds the `agent-hub` label and requires the request |
| `shared/behaviour-changes.bats` | Which changes CI's eval notice flags (extension changes included), and which stages' evals they affect (`scripts/agent-behaviour-changes.sh`) |
| `work-order/scenarios.bats` | 20 paths: ready (and without a description, and re-run after a failed update), needs details, not in Work Order, moved during run/review, cancelled by a newer request, no Intake transition, Claude fails, Jira rejects the description, Jira unreachable, invalid key, the review changing the outcome, the review failing; and the reverse paths: a `/revise` revision (only the updated sections replaced, every other section unchanged, the change request answered and resolved, the original request not captured again, earlier 🔁 replies left out), a revision with a plan attached (marked out of date), a revision sent back for details, a revision needing a section removed by hand (fails first, naming it), details added in a `/revise` comment |
| `work-order/claude-step.bats` | Only usable Claude output continues (6 kinds of bad output, incl. budget exceeded); ticket passed as data; read-only, repo-scoped tools and Claude isolation (write/shell tools denied, repo settings only, no hooks or MCP); model, fallback, budget; no tracker credentials; a session id per call, no saved sessions, and the cleanup removing exactly this job's session files (nothing for invalid entries, and nothing to do without a checkout); repository extensions — this stage's and the shared ones loaded for both passes (guidance, review checklists, experts and skills; for revisions after the revision instructions), other stages' not, nothing changing without any, and anything an extension can't contain stopping the run before Claude starts; the review's inputs, failure and output format; revision mode (only changed sections returned, the revision instructions, the review seeing the whole revised document, the revision formats for every stage) |
| `work-order/schema.bats` | Schema works as a Claude Code `--json-schema`; recorded outputs match it; ticket headings; valid ADF |
| `implementation-plan/scenarios.bats` | 19 paths (the review's outcome change and failure are covered once, by the work-order scenarios, since that logic is shared), with failure reasons on the ticket, including a revision needing a section renamed by hand, a `/revise` revision of the attached plan (only the updated sections spliced in, a person's edit kept, the summary untouched where not updated, stays in Implementation Plan), a revision with the attachment gone, a revision that needs a product decision, the expert review improving the plan or dropping a criterion; and: plan written (attached + summary), needs clarification, not in Work Order Approved, no work order (no Claude usage), moved during run, no transition, summary too large, missing criterion, cancelled, Jira rejects the description, re-plan replaces the previous plan, upload fails |
| `implementation-plan/claude-step.bats` | Only complete plans continue: every acceptance criterion covered, files to modify exist (for revisions, in the sections they change); the plan is never logged; the fallback warning; Opus by default, read-only tools; the review of a revision sees the whole revised plan |
| `implementation-plan/schema.bats` | Plan schema; both renderings (full plan, ticket summary); the summary replaces only the Implementation Plan section; Markdown tables and emphasis; revisions: splicing sections into the attached plan (replace, insert in order, remove, estimate line) and patching the summary |

Every scenario snapshots a **trace** — each step's result and every tracker call
— and checks every document sent to the tracker against Atlassian's ADF schema. The
main paths (ready, send back, revise) also snapshot the full request bodies
and the run summary. Claude's prompts aren't snapshotted (the agent-step
tests check what matters in them), so a prompt edit doesn't touch snapshots.

Claude's recorded answers are kept once per stage (`fixtures/claude/ready.json`
and the like); a scenario that needs a variant — a criterion missing, a
reviewed version — describes it as a jq edit of the recording
(`CLAUDE_FIXTURE_EDIT`, `CLAUDE_REVIEW_FIXTURE_EDIT` in `scenario.env`)
instead of storing a near-copy.

## Snapshots

When a change is intended, update the snapshots and **review the diff** — it
shows exactly how tickets, comments or tracker calls change:

```sh
npm run update-snapshots --prefix .github/agent-hub/tests && git diff .github/agent-hub/tests/
```

`shared/stage-workflow-shape.txt` records the shared stage workflow's steps
and `if:` conditions. `run_stage` in `lib/helpers.bash` mirrors them, so if
that snapshot changes, update the runner to match.

## Adding a scenario

1. Create `<stage>/scenarios/<name>/scenario.env` (variables are documented
   in `lib/mock-jira.bash`; defaults in `run_scenario`).
2. Add a `@test` calling `run_scenario <name>` to `scenarios.bats`.
3. `npm run update-snapshots --prefix .github/agent-hub/tests`, then check `expected/trace.txt`
   is what the workflow should do.

## Live evals

Why and when to run them: [docs/evals.md](../docs/evals.md).

Each stage's `evals/evals.bats` runs its agent step (draft and review) with
the **real** Claude Code CLI against sample tickets, in a copy of the
repository without the recorded test data (as the workflow's checkout sees
it). It checks the decision, the output schema, that the review ran, that
Claude made no attempt to reach outside the repository, and — for tickets that
proceed — the rendered ticket and the files it names. It uses Claude (typical
costs: [docs/claude-usage.md](../docs/claude-usage.md)), so it isn't part of
`npm test` and refuses to run unless `RUN_EVALS=1`, which only
`lib/run-evals.sh` sets — after you name a stage and type `use-claude`:

```sh
npm run evals --prefix .github/agent-hub/tests -- work-order                          # one stage
npm run evals --prefix .github/agent-hub/tests -- work-order --filter '^too-vague:'  # one case
```

or **Actions → Agent hub: Evals → Run workflow** with a stage and `use-claude` in
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
`helpers.bash` only sets `STAGE`, `SUITE_DIR` and `FIXTURES`;
`lib/helpers.bash` provides `extract_stage`, `run_stage` and `run_scenario`,
since every stage runs through the shared stage workflow. Add the folder to
the `test` and `update-snapshots` scripts in `package.json`; evals in
`<stage>/evals/` are found automatically, and the stage goes in the Agent hub:
Evals workflow's `stage` options (a test checks the list).
