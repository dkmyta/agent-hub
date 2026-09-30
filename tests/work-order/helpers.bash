# shellcheck shell=bash
# Helpers for the work-order suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export WORKFLOW="$REPO_DIR/.github/workflows/agent-work-order.yml"
export STAGE_DIR="$TESTS_DIR/work-order"
export FIXTURES="$STAGE_DIR/fixtures"
export BOUNCE_STATUS=needs-details
