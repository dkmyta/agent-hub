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
stage_setting_into CLAUDE_MODEL MODEL claude-opus-5-5
stage_setting_into CLAUDE_FALLBACK_MODEL FALLBACK_MODEL claude-sonnet-5
stage_setting_into CLAUDE_MAX_BUDGET_USD MAX_BUDGET_USD 10.00
# The code review: a fresh session on the shared review model
# (AGENT_HUB_REVIEW_MODEL), with its own budget (stages/build/review.sh).
stage_setting_into BUILD_REVIEW_MAX_BUDGET_USD REVIEW_MAX_BUDGET_USD 5.00
# The fix pass and its fix check (stages/build/fix.sh): small, targeted
# passes on a faster model, each with its own budget.
stage_setting_into BUILD_FIX_MODEL FIX_MODEL claude-sonnet-5
stage_setting_into BUILD_FIX_FALLBACK_MODEL FIX_FALLBACK_MODEL claude-opus-5-5
stage_setting_into BUILD_FIX_MAX_BUDGET_USD FIX_MAX_BUDGET_USD 3.00
stage_setting_into BUILD_FIX_CHECK_MAX_BUDGET_USD FIX_CHECK_MAX_BUDGET_USD 1.00

# Not for real tickets yet: the stage runs only where a repository opts in,
# for development (playground/), with the repository variable
# AGENT_HUB_BUILD_PREVIEW=true. The build checks its own commit, reviews it
# and fixes it once, but nothing yet waits for CI, hands it off, or stops a
# later push from replacing what was reviewed; the gate comes off after the
# CI gate and hand-off (4d) and the runner prerequisites
# (docs/workflows/build.md, "Status").
stage_setting_into BUILD_PREVIEW PREVIEW false

# The Claude Code version the build runs with: exact (e.g. 2.1.280), never
# "latest" — the build's boundary rests on how that version enforces the
# sandbox, so the version can't change beneath it (step_fetch checks the
# runner has it). The same repository variable picks the version installed
# on GitHub-hosted runners.
setting_into CLAUDE_CODE_VERSION AGENT_HUB_CLAUDE_CODE_VERSION ""

# A code stage: the steps without an agent get GitHub (lib/github.sh, loaded
# by lib/load.sh); the workflow's code-stage input gives them the token.
CODE_STAGE=true

# The agent edits the checkout and runs commands in the sandbox
# (lib/runners/claude-code.sh, "build").
AGENT_PROFILE=build

# The branch pull requests go into (default: the repository's default
# branch), the label marking the hub's own pull requests, and the branch
# prefix (agent-hub/<KEY>).
stage_setting_into BUILD_TARGET_BRANCH TARGET_BRANCH ""
stage_setting_into BUILD_LABEL LABEL agent-hub
# A person's way to tell the hub to leave a pull request alone: with this
# label on it, a run changes nothing (reconcile.sh).
stage_setting_into BUILD_PAUSED_LABEL PAUSED_LABEL agent-hub-paused
BUILD_BRANCH_PREFIX=agent-hub/

# The gates' size limits (stages/build/gates.sh).
stage_setting_into BUILD_MAX_FILES MAX_FILES 50
stage_setting_into BUILD_MAX_LINES MAX_LINES 2000
stage_setting_into BUILD_MAX_FILE_LINES MAX_FILE_LINES 1000

# Time limits, in minutes, for installing the dependencies and for each of the
# repository's checks the verify step runs (docs/workflows/build.md, "Verify").
stage_setting_into BUILD_INSTALL_MINUTES INSTALL_MINUTES 10
stage_setting_into BUILD_CHECK_MINUTES CHECK_MINUTES 10
# How long the CI gate waits, in minutes, for the repository's required
# checks to report on a pull request's head before a person is asked
# (docs/workflows/build.md, "CI gate"): a required check can be path-filtered
# and never run.
stage_setting_into BUILD_CI_WAIT_MINUTES CI_WAIT_MINUTES 120
# How many CI fixes the hub pushes for one hand-off — counted from the last
# full review, so a person's commits (reviewed again) start a new count
# (docs/workflows/build.md, "CI gate"). Past it, a person.
stage_setting_into BUILD_CI_FIX_ATTEMPTS CI_FIX_ATTEMPTS 2

# The minimum age, in days, of any package version the dependency step
# chooses (docs/workflows/build.md, "Dependencies"): a version published more
# recently isn't used — most malicious releases are caught within days. 0
# for none.
stage_setting_into BUILD_MIN_RELEASE_AGE_DAYS MIN_RELEASE_AGE_DAYS 3

# The licences a package the dependency step adds may have, as SPDX ids
# (comma-separated): any other, or none, is a decision item for a person
# (docs/workflows/build.md, "Dependencies"). Permissive licences by default.
stage_setting_into BUILD_ALLOWED_LICENSES ALLOWED_LICENSES "MIT,MIT-0,ISC,BSD-2-Clause,BSD-3-Clause,0BSD,Apache-2.0,Unlicense,CC0-1.0,BlueOak-1.0.0,Zlib,Python-2.0"

# Whether the repository's checks run on the base commit before the agent
# (docs/workflows/build.md, "Baseline"): stop (a check already failing there
# stops the build before Claude is used), warn (build anyway) or off.
stage_setting_into BUILD_BASELINE BASELINE stop

# Ticket text in a public repository's pull requests, commits and comments:
# off unless set to true (docs/workflows/build.md, "Publication policy").
setting_into PUBLISH_TICKET_CONTENT AGENT_HUB_PUBLISH_TICKET_CONTENT false

# How to retry, in the failure comment (lib/stage.sh): a build starts on
# approval, not on a /revise comment.
RETRY_INSTRUCTIONS="move the ticket back to $PLAN_STATUS and approve it again, or re-run the \"Agent hub: Build\" workflow from GitHub Actions with the ticket key."

NEEDS_CLARIFICATION_MESSAGE='The build needs answers to these questions before it can start. They are also in the attached plan (Questions from the build): answer them with /revise, then approve the plan again.'
