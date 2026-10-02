# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the steps that source this file
# Settings for a stage run: the shared ones below, then the stage's own
# (stages/<stage>/settings.sh). Each can be changed per repository with a
# repository variable (Settings → Secrets and variables → Actions →
# Variables); the defaults suit a fresh installation. All of them are
# documented in docs/setup.md.
#
# Sourced first by every step of the shared stage workflow, which passes the
# repository variables as JSON in VARS, and STAGE (the stage's folder name).
# Everything is exported: jq and the agent runner read some of it from the
# environment.

# setting <variable> <default>: the repository variable's value, or <default>
# when it isn't set (or is empty).
setting() {
  local value
  value=$(jq -r --arg name "$1" '.[$name] // empty' <<< "${VARS:-"{}"}" 2>/dev/null) || value=
  printf '%s' "${value:-$2}"
}

set -a
HUB_DIR=${HUB_DIR:-.github/agent-hub}
STAGE_DIR="$HUB_DIR/stages/$STAGE"
# The repository's own additions to the stages: shared/ and <stage>/ folders
# (docs/extending.md). Owned by the repository, so hub updates never touch it.
EXTENSIONS_DIR=${EXTENSIONS_DIR:-.github/agent-hub-extensions}

# Where tickets live: trackers/<tracker>/tracker.sh. Jira is the only one so far
# (GitHub Projects is planned).
TRACKER=$(setting AGENT_HUB_TRACKER jira)
# What runs the agent: lib/runners/<runner>.sh. Claude Code is the only one so far.
AGENT_RUNNER=$(setting AGENT_HUB_RUNNER claude-code)

# Expert review of every draft that goes ahead (docs/architecture.md): a
# strong model reviewing a draft catches what the drafter missed.
REVIEW_CLAUDE_MODEL=$(setting AGENT_HUB_REVIEW_CLAUDE_MODEL claude-opus-5-5)
REVIEW_CLAUDE_FALLBACK_MODEL=$(setting AGENT_HUB_REVIEW_CLAUDE_FALLBACK_MODEL claude-sonnet-5)

# The only sites Claude may fetch pages from (web search is unrestricted), so
# a malicious ticket can't get repository content sent to an arbitrary URL.
# Space-separated.
CLAUDE_FETCH_DOMAINS=$(setting AGENT_HUB_CLAUDE_FETCH_DOMAINS 'docs.github.com developer.atlassian.com support.atlassian.com docs.anthropic.com docs.claude.com developer.mozilla.org nodejs.org docs.npmjs.com')

# The tracker's statuses and labels the stages depend on; they must match the
# tracker's setup (docs/jira.md, docs/github-projects.md).
INTAKE_STATUS=$(setting AGENT_HUB_INTAKE_STATUS Intake)
WORK_ORDER_STATUS=$(setting AGENT_HUB_WORK_ORDER_STATUS 'Work Order')
WORK_ORDER_APPROVED_STATUS=$(setting AGENT_HUB_WORK_ORDER_APPROVED_STATUS 'Work Order Approved')
PLAN_STATUS=$(setting AGENT_HUB_IMPLEMENTATION_PLAN_STATUS 'Implementation Plan')
NEEDS_DETAILS_LABEL=$(setting AGENT_HUB_NEEDS_DETAILS_LABEL needs-details)
# Marks tickets waiting for a person; approving (the tracker's "…Approved"
# rules) removes it.
NEEDS_HUMAN_LABEL=$(setting AGENT_HUB_NEEDS_HUMAN_LABEL needs-human)
NEEDS_CLARIFICATION_LABEL=$(setting AGENT_HUB_NEEDS_CLARIFICATION_LABEL needs-clarification)

# Comments starting with this are change requests (or retries); the tracker's
# "Revision Requested" rule starts a run for them, and the run marks them
# resolved once handled.
REVISE_COMMAND=$(setting AGENT_HUB_REVISE_COMMAND /revise)

# Comment titles that flag a ticket, and are recognised to resolve the flags
# later. The Needs details one must match the tracker's intake check comment.
NEEDS_DETAILS_TITLE='Needs details'
NEEDS_CLARIFICATION_TITLE='Needs clarification'

# The work order's section the plan summary goes into, and the attached plan's
# file name (KEY-<suffix>).
PLAN_SECTION='Implementation Plan'
PLAN_FILE_SUFFIX=implementation-plan.md

# Jira only: "false" suppresses watcher notifications for description
# updates (needs Jira admin permission for the API user).
JIRA_NOTIFY_USERS=$(setting AGENT_HUB_JIRA_NOTIFY_USERS true)

# shellcheck source=/dev/null
source "$STAGE_DIR/settings.sh"
set +a
