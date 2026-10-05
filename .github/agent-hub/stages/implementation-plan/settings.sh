# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the steps that source this file
# The implementation-plan stage's own settings (shared ones: lib/settings.sh,
# which sources this file).

# The status a new plan is written from (revisions run in PLAN_STATUS), and
# the failure comment's title.
HOME_STATUS=$WORK_ORDER_APPROVED_STATUS
FAILURE_TITLE='❌ Implementation plan failed'

# Planning needs deeper reasoning than work orders, so a stronger model and
# larger budgets (API-equivalent dollars; typical costs: docs/claude-usage.md).
# Each is the repository variable AGENT_HUB_IMPLEMENTATION_PLAN_<name>
# (stage_setting).
CLAUDE_MODEL=$(stage_setting MODEL claude-opus-5-5)
CLAUDE_FALLBACK_MODEL=$(stage_setting FALLBACK_MODEL claude-sonnet-5)
CLAUDE_MAX_BUDGET_USD=$(stage_setting MAX_BUDGET_USD 5.00)
REVIEW_CLAUDE_MAX_BUDGET_USD=$(stage_setting REVIEW_MAX_BUDGET_USD 5.00)
# A revision is scoped to the requested changes, so each of its passes has
# this lower cap instead.
REVISION_MAX_BUDGET_USD=$(stage_setting REVISION_MAX_BUDGET_USD 2.00)

NEEDS_CLARIFICATION_MESSAGE='The implementation plan needs answers to these questions before it can be written. Answer them in the work order or in a comment, then move the ticket to Work Order Approved to try again.'
