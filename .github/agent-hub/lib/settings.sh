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

# The hub's repository variables (AGENT_HUB_*), read from VARS once — one jq
# call per step rather than one per setting — as _VAR_<name>, shell-quoted
# so no value is ever run. Invalid JSON reads as no variables (defaults).
for _var in $(compgen -v _VAR_); do unset "$_var"; done
eval "$(jq -r 'to_entries[] | select((.key | test("^AGENT_HUB_[A-Z0-9_]+$")) and (.value | type == "string"))
  | "_VAR_\(.key)=\(.value | @sh)"' <<< "${VARS:-"{}"}" 2>/dev/null || true)"

# setting <variable> <default>: the repository variable's value, or <default>
# when it isn't set (or is empty).
setting() {
  local var="_VAR_$1"
  printf '%s' "${!var:-$2}"
}

# setting_into <name> <variable> <default>: the same, assigned to <name> —
# without a subshell: every step loads every setting, and on macOS a
# subshell per setting was most of a step's start-up time.
setting_into() {
  local _var="_VAR_$2"
  printf -v "$1" '%s' "${!_var:-$3}"
}

# The stage's own settings come from repository variables
# AGENT_HUB_<STAGE>_<name> (e.g. AGENT_HUB_WORK_ORDER_MODEL), so every
# stage's settings are named the same way.
_STAGE_VAR_PREFIX="AGENT_HUB_$(printf '%s' "${STAGE:-}" | tr 'a-z-' 'A-Z_')_"
# stage_setting <name> <default>: the stage's setting.
stage_setting() { setting "$_STAGE_VAR_PREFIX$1" "$2"; }
# stage_setting_into <name> <setting> <default>: the same, assigned to <name>.
stage_setting_into() { setting_into "$1" "$_STAGE_VAR_PREFIX$2" "$3"; }

set -a
HUB_DIR=${HUB_DIR:-.github/agent-hub}
STAGE_DIR="$HUB_DIR/stages/$STAGE"
# The repository's own additions to the stages: shared/ and <stage>/ folders
# (docs/extending.md). Owned by the repository, so hub updates never touch it.
EXTENSIONS_DIR=${EXTENSIONS_DIR:-.github/agent-hub-extensions}

# Where tickets live: trackers/<tracker>/tracker.sh. Jira is the only one so far
# (GitHub Projects is planned).
setting_into TRACKER AGENT_HUB_TRACKER jira
# What runs the agent: lib/runners/<runner>.sh. Claude Code is the only one so far.
setting_into AGENT_RUNNER AGENT_HUB_RUNNER claude-code

# Expert review of every draft that goes ahead (docs/architecture.md): a
# strong model reviewing a draft catches what the drafter missed.
setting_into REVIEW_CLAUDE_MODEL AGENT_HUB_REVIEW_MODEL claude-opus-5-5
setting_into REVIEW_CLAUDE_FALLBACK_MODEL AGENT_HUB_REVIEW_FALLBACK_MODEL claude-sonnet-5-5

# The only sites Claude may fetch pages from (web search is unrestricted), so
# a malicious ticket can't get repository content sent to an arbitrary URL.
# Space-separated.
setting_into CLAUDE_FETCH_DOMAINS AGENT_HUB_CLAUDE_FETCH_DOMAINS 'docs.github.com developer.atlassian.com support.atlassian.com docs.anthropic.com docs.claude.com developer.mozilla.org nodejs.org docs.npmjs.com'

# The tracker's statuses and labels the stages depend on; they must match the
# tracker's setup (docs/jira.md, docs/github-projects.md).
setting_into INTAKE_STATUS AGENT_HUB_INTAKE_STATUS Intake
setting_into WORK_ORDER_STATUS AGENT_HUB_WORK_ORDER_STATUS 'Work Order'
setting_into WORK_ORDER_APPROVED_STATUS AGENT_HUB_WORK_ORDER_APPROVED_STATUS 'Work Order Approved'
setting_into PLAN_STATUS AGENT_HUB_IMPLEMENTATION_PLAN_STATUS 'Implementation Plan'
setting_into PLAN_APPROVED_STATUS AGENT_HUB_IMPLEMENTATION_PLAN_APPROVED_STATUS 'Implementation Plan Approved'
setting_into READY_FOR_REVIEW_STATUS AGENT_HUB_READY_FOR_REVIEW_STATUS 'Ready for Review'
setting_into APPROVED_STATUS AGENT_HUB_APPROVED_STATUS Approved
setting_into DONE_STATUS AGENT_HUB_DONE_STATUS Done
# The tracker group whose members may act on a build's items with /skip and
# /apply on the ticket (the same people who approve). Unset: no item
# commands are accepted — commenting on a ticket never authorises a change.
setting_into APPROVERS_GROUP AGENT_HUB_APPROVERS_GROUP ""
setting_into NEEDS_DETAILS_LABEL AGENT_HUB_NEEDS_DETAILS_LABEL needs-details
# Marks tickets waiting for a person; approving (the tracker's "…Approved"
# rules) removes it.
setting_into NEEDS_HUMAN_LABEL AGENT_HUB_NEEDS_HUMAN_LABEL needs-human
setting_into NEEDS_CLARIFICATION_LABEL AGENT_HUB_NEEDS_CLARIFICATION_LABEL needs-clarification

# A ticket's total Claude usage, across every stage: the runs that used
# Claude and their API-equivalent cost. Past either cap nothing more uses
# Claude for the ticket until a person removes the over-cap label, which
# allows one more cap's worth (docs/claude-usage.md, "Per-ticket caps").
setting_into TICKET_MAX_RUNS AGENT_HUB_TICKET_MAX_RUNS 10
setting_into TICKET_MAX_COST_USD AGENT_HUB_TICKET_MAX_COST_USD 60.00
# Claude Code stops a pass after the turn that crosses its budget, so a pass
# can cost more than its --max-budget-usd: this much is allowed for each pass,
# on top of its budget, when a run is admitted against the cap and when a
# pass with no report is counted.
setting_into PASS_OVERSHOOT_USD AGENT_HUB_PASS_OVERSHOOT_USD 1.00
setting_into OVER_CAP_LABEL AGENT_HUB_OVER_CAP_LABEL agent-hub-over-cap

# Comments starting with this are change requests (or retries); the tracker's
# "Revision Requested" rule starts a run for them, and the run marks them
# resolved once handled.
setting_into REVISE_COMMAND AGENT_HUB_REVISE_COMMAND /revise

# Comment titles that flag a ticket, and are recognised to resolve the flags
# later. The Needs details one must match the tracker's intake check comment.
NEEDS_DETAILS_TITLE='Needs details'
NEEDS_CLARIFICATION_TITLE='Needs clarification'

# The work order's section the plan summary goes into, and the attached plan's
# file name (KEY-<suffix>).
PLAN_SECTION='Implementation Plan'
PLAN_FILE_SUFFIX=implementation-plan.md
PLAN_FILE_NAME="${TICKET_KEY:-}-$PLAN_FILE_SUFFIX"
# The section the build adds to the plan file with its questions; the plan
# stage answers them in a revision and removes it.
BUILD_QUESTIONS_SECTION='Questions from the build'

# The tracker's limit on the description (Jira's: 32,000 characters): a stage
# that would exceed it says so clearly instead of the tracker rejecting the
# update.
DESCRIPTION_MAX_CHARS=32000

# Jira only: "false" suppresses watcher notifications for description
# updates (needs Jira admin permission for the API user).
setting_into JIRA_NOTIFY_USERS AGENT_HUB_JIRA_NOTIFY_USERS true

# shellcheck source=/dev/null
source "$STAGE_DIR/settings.sh"
set +a
