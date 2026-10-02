# shellcheck shell=bash
# Helpers for the implementation-plan suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export STAGE=implementation-plan
export SUITE_DIR="$TESTS_DIR/implementation-plan"
export FIXTURES="$SUITE_DIR/fixtures"
