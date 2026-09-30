#!/usr/bin/env bash
# Runs the live evals (the real Claude — this uses Claude) for the stages named,
# so a run costs one stage's worth rather than every stage's. `all` runs every
# stage: only worth it after a model change or a Claude Code upgrade. Arguments
# from the first one starting with `-` go to bats (e.g. --filter).
#
#   npm run evals --prefix tests -- <stage>... | all [--filter '^<case>:']
#
# Asks you to type `use-claude` before anything runs (see below).
#
# EVALS_MAX_COST_USD (default 10) caps the run's total spend: once reached, the
# remaining cases are skipped. Each Claude call has its own cap too, so a run
# can end above it by at most one case's worth.
set -euo pipefail
cd "$(dirname "$0")/.."

available=$(for dir in */evals; do printf '%s ' "${dir%/evals}"; done)
dirs=() names=()
while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
  names+=("$1")
  if [ "$1" = all ]; then dirs+=(*/evals)
  elif [ -d "$1/evals" ]; then dirs+=("$1/evals")
  else echo "Unknown stage: $1. Stages with evals: ${available}all" >&2; exit 2
  fi
  shift
done
if [ ${#dirs[@]} -eq 0 ]; then
  echo "Name the stages to evaluate (each run uses Claude): ${available}or all" >&2
  exit 2
fi

EVALS_MAX_COST_USD="${EVALS_MAX_COST_USD:-10}"

# Evals use Claude, so every run is confirmed: typed at the prompt, or
# EVALS_CONFIRM=use-claude where there's no terminal (the Agent Evals workflow
# sets it once its own confirmation input matches).
if [ "${EVALS_CONFIRM:-}" != use-claude ]; then
  if [ ! -t 0 ]; then
    echo "Evals use Claude. To run them without a terminal, set EVALS_CONFIRM=use-claude." >&2
    exit 2
  fi
  echo "This runs the real Claude for: ${names[*]}. Each case costs about as much as a real ticket;" >&2
  echo "the run stops starting cases once it has spent \$$EVALS_MAX_COST_USD (see docs/claude-usage.md)." >&2
  read -r -p "Type use-claude to continue: " answer
  [ "$answer" = use-claude ] || { echo "Cancelled; nothing ran." >&2; exit 2; }
fi

EVALS_SPENT_FILE=$(mktemp)
trap 'rm -f "$EVALS_SPENT_FILE"' EXIT
echo 0 > "$EVALS_SPENT_FILE"
export RUN_EVALS=1 EVALS_SPENT_FILE EVALS_MAX_COST_USD
node_modules/.bin/bats --timing "${dirs[@]}" "$@"
