#!/usr/bin/env bash
# Lists changes between <base> and HEAD that can change how the agents decide
# — prompts, output schemas, and Claude settings in the agent workflows — so
# CI can remind the author to run the Agent Evals. Prints nothing if none.
#
# Usage: agent-behaviour-changes.sh <base ref or sha>
set -euo pipefail
base=$1

git diff --name-only "$base"...HEAD -- '.github/agents/*/prompt.md' '.github/agents/*/schema.json'

# Claude settings in agent workflows: CLAUDE_* env values and the tool list.
git diff --unified=0 "$base"...HEAD -- '.github/workflows/agent-*.yml' \
  | grep -E '^[+-][^+-].*(CLAUDE_[A-Z_]+:|--allowedTools|TOOLS=)' \
  | sed -E 's/^([+-])[[:space:]]*/workflow setting \1 /' || true
