# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the steps that source this file
# The implementation-plan stage's own settings (shared ones: lib/settings.sh,
# which sources this file).

# The status a new plan is written from (revisions run in PLAN_STATUS), and
# the failure comment's title.
HOME_STATUS=$WORK_ORDER_APPROVED_STATUS
FAILURE_TITLE='❌ Implementation plan failed'

# Planning needs deeper reasoning than work orders, so it has its own model
# and budget (API-equivalent dollars; typical costs: docs/claude-usage.md).
CLAUDE_MODEL=$(setting AGENT_HUB_PLAN_CLAUDE_MODEL claude-opus-5-5)
CLAUDE_FALLBACK_MODEL=$(setting AGENT_HUB_PLAN_CLAUDE_FALLBACK_MODEL claude-sonnet-5)
CLAUDE_MAX_BUDGET_USD=$(setting AGENT_HUB_PLAN_CLAUDE_MAX_BUDGET_USD 5.00)
REVIEW_CLAUDE_MAX_BUDGET_USD=$(setting AGENT_HUB_REVIEW_CLAUDE_MAX_BUDGET_USD 5.00)
# A revision is scoped to the requested changes, so each of its passes has
# this lower cap instead.
REVISION_MAX_BUDGET_USD=$(setting AGENT_HUB_PLAN_REVISION_MAX_BUDGET_USD 2.00)

NEEDS_CLARIFICATION_MESSAGE='The implementation plan needs answers to these questions before it can be written. Answer them in the work order or in a comment, then move the ticket to Work Order Approved to try again.'
# The tracker's limit on the description (Jira's: 32,000 characters); a
# summary that would exceed it fails the run with a clear message instead of
# the tracker rejecting the update.
DESCRIPTION_MAX_CHARS=32000
