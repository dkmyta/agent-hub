# Extending the stages for your repository

The hub's stages are generic: they know how to write a work order or a plan,
not how *your* codebase works. Extensions add that knowledge — conventions,
where things live, which areas are risky, experts who know a subsystem — per
stage, without editing the hub.

They live in **`.github/agent-hub-extensions/`**, which belongs to your
repository: hub updates replace `.github/agent-hub/` and never touch it.
Everything here is optional; with no extensions the stages work as they are.
Installing the hub creates the folder with a README if it doesn't exist yet
(people read it; the stages only load the folders below).

## What you can add

| File | Used by | For |
|---|---|---|
| `guidance.md` | The agents that write: the work order or plan (and their revisions), the build, its fix pass — and the build's code review and fix check, which judge code by it | Conventions, terminology, where things live, how to build and test, what to always check or mention |
| `review.md` | The reviewers: the documents' expert review, the build's code review and fix check | Extra checks for the reviewer, on top of the hub's |

Which pass gets which, in one table: [architecture.md](architecture.md#agent-passes).
| `agents/<name>.md` | Both passes | Codebase experts ([Claude Code subagents](https://code.claude.com/docs/en/sub-agents)) the agent can ask about a part of the code |
| `skills/<name>/SKILL.md` (plus any files it uses) | Both passes | Know-how the agent loads when it's relevant ([Claude Code skills](https://code.claude.com/docs/en/skills)) |
| `README.md` | People only | Notes for whoever maintains the extensions |
| `checks.json` (in `build/` only) | The build's verify step — the hub, not the agent | The checks the hub runs on every build's commit, when your `package.json` scripts aren't the right ones ([below](#the-builds-checks)) |

Put each in **`shared/`** to apply to every stage, or in a folder named after
the stage (`work-order/`, `implementation-plan/`, later stages by their folder
name in `.github/agent-hub/stages/`):

```
.github/agent-hub-extensions/
  shared/
    guidance.md
    skills/house-style/SKILL.md
  work-order/
    guidance.md
    agents/billing-expert.md
  implementation-plan/
    guidance.md
    review.md
    agents/billing-expert.md
    agents/data-model-expert.md
```

## How the stages use them

- **Instructions:** the stage's own instructions come first, then the shared
  `guidance.md`, then the stage's — each under a heading saying it comes from
  the repository. The agent follows it wherever it doesn't conflict with the
  hub's instructions, so the output format, the read-only rules and the
  handling of ticket text as data always win. The review gets `review.md` the
  same way, after the hub's review standard and the stage's checklist.
- **Experts and skills:** loaded for both passes (draft and review). Claude
  Code lists them to the agent with their descriptions, and the agent decides
  when to use them. Their names are prefixed with the folder they're in —
  `work-order:billing-expert`, `shared:house-style` — which is how to refer to
  them in `guidance.md` ("For anything about invoices, ask
  `implementation-plan:billing-expert`").
- **The run log** names the folders loaded ("Repository extensions: …").

Your repository's own Claude Code setup is also available to every stage,
as it is to developers using Claude Code: `CLAUDE.md` (and
`.claude/CLAUDE.md`) joins the agent's instructions as repository guidance,
and `.claude/agents/` and `.claude/skills/` are loaded like an extension's.
The agents run in Claude Code's restricted mode, which doesn't load these by
itself, so the hub passes them explicitly (links are skipped). They add
guidance and expertise, never capabilities: agent and skill definitions keep
only their name, description and (agents) model, tools and colour — a
permission mode, hooks, MCP servers or pre-approved tools are dropped — and
the stage's tool profile and sandbox apply to them like everything else.
Claude Code's own bundled skills (configuration, scheduling and similar
helpers) are off for every stage. Use extensions for what only the pipeline needs, or what
differs per stage.

## What extensions can't do

Extensions add knowledge, never permissions:

- **Only the files above** (`checks.json` only in `build/`). Anything else — hooks, an MCP server config
  (`.mcp.json`), a plugin manifest (`.claude-plugin/`), settings, commands,
  symbolic links, folders inside `agents/` — stops the run before Claude
  starts, with a failure comment naming it. CI catches it earlier: the hub's
  tests check every extension folder, and that its name is `shared` or a
  stage (a typo like `work_order/` would otherwise never load).
- **Experts get the same restrictions as the agent**, whatever their own
  `tools:` line says: read-only, inside the repository, no shell, no writing
  or editing, no hooks or MCP servers, and web pages only from the allowed
  documentation sites. A `tools: Write` line has no effect.
- **Ticket text can't change them.** They come from the branch the run uses
  — the default branch for tracker requests, or the branch picked for a
  manual **Run workflow** — reviewed like code; a ticket is only ever data.

Treat them as code: they steer what the agents write, so changes go through
pull requests and review. Never put secrets in them.

## Examples

`work-order/guidance.md`:

```markdown
- The API lives in `services/api/`, the web app in `apps/web/`. A change to
  one usually needs a matching change to the other: say so in Scope.
- "Workspace" in tickets means an `Organization` in the code.
- Anything touching payments needs a note in Risk & Open Questions.
```

`implementation-plan/agents/billing-expert.md`:

```markdown
---
name: billing-expert
description: Knows the billing code (invoices, plans, Stripe webhooks). Use it for any change that touches billing, to find the code involved and its pitfalls.
tools: Read, Grep, Glob
---
You are the expert on this repository's billing code, in `services/api/billing/`.
Answer with file paths and line references. Point out: idempotency of webhook
handlers, currency rounding (always integer cents), and the migration rules in
`services/api/billing/README.md`.
```

`shared/skills/house-style/SKILL.md`:

```markdown
---
name: house-style
description: The team's writing conventions for tickets and plans. Use whenever writing a work order or a plan.
---
- British English.
- Name files with their full path from the repository root.
- Prefer a short list over a paragraph.
```

`implementation-plan/review.md`:

```markdown
## Repository checks
- Every database change has a migration and a rollback step.
- Feature flags are named `ff_<team>_<feature>`.
```

## The build's checks

The build's verify step runs your repository's checks on the build's commit,
in the hub's sandbox (no network but localhost), and pushes nothing if one
fails ([build.md](workflows/build.md#verify)). By default the checks are the
`package.json` scripts named `test`, `lint`, `typecheck` (or `type-check`)
and `build`. `build/checks.json` replaces them — for checks with other names,
a project in a subfolder, or a repository that isn't a Node project:

```json
{
  "checks": [
    { "name": "unit tests", "command": "npm --prefix web test" },
    { "name": "types", "command": "npm --prefix web run typecheck" }
  ],
  "install": ["web"]
}
```

- **`install`** (optional): folders, besides the root, whose dependencies the
  build installs from their lockfiles — for checks in a subfolder project
  with its own dependencies, e.g. `"install": ["web"]`. (The folders of a
  plan's dependency changes are installed anyway.)
- **Each check** has a `name` (shown on the pull request and the ticket) and
  a `command`, run with `bash` from the repository root; a non-zero exit is
  a failure. Neither may contain a tab or a line break.
- **Read from the plan's base commit**, as the repository was before the
  agent ran: a build can't change which checks judge it, and a change to
  `checks.json` applies from the next plan written after it's merged.
- **`{"checks": []}`** runs none. A file that isn't valid stops the build
  before anything is pushed; CI catches it earlier (the hub's tests read it
  as the verify step does).
- **Each check has a time limit** (`AGENT_HUB_BUILD_CHECK_MINUTES`, 10 by
  default, [setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults)) and runs with your
  dependencies installed, the Node version you declare and no network:
  checks that need a service or the internet belong in CI. They also run
  on the base commit before the agent (the
  [baseline](workflows/build.md#baseline)), so a check that can't pass in the
  sandbox stops builds before any Claude usage, until it's left out here.
- **It's read by the hub, not the agent**, so it isn't loaded into Claude's
  instructions and changing it doesn't post the **Agent behaviour changed**
  notice. The agent is told the checks will be re-run, and runs the
  repository's checks itself first.

## Writing good extensions

- **Say where and how, not the answer.** Point to the code and docs that
  matter instead of copying them; copies go stale.
- **Keep guidance short.** It's in every run's instructions — every page adds
  to the cost and dilutes the rest. A page or two per stage is plenty.
- **Make descriptions precise.** The agent picks experts and skills by their
  description: say what they know and when to use them.
- **Experts add work.** Each one the agent asks is extra turns and cost in
  that pass; add them for areas that are genuinely hard to find your way in,
  and check the run summary's cost after adding one. Leave out the `model:`
  line unless an expert really needs a different model — a larger one costs
  more on every question it answers.
- **Per stage, not everywhere.** Put something in `shared/` only if every
  stage needs it.

## Trying an extension

1. **Check the format** (no Claude usage): `claude plugin validate
   .github/agent-hub-extensions/<folder>` checks the experts' and skills'
   files.
2. **Open a pull request.** CI runs the hub's checks on extension changes,
   and posts the **Agent behaviour changed** notice naming the stages the
   change affects (all of them for `shared/`; README and `build/checks.json`
   edits don't count).
3. **Try it** on a real ticket, or — if it's worth the cost — run **Agent
   hub: Evals** for those stages ([evals.md](evals.md)). The run log's
   "Repository extensions: …" line shows what was loaded.

## Not yet

- **Context from other repositories** (read-only, for a stage that needs to
  know how another codebase works) is planned, not built.
- **Changing what the agents may do** — tools, permissions, network access —
  isn't something extensions will offer: the restrictions are the hub's, the
  same for every repository.
