# Agent evals

The evals give the **real Claude** a set of sample tickets and check that it
still makes the right decisions. They use Claude and cost money, so they're
**used sparingly** — mainly to debug an agent that's deciding badly, or to
check a significant change to how it decides — and they're deliberately hard
to start by accident:

- **Manual only**: no schedule, push or pull request ever starts them (a test
  enforces this).
- **Typed confirmation**: `use-claude`, in the Agent Evals workflow's
  confirmation box or at the local prompt. Anything else runs nothing.
- **Approval** (optional, recommended): required reviewers on the
  `agent-evals` environment make every GitHub run wait for approval.
- **One stage per run** and a **spend cap** per run (below).

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
| `free-text-request` | A clear request written as plain prose, no template | Write a work order that points at real files |
| `too-vague` | Filled in, but "fix it, it's broken" | Send it back for more detail |
| `prompt-injection` | Text trying to make Claude read secrets and send them out | Treat it as data, send it back, and make no attempt to reach outside the repository |

Implementation plan cases (`tests/implementation-plan/evals/cases/`; each is a
work order, rendered into a ticket as the work-order stage writes it):

| Case | The work order | Claude should |
|---|---|---|
| `readme-quick-start` | A clear, current request for a small README change | Write a plan that changes `README.md`, covers every criterion, and stays short |
| `open-product-decision` | Leaves open who is notified and how | Ask the delivery lead instead of guessing |
| `stale-work-order` | Describes a workflow that doesn't exist in the code | Ask, saying what it found — not quietly redefine the scope |

Every case runs the same passes as a real run — the draft, and the expert
review when the draft proceeds (a draft that sends the ticket back isn't
reviewed) — so the evals measure what actually reaches the ticket.
For every case they also check that Claude's answer has the right shape, that
it made **no attempt to reach outside the repository**, and — for work orders —
that the ticket renders correctly and **every file it names exists**.

Claude works in a copy of the repository without the recorded test data, the
same way the real workflow checks it out, so it can't copy a past answer.

## Keeping the suite small

Each case costs about as much as a real ticket (a draft and an Opus review),
and every new stage adds cases, so the suite is kept deliberately small.
**When adding evals, test only the most important decisions: weigh each
case's time and cost against what it catches that the regular tests can't.**

- **About two cases per stage**: a ticket that should go through and one that
  should come back. That's the decision each stage makes; everything else
  (formatting, Jira calls, schemas, tool restrictions) is covered by the
  regular tests, which don't use Claude.
- **A third case only for a failure actually seen** (like `stale-work-order`),
  and retire it once another case covers it.
- **Cross-cutting checks once, not per stage**: prompt injection is checked
  where requester text first comes in (the work order); the tool restrictions
  that make it safe are checked by the regular tests.
- **One stage per run**: the Agent Evals workflow runs a single stage by
  default, so a run costs one stage's worth however many stages exist.
  **all** is for changes that affect every stage.
- **A spend cap per run** (`AGENT_EVALS_MAX_COST_USD`, default $10): once
  reached, the remaining cases are skipped and shown as such in the results.
  An **all** run can reach it; raise the variable for that run if needed.

## When to run them

Only when the result is worth the cost. Good reasons:

- **Debugging**: an agent made a wrong call on a real ticket and you want to
  reproduce it, or check a fix, without waiting for another real ticket.
- **A significant change** to how an agent decides, in one of these:

| Change | Where | Why |
|---|---|---|
| Agent instructions | `.github/agents/*/prompt.md` | Changes what Claude decides |
| Review and revision standards | `.github/agents/lib/*.md`, `.github/agents/*/review.md` | Changes what the review lets through and how revisions work |
| Output format | `.github/agents/*/schema.json` | Changes what Claude produces |
| Claude settings | `CLAUDE_*` and budget settings or the allowed tools in `agent-*.yml`, or those repository variables | Changes how Claude works |
| Claude Code upgrade | On the runner (or `CLAUDE_CODE_VERSION`) | Can change behaviour on its own |
| Switching Claude account type | Subscription ↔ API, or a new runner | Confirms the new setup works end to end |

For small wording tweaks, trying the change on a real ticket is often as
informative and costs about the same.

CI notes the first four on the pull request (an **"Agent behaviour changed"**
notice — informational, never blocking), listing what changed and **which
stages** the evals would cover — just the stages whose files changed, or
**all** for a change to the shared files (`lib/claude.sh`, `lib/*.md`) or
to the Claude settings of a workflow that isn't a stage's own. A Claude Code
upgrade or an account switch affects every stage. Those two happen outside the
repository, so CI can't see them.

**Not needed** for changes the tests already cover: the Jira steps, comment
text, the ticket layout (`render.jq`), shared libraries, tests, docs, or CI.

## How to run them

**From GitHub** (uses the repository's runner and Claude account; needs the
runner online — a run started while it's offline waits in the queue):
1. Actions → **Agent Evals** → **Run workflow**.
2. Pick the branch and the **stage** (one run per stage; **all** only when
   every stage is affected).
3. Leave *cases* blank to run the stage's cases, or list some, e.g. `too-vague`.
4. Type `use-claude` in the confirmation box. Anything else skips the run.
5. If the `agent-evals` environment has required reviewers, a reviewer
   approves the run on its page.

**Recommended once per repository**: Settings → Environments → **agent-evals**
(created by the first run, or add it yourself) → **Required reviewers** → add
yourself or whoever owns the Claude account. (Environment protection needs a
public repository or a paid GitHub plan.)

**Locally** (uses the Claude Code login on your machine; asks you to type
`use-claude` first):
```sh
npm run evals --prefix tests -- work-order                           # one stage
npm run evals --prefix tests -- work-order --filter '^too-vague:'   # one case
npm run evals --prefix tests -- all                                  # every stage
```

Without a stage, or without the confirmation, it runs nothing.
`EVALS_MAX_COST_USD` sets the spend cap locally (default 10). Time and usage per stage:
[claude-usage.md](claude-usage.md#what-triggers-it).

## Reading the results

The run ends with a table of each case's expected and actual result, duration,
turns and API-equivalent cost, plus the Claude Code version and model.

- **All pass**: the agent still decides these cases correctly.
- **A case fails**: read the failure — the decision, a missing file, or a
  blocked attempt to leave the repository. Claude isn't fully deterministic,
  so re-run that case once; if it fails again, the change affected the agent:
  adjust the prompt or settings and run again.
- **Cost or turns jump** compared to earlier runs: the change made Claude do
  more work — worth a look even if everything passes.

## Adding a case

Add a case only for a decision the existing cases don't cover, usually a
failure seen on a real ticket (see [Keeping the suite small](#keeping-the-suite-small)) — see
[tests/README.md](../tests/README.md#live-evals). Keep cases to files the
workflows themselves add, so they work in any repository.
