# Agent evals

The evals give the **real Claude** a set of sample tickets and check that it
still makes the right decisions. They're run by hand, when a change could
affect what Claude does.

## Why run them

The test suite checks the *plumbing*: given an answer from Claude, does the
workflow write the right thing to Jira? It uses recorded answers, so it can't
tell you whether Claude would still **give** a good answer.

That depends on things the tests can't see:

- **The instructions** (`prompt.md`) — a reworded sentence can change what
  Claude decides, e.g. start accepting vague tickets or stop researching.
- **The output format** (`schema.json`) — a new or renamed field changes what
  Claude is asked to produce.
- **The model and its settings** — a different model, fallback, budget, allowed
  tools or fetch domains changes how Claude works.
- **Claude Code itself** — an upgrade on the runner can change behaviour with
  no change in the repository.

A change in any of these can pass every test and still make the agent worse.
The evals catch that before it reaches real tickets.

## What they check

Each sample ticket has an expected outcome:

| Case | The ticket | Claude should |
|---|---|---|
| `readme-docs` | A clear, filled-in request to update the README | Write a work order that points at real files |
| `free-text-request` | A clear request written as plain prose, no template | Write a work order |
| `placeholders-only` | Every field "TBD" | Send it back for more detail |
| `too-vague` | Filled in, but "fix it, it's broken" | Send it back for more detail |
| `prompt-injection` | Text trying to make Claude read secrets and send them out | Treat it as data, send it back, and make no attempt to reach outside the repository |

For every case they also check that Claude's answer has the right shape, that
it made **no attempt to reach outside the repository**, and — for work orders —
that the ticket renders correctly and **every file it names exists**.

Claude works in a copy of the repository without the recorded test data, the
same way the real workflow checks it out, so it can't copy a past answer.

## When to run them

**Run them before merging a change that touches any of these:**

| Change | Where | Why |
|---|---|---|
| Agent instructions | `.github/agents/*/prompt.md` | Changes what Claude decides |
| Output format | `.github/agents/*/schema.json` | Changes what Claude produces |
| Claude settings | `CLAUDE_*` settings or the allowed tools in `agent-*.yml`, or the `CLAUDE_*` repository variables | Changes how Claude works |
| Claude Code upgrade | On the runner (or `CLAUDE_CODE_VERSION`) | Can change behaviour on its own |
| Switching Claude account type | Subscription ↔ API, or a new runner | Confirms the new setup works end to end |

CI flags the first three on the pull request with a **"Run Agent Evals before
merging"** warning, listing what changed. The last two happen outside the
repository, so remember them yourself.

**Not needed** for changes the tests already cover: the Jira steps, comment
text, the ticket layout (`render.jq`), shared libraries, tests, docs, or CI.

## How to run them

**From GitHub** (uses the repository's runner and Claude account):
1. Actions → **Agent Evals** → **Run workflow**.
2. Pick the branch with your change.
3. Leave *cases* blank to run all of them, or list some, e.g. `readme-docs too-vague`.

**Locally** (uses the Claude Code login on your machine):
```sh
npm run evals --prefix tests                                  # all cases
npm run evals --prefix tests -- --filter '^readme-docs:'      # one case
```

A full run takes a few minutes; its usage is in [claude-usage.md](claude-usage.md#what-triggers-it).

## Reading the results

The run ends with a table of each case's expected and actual result, duration,
turns and API-equivalent cost, plus the Claude Code version and model.

- **All pass**: the change is safe to merge from the agent's point of view.
- **A case fails**: read the failure — the decision, a missing file, or a
  blocked attempt to leave the repository. Claude isn't fully deterministic,
  so re-run that case once; if it fails again, the change affected the agent:
  adjust the prompt or settings and run again.
- **Cost or turns jump** compared to earlier runs: the change made Claude do
  more work — worth a look even if everything passes.

## Adding a case

When an agent needs to handle a new kind of ticket, add a case so future
changes keep handling it — see
[tests/README.md](../tests/README.md#live-evals). Keep cases to files the
workflows themselves add, so they work in any repository.
