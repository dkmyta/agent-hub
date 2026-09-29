# Architecture and conventions

How the agent workflows are built. **Every new or updated agent workflow
follows these conventions**; `agent-work-order.yml` is the reference
implementation.

## The pattern

```mermaid
sequenceDiagram
  participant J as Jira
  participant R as Jira automation rule
  participant G as GitHub Actions
  participant C as Claude Code (read-only)
  J->>R: ticket created / description changed
  R->>R: conditions (status, has details)
  R->>J: move to the stage's status
  R->>G: repository_dispatch <stage>-requested {ticket_key}
  G->>J: fetch ticket, check status, post progress comment
  G->>C: ticket as data + stage prompt + output schema
  C-->>G: structured result (JSON)
  G->>J: apply result (description, comments, labels, transition)
  G->>J: clear progress comment (or turn it into a failure notice)
```

1. **Jira decides *when***. A Jira automation rule moves the ticket into the
   stage's status and sends `repository_dispatch` with **only the ticket key**.
2. **The workflow reads everything else from Jira**, so it always sees the
   current ticket and can be re-run by hand for any ticket.
3. **Claude only reads and decides.** It explores the repository with
   read-only, repo-scoped tools, researches with web search, and returns
   **structured output** matching the stage's JSON schema. It has no
   credentials and never calls Jira.
4. **Plain shell applies the result.** The Jira steps turn Claude's output into
   Jira's document format (ADF) and make the API calls, failing loudly on any
   error.

## Conventions

### Triggers and naming
- Event: `<stage>-requested` (`work-order-requested`, later `plan-requested`,
  `build-requested`). Payload: `{"ticket_key": "..."}` only.
- Also `workflow_dispatch` with a `ticket_key` input for manual runs.
- `run-name: "<Stage>: <ticket key>"` so the Actions list is scannable.
- File: `.github/workflows/agent-<stage>.yml`.

### Structure
- One job. Steps: **Fetch ticket** (`id: start`) → **Generate (Claude Code)**
  (`id: claude`) → one **Apply** step per outcome (`if:` on
  `steps.claude.outputs.status`) → **Clear progress comment** → **Report
  failure on ticket** (`if: failure()`).
- Everything Jira-specific that must match Jira (status names, labels, comment
  titles, standard messages) lives in the workflow's top-level `env:`.
- Agent files live in `.github/agents/<stage>/`: `prompt.md` (instructions,
  passed with `--append-system-prompt-file`), `schema.json` (output schema),
  `render.jq` (output → ticket layout). Shared code lives in
  `.github/agents/lib/` (`jira.sh`, `adf.jq`) — reuse it, don't copy it.

### Safety
- `concurrency` per ticket with `cancel-in-progress: true`: the newest request
  wins; the cleanup step runs on `success() || cancelled()` so a cancelled run
  leaves nothing behind.
- Every step has `timeout-minutes`, and together they fit within the job's
  (a test enforces it), so a slow step fails and is reported instead of the
  job being cancelled.
- Every step that writes to Jira first calls `jira_require_status` so a run
  never writes to a ticket that has moved on.
- Check prerequisites (e.g. a transition exists) **before** the first write,
  so a failure can't leave a half-processed ticket.
- Ticket data reaches scripts through `env:`, never `${{ }}` inside `run:`.
- Jira secrets only on the steps that call Jira — never on the Claude step.
- `actions/checkout` with `persist-credentials: false`.
- Claude: `--permission-mode dontAsk`, tools limited to
  `Read(./**),Grep(./**),Glob(./**),WebSearch` plus `WebFetch(domain:…)` for an
  allowlist of documentation sites (no fetching arbitrary URLs, so ticket text
  can't get repository content sent anywhere), pinned `--model` with
  `--fallback-model`, and a `--max-budget-usd` cap.
- Anything a later run needs to recognise (e.g. the Original Request comment)
  carries a fixed marker from `env:`, so re-runs are idempotent.
  The prompt treats ticket text and web pages as data, never instructions.
- The Claude step fails unless the output is complete and valid for its
  status (jq 1.6 treats empty input as success — check for output explicitly).

### Visibility
- A progress comment ("⏳ …" with a link to the run) while the run is active,
  deleted when it ends, or turned into "❌ … failed" with the run link.
- A run summary (`$GITHUB_STEP_SUMMARY`): result, model, duration, turns, cost.

### Jira document format
- Build all ticket content with `adf.jq` helpers; never hand-write ADF.
- Headings that later stages or automations look for (e.g. the Delivery
  section) are part of the contract — changing them is a breaking change.

## Adding a stage

1. Copy `agent-work-order.yml` and `.github/agents/work-order/`, rename.
2. Write the prompt and schema; keep `render.jq` building on `adf.jq`.
3. Add `tests/<stage>/` (scenarios, Claude-step tests, schema tests, evals) —
   see [tests/README.md](../tests/README.md).
4. Document it from [workflows/TEMPLATE.md](workflows/TEMPLATE.md).
5. Add the Jira rule, and list it in the PR's deployment steps.
