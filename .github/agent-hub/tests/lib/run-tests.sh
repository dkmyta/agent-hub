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
# One sort order on every machine (some languages sort run.sh before
# SKILL.md): collation only, so text is still read as UTF-8.
if [ -n "${LC_ALL:-}" ]; then export LANG=$LC_ALL; unset LC_ALL; fi
export LC_COLLATE=C
# The scenarios run the playground's tests (node --test) with the first node
# on PATH: an older one there fails them all in confusing ways, far from the
# cause. Node 20 or later, first on PATH.
if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2> /dev/null; then
  echo "The tests need Node 20 or later first on PATH; $(command -v node || echo "no node") is $(node --version 2> /dev/null || echo "missing"). Put a newer one first (e.g. nvm use 22), then run them again." >&2
  exit 2
fi

jobs=${AGENT_HUB_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 1)}
if [ "$jobs" -gt 1 ] && command -v parallel > /dev/null; then
  exec node_modules/.bin/bats --jobs "$jobs" "$@"
fi
if [ "$jobs" -gt 1 ]; then
  echo "Running the tests one at a time. Install GNU parallel to run them in parallel (macOS: brew install parallel; Ubuntu: apt-get install parallel)." >&2
fi
exec node_modules/.bin/bats "$@"
