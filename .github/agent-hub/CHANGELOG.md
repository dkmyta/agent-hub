# Changelog

What changed in each release of the agent hub, newest first. Each entry says
what a repository has to do when updating to it, under **Updating**
("Nothing" when it's just a file update). How to update:
[docs/updating.md](docs/updating.md).

## 2.0.0 — 2026-10-02

Preparation for the next stages: consistent settings, fewer Jira updates,
faster installs and updates.

- **Per-stage settings are named the same way for every stage:**
  `AGENT_HUB_<STAGE>_<setting>` (`MODEL`, `FALLBACK_MODEL`, `MAX_BUDGET_USD`,
  `REVIEW_MAX_BUDGET_USD`, `REVISION_MAX_BUDGET_USD`), and the review model is
  `AGENT_HUB_REVIEW_MODEL` / `AGENT_HUB_REVIEW_FALLBACK_MODEL` — see
  [docs/setup.md](docs/setup.md#4-set-variables-only-what-differs-from-the-defaults).
  Each stage's review budget is now its own (one variable used to set both).
- Each run makes fewer Jira updates: label changes go in the same request as
  the description, or together in one, so fewer Jira automation events.
- The update script is several times faster, and gives a repository without
  extensions a README on where they go.
- Local hooks lint on commit only; the tests run in CI (and by hand).

**Updating:** if you set any of these repository variables, rename them:

| Before | Now |
|---|---|
| `AGENT_HUB_CLAUDE_MODEL`, `_CLAUDE_FALLBACK_MODEL`, `_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_MODEL`, `_FALLBACK_MODEL`, `_MAX_BUDGET_USD` |
| `AGENT_HUB_REVISION_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_REVISION_MAX_BUDGET_USD` |
| `AGENT_HUB_PLAN_CLAUDE_MODEL`, `_PLAN_CLAUDE_FALLBACK_MODEL`, `_PLAN_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_IMPLEMENTATION_PLAN_MODEL`, `_FALLBACK_MODEL`, `_MAX_BUDGET_USD` |
| `AGENT_HUB_PLAN_REVISION_MAX_BUDGET_USD` | `AGENT_HUB_IMPLEMENTATION_PLAN_REVISION_MAX_BUDGET_USD` |
| `AGENT_HUB_REVIEW_CLAUDE_MAX_BUDGET_USD` | `AGENT_HUB_WORK_ORDER_REVIEW_MAX_BUDGET_USD` and `AGENT_HUB_IMPLEMENTATION_PLAN_REVIEW_MAX_BUDGET_USD` |
| `AGENT_HUB_REVIEW_CLAUDE_MODEL`, `_REVIEW_CLAUDE_FALLBACK_MODEL` | `AGENT_HUB_REVIEW_MODEL`, `_REVIEW_FALLBACK_MODEL` |

Contributors: remove the old push hook with
`pre-commit uninstall --hook-type pre-push`.

## 1.0.0 — 2026-10-02

The first release.

- Stages: **work order** (an intake ticket → a structured work order, or back
  for details) and **implementation plan** (an approved work order → a
  technical plan attached to the ticket, or back with questions), each with an
  expert review, scoped `/revise` revisions and reverse paths.
- Tracker: **Jira**. GitHub Projects: setup foundations and the intake form;
  its stages aren't connected yet.
- Agent runner: **Claude Code**, read-only and isolated; session files
  removed after every run.
- Repository extensions per stage (`.github/agent-hub-extensions/`).
- Install and update script, tests, evals and docs.

**Updating:** first install — follow [docs/setup.md](docs/setup.md).
