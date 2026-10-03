# Implementation plan: PROJ-99 — Document the Jira to GitHub automation in the README

_Version: <time> — written from the approved work order on PROJ-99, against commit 135e47ddce8b34bf3869aa3e7ef25aee8a66c0ff._

**Estimate:** S — One README change and one new docs page, following existing patterns.

## Current State

README.md already has an intro, a pipeline diagram and a Workflows table linking into docs/; docs/workflows/ has pages for the work-order stage and docs/evals.md covers the evals, but the implementation-plan workflow has neither a table row nor a page.

## Approach

This repository's actual state does not match the ticket's premise. README.md is not a single line today: it already has an intro, a Mermaid pipeline diagram, a Workflows table, and links into a docs/ directory (docs/setup.md, docs/architecture.md, docs/evals.md, docs/runners.md, docs/claude-usage.md, docs/workflows/work-order.md). There is also no .github/workflows/agent-build.yml and no code-implementing, PR-opening stage anywhere in the repo. The real workflows under .github/workflows/ are agent-work-order.yml, agent-implementation-plan.yml, agent-evals.yml, and the non-agent CI workflow tests.yml. docs/architecture.md's own naming convention section (line 41-42) lists 'build-requested' as a stage planned for 'later' — i.e. the code-implementation/PR stage the ticket describes as agent-build.yml is still future work, not yet built. The plan therefore documents the pipeline as it actually exists.

Of the three Claude-using workflows, two are already fully documented: agent-work-order.yml has a Workflows table row plus docs/workflows/work-order.md, and agent-evals.yml has a table row plus docs/evals.md. The only real gap is agent-implementation-plan.yml (Stage 2 today: it turns an approved work order into a detailed implementation plan written back to the ticket, and does not touch git or open a pull request) — it has no Workflows table row and no docs/workflows/ page, even though CONTRIBUTING.md's 'Definition of done for workflow changes' (#4) requires exactly that for every workflow.

The fix follows the repository's own established convention instead of inlining full detail into README: extend README's existing pipeline intro/diagram and Workflows table with one new row for agent-implementation-plan.yml (mirroring the existing rows), and add docs/workflows/implementation-plan.md modelled on docs/workflows/work-order.md and started from docs/workflows/TEMPLATE.md, covering its trigger, end-to-end behaviour, and required runner/secrets — the same three things the ticket asks 'what must be configured' to cover. This keeps README itself at roughly its current length (a single scannable table row per workflow, as already used for the other two) while still letting someone configure or troubleshoot a Jira rule without reading the YAML, which is the ticket's real goal.

Per Dana Lead's comment, agent-evals.yml is covered too, but it already has a complete Workflows table row and a full docs/evals.md page that already states its trigger (manual only, no Jira event), runner (self-hosted + claude), and secrets (none required; ANTHROPIC_API_KEY only if using the Claude API) — so no changes are needed there; the plan confirms this rather than duplicating it.

**Why this approach:** docs/workflows/work-order.md and docs/evals.md are each ~100+ lines; inlining that level of detail for three workflows directly into README.md would both contradict the AC's 'roughly one page' / 'not a line-by-line YAML walkthrough' requirement and duplicate content CONTRIBUTING.md already mandates live in docs/workflows/*.md. Extending the existing table-row-plus-linked-page pattern is the smallest change consistent with how the other two workflows are already documented, satisfies Dana's 'briefly' instruction, and matches the codebase's own definition of done for a new workflow.

**Alternatives considered**

- **Write three full inline sections directly in README.md as the ticket's original acceptance criteria literally describe** — Would roughly triple README's length (each existing per-workflow doc runs 100+ lines), breaking the 'roughly one page' criterion, and would duplicate detail CONTRIBUTING.md already requires to live in docs/workflows/*.md — inconsistent with how agent-work-order.yml and agent-evals.yml are already documented in this exact repository.
- **Document a hypothetical agent-build.yml as the ticket's acceptance criteria describe (branch agent/<ticket_key>, draft PR, contents:write/pull-requests:write)** — No such file or behaviour exists anywhere in the repository; docs/architecture.md explicitly reserves the 'build-requested' stage name for later. Documenting it now would describe code that doesn't exist, contradicting the ticket's own instruction to 'describe current behavior as-is'.
- **Also rewrite docs/workflows/work-order.md's Jira automation-rule detail to the same level of confidence for the new implementation-plan page** — work-order.md's rule table (exact trigger conditions, smart-value formula) reflects a live Jira rule someone with access to that Jira project documented; this repository doesn't capture the equivalent detail for an 'Implementation Plan Requested' rule, so the new page states the GitHub-side contract precisely and flags the Jira-side trigger condition as something to confirm with whoever owns the Jira rules, rather than inventing specifics.

## Acceptance Criteria Coverage

| Acceptance criterion | How it's met | How to verify |
|---|---|---|
| README.md has a section for agent-work-order.yml covering: its trigger (work-order-requested repository_dispatch, plus manual workflow_dispatch with ticket_key), what a run does (fetches the ticket from Jira, has Claude review it read-only, writes back either a formatted work order or a needs-details bounce to Intake), and what must be configured (self-hosted runner with the claude label; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN). | Already satisfied by the existing repository: README.md's Workflows table has a row for agent-work-order.yml stating its trigger, and docs/workflows/work-order.md covers the read-only Claude review, the ready/needs-details/failed outcomes, the self-hosted+claude runner (AGENT_RUNS_ON default), and the three Jira secrets — all verified against .github/workflows/agent-work-order.yml's on:, runs-on:, and env:/secrets blocks. No changes are needed for this criterion; the plan only confirms it stays accurate after the other edits. | Read README.md's Workflows table row for agent-work-order.yml and docs/workflows/work-order.md, and confirm each still matches .github/workflows/agent-work-order.yml's on:, runs-on:, and secrets usage after the changes in this plan land. |
| README.md has a section for agent-build.yml covering: its trigger (jira-plan-approved repository_dispatch with ticket_key, summary, description payload fields), what a run does (Claude implements the change on a new agent/<ticket_key> branch, opens a draft PR against main, and a comment with the PR link is posted back to the Jira ticket), and what must be configured (self-hosted runner; contents:write and pull-requests:write permissions; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN). | agent-build.yml and the behaviour described (new branch, draft PR, contents:write/pull-requests:write) do not exist anywhere in this repository — confirmed by listing .github/workflows/ and by docs/architecture.md's naming convention section, which lists 'build-requested' as a stage planned for 'later'. The repository's actual current Stage 2 is .github/workflows/agent-implementation-plan.yml: triggered by repository_dispatch plan-requested (payload: only ticket_key) or workflow_dispatch with ticket_key, it has Claude research the codebase read-only and write a structured implementation plan into the ticket's 'Implementation Plan' description section, then moves the ticket to the 'Implementation Plan' Jira status for review — or, if Claude needs a directional decision, posts a 'Needs clarification' comment and returns the ticket to 'Work Order'. It never touches git or opens a pull request, and needs only contents: read plus the same three Jira secrets as agent-work-order.yml. The plan documents this real workflow in place of the nonexistent one, via a new README table row and a new docs/workflows/implementation-plan.md page (see Changes and Steps below). Documenting the future PR-opening stage is left until that workflow actually exists, consistent with 'describe current behavior as-is'. | Confirm `.github/workflows/agent-build.yml` does not exist. Read the new README.md table row and docs/workflows/implementation-plan.md and confirm they state plan-requested / {ticket_key} as the trigger, describe the plan-writing (not PR-opening) behaviour, and list contents: read plus JIRA_DOMAIN/JIRA_EMAIL/JIRA_API_TOKEN as the requirements, matching .github/workflows/agent-implementation-plan.yml's on:, permissions:, and env:/secrets blocks. |
| Only README.md is changed — no workflow YAML, prompt, schema, or script file under .github is touched. | The plan touches README.md and adds one new file, docs/workflows/implementation-plan.md, which lives outside .github/ entirely — it is the repository's established location for per-workflow documentation (CONTRIBUTING.md's 'Definition of done for workflow changes' #4, and the existing docs/workflows/work-order.md). No file under .github/ (workflow YAML, prompt, schema, or script) is created, modified, or deleted; .github/workflows/agent-work-order.yml, .github/workflows/agent-implementation-plan.yml, .github/workflows/agent-evals.yml and everything under .github/agents/ are read for reference only. | After the change, `git status`/`git diff --stat` shows only README.md and docs/workflows/implementation-plan.md touched, and neither appears under .github/. |
| The result reads as roughly one page: a short shared-pipeline intro plus one scannable subsection per workflow, not a line-by-line YAML walkthrough. | README.md keeps its current shape — a short intro paragraph, one Mermaid pipeline diagram, and a Workflows table with exactly one row per workflow — and only grows by two updated intro lines, a few extra diagram edges, and one new table row (for agent-implementation-plan.yml). Per-workflow detail (trigger specifics, payload fields, Jira setup, secrets, edge cases, known gaps) stays in each workflow's own docs/workflows/*.md page, exactly as already done for agent-work-order.yml and agent-evals.yml, so README stays roughly the length it is today rather than growing into a multi-page document with three inlined sections. This also matches Dana Lead's 'cover all three workflows, briefly' instruction. | Diff README.md before/after: the net addition should be roughly a dozen lines (two intro-sentence edits, a few Mermaid edges, one table row, one documentation-list bullet), not new multi-paragraph sections; each of the three workflows appears exactly once in the Workflows table. |

## Changes by File

- `README.md` (modify) — Extend the existing pipeline intro/diagram and Workflows table to include the real Stage 2 workflow (agent-implementation-plan.yml), and correct the intro sentence that still describes planning as future work.
  - Lines 3-6: change 'Claude Code does the preparation work (work orders today, planning and implementation next)' to reflect that implementation plans are already generated today, e.g. '...Claude Code does the preparation work (work orders and implementation plans today, code implementation next)...' — implementation plans are already live via agent-implementation-plan.yml; only the code-implementation/PR-opening stage (docs/architecture.md's future 'build-requested') is still to come.
  - Lines 8-16: extend the Mermaid flowchart past the current 'Work order written to ticket' end state to show the second stage, e.g.: `A[Ticket in Intake] -->|description has details| B[Work Order]`, `A -->|no details| A`, `B -->|work-order-requested| C[agent-work-order.yml]`, `C -->|ready, needs-human label| B`, `C -->|needs details| A`, `C -->|failed| Z[Failure comment + run link]`, `B -->|person approves the work order| D[Work Order Approved]`, `D -->|plan-requested| E[agent-implementation-plan.yml]`, `E -->|ready, needs-human label| F[Implementation Plan]`, `E -->|needs clarification| B`, `E -->|failed| Z`. Keep the same flowchart LR style and node-label conventions already used.
  - Workflows table (currently lines 31-35): insert a new row directly after the agent-work-order.yml row: Workflow `[\`agent-implementation-plan.yml\`](.github/workflows/agent-implementation-plan.yml)`, Trigger '`plan-requested` from Jira, or manual', What it does 'Turns an approved work order into a detailed implementation plan for a developer to build from, or sends it back to Work Order with questions', Docs '[implementation-plan.md](docs/workflows/implementation-plan.md)'.
  - Documentation list (currently lines 39-47): add a bullet next to the existing 'Work order workflow' bullet: '- [Implementation plan workflow](docs/workflows/implementation-plan.md) — usage, Jira setup, edge cases, known gaps'.
- `docs/workflows/implementation-plan.md` (add) — New per-workflow doc page for agent-implementation-plan.yml, modelled on docs/workflows/work-order.md and started from docs/workflows/TEMPLATE.md, so the Jira event, payload, runner and secrets are documented without reading the YAML.
  - Title and summary: `# Implementation plan (\`agent-implementation-plan.yml\`)` plus one or two sentences: turns an approved work order into a detailed implementation plan for a developer to build from, or sends it back with questions.
  - Info table (same shape as work-order.md's): Trigger — `repository_dispatch` `plan-requested` (Jira), payload `{"ticket_key": "..."}`, or **Run workflow** with a ticket key; Runs on — `AGENT_RUNS_ON` (default `[self-hosted, claude]`, the same runner requirement as the work-order stage — see runners.md); Model — `PLAN_CLAUDE_MODEL` (default `claude-opus-5-5`), falling back to `PLAN_CLAUDE_FALLBACK_MODEL` (default `claude-sonnet-5`), capped by `PLAN_CLAUDE_MAX_BUDGET_USD` (default 5.00); Agent files — `.github/agents/implementation-plan/`; Tests — `tests/implementation-plan/` (see Known gaps — only shared helpers exist today).
  - Ticket lifecycle: a `stateDiagram-v2` from Work Order Approved, mirroring work-order.md's style: ready -> plan written, ticket moved to Implementation Plan with needs-human label; needs clarification -> comment with questions + needs-clarification/needs-human labels, ticket back to Work Order; failed -> failure comment, ticket stays in Work Order Approved. Prose below the diagram must also cover the two extra pre/post-Claude safeguards unique to this stage (from agent-implementation-plan.yml's Fetch ticket and Claude steps): the run fails immediately, before Claude runs, if the ticket has no work order yet (no acceptance criteria, or no 'Implementation Plan' section in the description); and a 'ready' plan is rejected (run fails) if it doesn't cover every acceptance criterion's exact wording, or if it modifies/deletes a file that doesn't exist in the repository.
  - Jira setup: an 'Implementation Plan Requested' automation-rule section giving the GitHub-side contract precisely — dispatch endpoint, `Authorization: Bearer <token>` header, body `{"event_type": "plan-requested", "client_payload": {"ticket_key": "{{issue.key}}"}}` — matching work-order.md's rule-documentation format, but explicitly noting that the exact Jira-side trigger/condition for recognising an 'approved' work order (e.g. what action moves the ticket to Work Order Approved) isn't captured in this repository and should be confirmed against the live rule with whoever administers the Jira project, unlike the Work Order Requested rule whose configuration is fully documented in work-order.md. A 'Statuses, labels and text' table listing `JIRA_WORK_ORDER_APPROVED_STATUS` (default 'Work Order Approved'), `JIRA_IMPLEMENTATION_PLAN_STATUS` (default 'Implementation Plan'), `JIRA_WORK_ORDER_STATUS` (default 'Work Order', reused to bounce back), `JIRA_NEEDS_HUMAN_LABEL` (default 'needs-human', reused), `JIRA_NEEDS_CLARIFICATION_LABEL` (default 'needs-clarification'), and the fixed `NEEDS_CLARIFICATION_TITLE`/`NEEDS_CLARIFICATION_MESSAGE` text that must match the rule's own comment if it posts one.
  - Secrets and permissions: repository secrets `JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_API_TOKEN` (same as work-order.md); workflow permissions are `contents: read` only — call out explicitly that, unlike a future code-implementing stage, this workflow only reads the repository and writes to Jira, so it needs no elevated GitHub write permissions.
  - Edge cases table: ticket not in Work Order Approved (no-op with a notice); no work order present (acceptance criteria/Implementation Plan section missing) — run fails before Claude runs; plan omits an acceptance criterion or references a nonexistent file — run fails after Claude runs, before any Jira write; plan would exceed Jira's description size limit (`DESCRIPTION_MAX_CHARS`, default 32000) — run fails with a clear message; needs clarification — comment posted, labels added, ticket returned to Work Order; two requests in quick succession — concurrency group `implementation-plan-<ticket_key>` cancels the older run; manual run on a ticket not in Work Order Approved — no-op notice; Jira unreachable / Claude errors, times out, or exceeds budget — failure comment, same pattern as work-order.md.
  - Known gaps: test coverage — only `tests/implementation-plan/helpers.bash` exists today; scenario, Claude-step and schema tests analogous to `tests/work-order/` haven't been added yet (see tests/README.md's 'For new agent stages'); no live eval cases exist yet for this stage (docs/evals.md's case table only covers work-order cases); same caveats as work-order.md apply otherwise (posts as the JIRA_EMAIL person, no automatic retries, expired credentials fail quietly, evals are non-deterministic).
  - Testing section: reference tests/README.md and note the current gap (helpers only), same structure as work-order.md's Testing section.

## Scope & Governance

**Risk:** low — Documentation only: no code paths change, and a wrong instruction is easy to spot and fix.

| Change kind | In this plan |
|---|---|
| Dependencies | no |
| Schema or migration | no |
| Public API or contract | no |
| Auth or permissions | no |
| Sensitive data | no |
| Infrastructure | no |
| Workflow or CI | no |
| Configuration | no |

**Also in scope**

Nothing beyond Changes by File.

**Must not touch**

- `.github/workflows/**`

**Manual changes**

None.

## Implementation Steps

1. **Update the shared pipeline intro and diagram in README.md**
   - Edit the opening paragraph (README.md lines 3-6) so it no longer says planning is 'next' — implementation plans are generated today via agent-implementation-plan.yml; only code implementation/PR-opening remains future work.
   - Extend the Mermaid flowchart (README.md lines 8-16) with the additional nodes/edges for the Work Order Approved -> agent-implementation-plan.yml -> Implementation Plan / back-to-Work-Order / failure paths, as specified in the README.md change above, keeping the existing flowchart LR style.
   Files: `README.md`
   Covers: README.md has a section for agent-build.yml covering: its trigger (jira-plan-approved repository_dispatch with ticket_key, summary, description payload fields), what a run does (Claude implements the change on a new agent/<ticket_key> branch, opens a draft PR against main, and a comment with the PR link is posted back to the Jira ticket), and what must be configured (self-hosted runner; contents:write and pull-requests:write permissions; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN).; The result reads as roughly one page: a short shared-pipeline intro plus one scannable subsection per workflow, not a line-by-line YAML walkthrough.
2. **Add a Workflows table row and documentation-list bullet for agent-implementation-plan.yml**
   - Insert the new row into the Workflows table directly after the agent-work-order.yml row, using the same column format as the existing rows (Workflow link, Trigger, What it does, Docs link).
   - Add the matching bullet to the Documentation list near the bottom of README.md, alongside the existing 'Work order workflow' bullet.
   Files: `README.md`
   Covers: README.md has a section for agent-build.yml covering: its trigger (jira-plan-approved repository_dispatch with ticket_key, summary, description payload fields), what a run does (Claude implements the change on a new agent/<ticket_key> branch, opens a draft PR against main, and a comment with the PR link is posted back to the Jira ticket), and what must be configured (self-hosted runner; contents:write and pull-requests:write permissions; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN).; The result reads as roughly one page: a short shared-pipeline intro plus one scannable subsection per workflow, not a line-by-line YAML walkthrough.
3. **Write docs/workflows/implementation-plan.md**
   - Copy docs/workflows/TEMPLATE.md to docs/workflows/implementation-plan.md and fill in every section as specified in the docs/workflows/implementation-plan.md change above, cross-checking every fact against .github/workflows/agent-implementation-plan.yml's on:, permissions:, env: and steps, and against .github/agents/implementation-plan/prompt.md and schema.json for the 'what it does' and needs-clarification wording.
   - Keep the page's length and structure consistent with docs/workflows/work-order.md so the two read as a matched pair.
   Files: `docs/workflows/implementation-plan.md`
   Covers: README.md has a section for agent-build.yml covering: its trigger (jira-plan-approved repository_dispatch with ticket_key, summary, description payload fields), what a run does (Claude implements the change on a new agent/<ticket_key> branch, opens a draft PR against main, and a comment with the PR link is posted back to the Jira ticket), and what must be configured (self-hosted runner; contents:write and pull-requests:write permissions; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN).
4. **Re-verify the agent-work-order.yml and agent-evals.yml documentation is still accurate**
   - Re-read README.md's Workflows table row and docs/workflows/work-order.md against the current .github/workflows/agent-work-order.yml to confirm nothing drifted while editing the surrounding table and diagram.
   - Re-read README.md's Workflows table row and docs/evals.md against .github/workflows/agent-evals.yml; confirm no changes are needed there (per Dana Lead's 'cover all three workflows, briefly' — this workflow's coverage is already complete).
   Files: `README.md`, `docs/workflows/work-order.md`, `docs/evals.md`
   Covers: README.md has a section for agent-work-order.yml covering: its trigger (work-order-requested repository_dispatch, plus manual workflow_dispatch with ticket_key), what a run does (fetches the ticket from Jira, has Claude review it read-only, writes back either a formatted work order or a needs-details bounce to Intake), and what must be configured (self-hosted runner with the claude label; secrets JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN).
5. **Confirm scope and length**
   - Run `git status` / `git diff --stat` and confirm only README.md (modified) and docs/workflows/implementation-plan.md (added) appear, and neither path is under .github/.
   - Read README.md end to end and confirm it still reads as roughly one page: intro, one diagram, one Workflows table with three agent-workflow rows plus tests.yml, and a short Documentation list — no inlined per-workflow walkthroughs.
   Files: `README.md`, `docs/workflows/implementation-plan.md`
   Covers: Only README.md is changed — no workflow YAML, prompt, schema, or script file under .github is touched.; The result reads as roughly one page: a short shared-pipeline intro plus one scannable subsection per workflow, not a line-by-line YAML walkthrough.

## Testing

**Automated tests**

- None — this is a documentation-only change and adds no code, so no new automated tests are needed. The repository's local pre-push hook (`npm test --prefix tests`) only triggers on changes under .github/ or tests/ (see .pre-commit-config.yaml line 59), which this change doesn't touch.

**Commands**

```
pre-commit run --all-files (formatting/whitespace/EOF checks on the touched Markdown files; actionlint/shellcheck/tests hooks won't fire since no .github/ or tests/ file changed)
```

**Manual checks**

- Render README.md (e.g. GitHub's preview or a local Markdown/Mermaid renderer) and confirm the extended flowchart renders correctly and the new table row and documentation bullet's links resolve to real files (.github/workflows/agent-implementation-plan.yml, docs/workflows/implementation-plan.md).
- Render docs/workflows/implementation-plan.md and confirm its Mermaid diagram and tables render correctly, matching the style of docs/workflows/work-order.md.
- Walk through the new page as if setting up the Jira 'Implementation Plan Requested' rule: confirm the event name (`plan-requested`), payload (`{"ticket_key": "..."}`), runner requirement, and the three secrets are all obtainable from the page without opening agent-implementation-plan.yml.

## Security & Privacy

No security or privacy impact identified.

## Observability

No observability changes needed.

## Risks

- **The new docs/workflows/implementation-plan.md states the Jira automation rule's exact trigger/condition with less confidence than work-order.md does, since this repository doesn't capture a live example of that rule.** — The page documents the GitHub-side contract (event, payload, endpoint, token scope) precisely from the workflow file, and explicitly flags the Jira-side trigger condition as something to confirm with whoever administers the Jira project, rather than asserting unverified specifics.
- **Reviewers familiar with the original ticket text may expect to see 'agent-build.yml' documented and flag its absence as incomplete work.** — The PR description and the acceptance-criteria mapping in this plan explain, with evidence (no such file exists; docs/architecture.md reserves 'build-requested' for later), that the ticket's Stage 2 description doesn't match any file in the repository, and that agent-implementation-plan.yml — the real current Stage 2 — is documented in its place.
- **Extending the Mermaid diagram could make it visually busy or hard to keep 'roughly one page'.** — Keep new nodes/edges minimal (reuse the existing failure node, only add the two new nodes strictly needed for the second stage) and lean on the linked docs/workflows/implementation-plan.md page for detail beyond the diagram.

## Release & Rollback

No release steps beyond merging.

**Rollback:** Revert the single commit touching README.md and remove docs/workflows/implementation-plan.md (or `git revert` the commit) — no workflow, prompt, schema, script, or other runtime file is touched, so rollback has no effect on any running automation.

## Resolved Technical Questions

- **Does .github/workflows/agent-build.yml exist, with the trigger/branch/PR behaviour the ticket describes?** No. Listing .github/workflows/ shows only agent-work-order.yml, agent-implementation-plan.yml, agent-evals.yml and tests.yml. docs/architecture.md's naming-convention section (lines 41-42) explicitly lists 'build-requested' as a stage name reserved for 'later' — confirming the code-implementing, PR-opening stage described in the ticket's second acceptance criterion doesn't exist yet. Evidence: `Glob .github/workflows/*`, `docs/architecture.md:41-42`, `README.md:3-6 ('work orders today, planning and implementation next')`
- **What does the repository's actual second pipeline stage do, if not open a PR?** .github/workflows/agent-implementation-plan.yml is triggered by repository_dispatch plan-requested (payload: {"ticket_key": "..."}) or workflow_dispatch with a ticket_key input. It fetches the ticket from Jira, has Claude research the codebase read-only and write a structured implementation plan, then writes that plan into the ticket's 'Implementation Plan' description section and transitions the ticket to the 'Implementation Plan' status — or, if Claude flags a directional question, posts a 'Needs clarification' comment and returns the ticket to 'Work Order'. It never calls git or opens a pull request. Evidence: `.github/workflows/agent-implementation-plan.yml:1-14,96-224`, `.github/agents/implementation-plan/prompt.md`, `.github/agents/implementation-plan/schema.json`
- **Do the real Claude-using workflows target different runner labels, as the ticket's 'Important Details' claim ([self-hosted, claude] vs plain self-hosted)?** No — as they exist today, all three (agent-work-order.yml, agent-implementation-plan.yml, agent-evals.yml) default to the identical AGENT_RUNS_ON value ['self-hosted', 'claude'], because all three invoke Claude Code. The runner-label distinction the ticket describes belongs to the not-yet-built code-implementation stage (which presumably wouldn't need the Claude-logged-in account the same way), so it isn't part of what exists to document. Evidence: `.github/workflows/agent-work-order.yml:76`, `.github/workflows/agent-implementation-plan.yml:70`, `.github/workflows/agent-evals.yml:26`
- **Is README.md currently a single line, as the ticket's Overview states?** No. It already contains an intro paragraph, a Mermaid pipeline diagram, a Workflows table (3 rows plus tests.yml) and a Documentation list linking to six files under docs/. Only one real workflow (agent-implementation-plan.yml) is missing from that structure. Evidence: `README.md:1-48`
- **Is agent-evals.yml (the third workflow Dana Lead asked to cover) already documented, or does it need new content?** Already fully documented: README.md's Workflows table has a row for it (trigger: Manual; what it does: 'Live Claude evals of the agents' decisions'; docs: evals.md), and docs/evals.md covers why/when to run it, the sample cases, how to run it, and reading results. No secrets are required for it beyond optionally ANTHROPIC_API_KEY (only for the Claude-API path); it targets the same AGENT_RUNS_ON runner as the other two. No changes are needed for this workflow. Evidence: `README.md:29-36`, `docs/evals.md`, `.github/workflows/agent-evals.yml`
- **What secrets and permissions does agent-implementation-plan.yml actually require?** Secrets: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN (same &jira-env anchor pattern as agent-work-order.yml), plus optional ANTHROPIC_API_KEY only if using the Claude API instead of a subscription login. Permissions: contents: read only — it writes to Jira via the REST API, not to git, so it needs no write permissions (unlike the ticket's described, not-yet-built build stage). Evidence: `.github/workflows/agent-implementation-plan.yml:31-33,99-102,131-134`, `.github/agents/lib/jira.sh:1-5`

## Assumptions

- The ticket's acceptance criteria describing 'agent-build.yml' are treated as describing a stage that hasn't been built yet (confirmed by docs/architecture.md reserving 'build-requested' for later); the plan documents the real current second-stage workflow, agent-implementation-plan.yml, in its place, and leaves documenting an eventual PR-opening stage for when that workflow exists.
- 'Only README.md is changed' is read, per the same acceptance criterion's own clarifying clause ('no workflow YAML, prompt, schema, or script file under .github is touched'), as ruling out edits under .github/ — not as forbidding the repository's already-established docs/workflows/*.md convention (which CONTRIBUTING.md's definition of done requires for every workflow, and which the other two workflows already use). Creating docs/workflows/implementation-plan.md follows that existing convention rather than duplicating its content inline in README.
- The exact Jira-side trigger condition for an 'Implementation Plan Requested' automation rule (what specifically marks a work order as approved) isn't recorded anywhere in this repository, so the new doc page documents the GitHub-side contract precisely and notes that the live rule's condition should be confirmed with whoever administers the Jira project — mirroring the ticket's own out-of-scope note that configuring the Jira rules themselves is separate work.
- Per Dana Lead's comment ('Yes — cover all three workflows, briefly'), 'all three' is read as the three workflows that actually exist and touch Claude/Jira today — agent-work-order.yml, agent-implementation-plan.yml, agent-evals.yml — not a literal reading of the ticket's original two-workflow (work-order/build) framing.
- tests.yml (CI lint/tests) is left as already documented in README's Workflows table; it isn't a Jira-triggered agent workflow and isn't one of the three Dana Lead asked to cover.

## Expert review

Verified the draft against the code; no changes needed.

