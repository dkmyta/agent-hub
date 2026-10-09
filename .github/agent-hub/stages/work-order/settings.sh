# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the steps that source this file
# The work-order stage's own settings (shared ones: lib/settings.sh, which
# sources this file).

# The status this stage works in, and the failure comment's title.
HOME_STATUS=$WORK_ORDER_STATUS
FAILURE_TITLE='❌ Work order generation failed'

# Each is the repository variable AGENT_HUB_WORK_ORDER_<name> (stage_setting).
stage_setting_into CLAUDE_MODEL MODEL claude-sonnet-5-5
# Used automatically when the model is overloaded.
stage_setting_into CLAUDE_FALLBACK_MODEL FALLBACK_MODEL claude-opus-5-5
# Stops a runaway run; exceeding it fails the run with the failure comment.
# API-equivalent dollars (typical costs: docs/claude-usage.md). With a Claude
# subscription nothing is billed but runs use the plan's limits, so this
# protects those; with an API key it caps spend.
stage_setting_into CLAUDE_MAX_BUDGET_USD MAX_BUDGET_USD 2.00
stage_setting_into REVIEW_CLAUDE_MAX_BUDGET_USD REVIEW_MAX_BUDGET_USD 2.00
# A revision is scoped to the requested changes, so each of its passes has
# this lower cap instead.
stage_setting_into REVISION_MAX_BUDGET_USD REVISION_MAX_BUDGET_USD 1.00

# The Needs details comment: must match the tracker's intake check comment
# (Jira: the Work Order Requested rule).
# shellcheck disable=SC1112 # curly apostrophes intended
NEEDS_DETAILS_MESSAGE='This ticket doesn’t have enough detail to generate a work order, so it’s in Intake until more is added. Update the description, or add the details in a comment starting with /revise, to resubmit it automatically.'
# Closes the Original Request comment; also how a re-run recognises it.
ORIGINAL_REQUEST_NOTE='Captured from the original intake form before the work order replaced the description.'
