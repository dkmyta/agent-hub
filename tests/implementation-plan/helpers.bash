# shellcheck shell=bash
# Helpers for the implementation-plan suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export WORKFLOW="$REPO_DIR/.github/workflows/agent-implementation-plan.yml"
export STAGE_DIR="$TESTS_DIR/implementation-plan"
export FIXTURES="$STAGE_DIR/fixtures"
export BOUNCE_STATUS=needs-clarification
