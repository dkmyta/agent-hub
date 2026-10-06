# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the steps that source this file
# The build stage's own settings (shared ones: lib/settings.sh, which sources
# this file). Each is the repository variable AGENT_HUB_BUILD_<name>
# (stage_setting). See docs/workflows/build.md.

# The status a build starts from, and the failure comment's title.
HOME_STATUS=$PLAN_APPROVED_STATUS
FAILURE_TITLE='❌ Build failed'

# Writing code needs the strongest model and the largest budget
# (API-equivalent dollars; docs/claude-usage.md).
CLAUDE_MODEL=$(stage_setting MODEL claude-opus-5-5)
CLAUDE_FALLBACK_MODEL=$(stage_setting FALLBACK_MODEL claude-sonnet-5)
CLAUDE_MAX_BUDGET_USD=$(stage_setting MAX_BUDGET_USD 10.00)

# Not for real tickets yet: the stage runs only where a repository opts in,
# for development (playground/), with the repository variable
# AGENT_HUB_BUILD_PREVIEW=true. The build now runs in a known environment and
# checks its own commit (3c), but a person is still its only reviewer and
# nothing yet stops a later push from replacing what was reviewed; the gate
# comes off with the agent review and CI (PR 4; docs/workflows/build.md,
# "Status").
BUILD_PREVIEW=$(stage_setting PREVIEW false)

# The Claude Code version the build runs with: exact (e.g. 2.1.280), never
# "latest" — the build's boundary rests on how that version enforces the
# sandbox, so the version can't change beneath it (step_fetch checks the
# runner has it). The same repository variable picks the version installed
# on GitHub-hosted runners.
CLAUDE_CODE_VERSION=$(setting AGENT_HUB_CLAUDE_CODE_VERSION "")

# A code stage: the steps without an agent get GitHub (lib/github.sh, loaded
# by lib/load.sh); the workflow's code-stage input gives them the token.
CODE_STAGE=true

# The agent edits the checkout and runs commands in the sandbox
# (lib/runners/claude-code.sh, "build").
AGENT_PROFILE=build

# The branch pull requests go into (default: the repository's default
# branch), the label marking the hub's own pull requests, and the branch
# prefix (agent-hub/<KEY>).
BUILD_TARGET_BRANCH=$(stage_setting TARGET_BRANCH "")
BUILD_LABEL=$(stage_setting LABEL agent-hub)
BUILD_BRANCH_PREFIX=agent-hub/

# The gates' size limits (stages/build/gates.sh).
BUILD_MAX_FILES=$(stage_setting MAX_FILES 50)
BUILD_MAX_LINES=$(stage_setting MAX_LINES 2000)
BUILD_MAX_FILE_LINES=$(stage_setting MAX_FILE_LINES 1000)

# Time limits, in minutes, for installing the dependencies and for each of the
# repository's checks the verify step runs (docs/workflows/build.md, "Verify").
BUILD_INSTALL_MINUTES=$(stage_setting INSTALL_MINUTES 10)
BUILD_CHECK_MINUTES=$(stage_setting CHECK_MINUTES 10)

# Ticket text in a public repository's pull requests, commits and comments:
# off unless set to true (docs/workflows/build.md, "Publication policy").
PUBLISH_TICKET_CONTENT=$(setting AGENT_HUB_PUBLISH_TICKET_CONTENT false)

# How to retry, in the failure comment (lib/stage.sh): a build starts on
# approval, not on a /revise comment.
RETRY_INSTRUCTIONS="move the ticket back to $PLAN_STATUS and approve it again, or re-run the \"Agent hub: Build\" workflow from GitHub Actions with the ticket key."

NEEDS_CLARIFICATION_MESSAGE='The build needs answers to these questions before it can start. They are also in the attached plan (Questions from the build): answer them with /revise, then approve the plan again.'
