#!/usr/bin/env bash
# Runs the bats suites named (`npm test`, `npm run update-snapshots`): in
# parallel, one job per CPU, when GNU parallel is installed (bats needs it for
# --jobs); one test at a time otherwise. Arguments go to bats.
#
# AGENT_HUB_TEST_JOBS sets the number of jobs (1: one at a time).
set -euo pipefail
cd "$(dirname "$0")/.."
# The tests never use Claude: whatever the shell exported, no eval mode
# (lib/run-evals.sh sets these, after a typed confirmation).
unset REAL_CLAUDE RUN_EVALS EVALS_CONFIRM EVALS_SPENT_FILE

jobs=${AGENT_HUB_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 1)}
if [ "$jobs" -gt 1 ] && command -v parallel > /dev/null; then
  exec node_modules/.bin/bats --jobs "$jobs" "$@"
fi
if [ "$jobs" -gt 1 ]; then
  echo "Running the tests one at a time. Install GNU parallel to run them in parallel (macOS: brew install parallel; Ubuntu: apt-get install parallel)." >&2
fi
exec node_modules/.bin/bats "$@"
