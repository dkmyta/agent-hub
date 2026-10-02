# shellcheck shell=bash
# Helpers for the work-order suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export STAGE=work-order
export SUITE_DIR="$TESTS_DIR/work-order"
export FIXTURES="$SUITE_DIR/fixtures"
