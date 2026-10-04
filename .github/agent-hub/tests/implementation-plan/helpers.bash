# shellcheck shell=bash
# Helpers for the implementation-plan suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export STAGE=implementation-plan
export SUITE_DIR="$TESTS_DIR/implementation-plan"
export FIXTURES="$SUITE_DIR/fixtures"
# The plan stage starts from the work-order stage's output: the same tickets
# (a written work order; a ticket with none) and Claude's generic error
# output, kept once, in the work-order suite.
export WORK_ORDER_FIXTURES="$TESTS_DIR/work-order/fixtures"
