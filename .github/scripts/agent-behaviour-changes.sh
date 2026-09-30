#!/usr/bin/env bash
# Lists changes between <base> and HEAD that can change how the agents decide
# — prompts, review and revision standards (lib/*.md), output schemas, how
# Claude is run (lib/claude.sh), and Claude settings in the agent workflows —
# so CI can remind the author to run the Agent Evals. Prints nothing if none.
#
# With --stages, prints which stages' evals to run instead: one per line, or
# just `all` when a change affects every stage (the shared lib, or a workflow
# that isn't a stage's own, e.g. agent-evals.yml).
#
# Usage: agent-behaviour-changes.sh [--stages] <base ref or sha>
set -euo pipefail
stages=false
if [ "${1:-}" = --stages ]; then stages=true; shift; fi
base=$1

changes() {
  git diff --name-only "$base"...HEAD -- '.github/agents/*/prompt.md' '.github/agents/*/schema.json' \
    '.github/agents/*/review.md' '.github/agents/lib/*.md' '.github/agents/lib/claude.sh'

  # Claude settings in agent workflows: CLAUDE_* env values and the tool list.
  local workflow
  for workflow in $(git diff --name-only "$base"...HEAD -- '.github/workflows/agent-*.yml'); do
    git diff --unified=0 "$base"...HEAD -- "$workflow" \
      | grep -E '^[+-][^+-].*(CLAUDE_[A-Z_]+:|_MAX_BUDGET_USD:|--allowedTools|TOOLS=)' \
      | sed -E "s|^([+-])[[:space:]]*|$workflow: workflow setting \1 |" || true
  done
}

if [ "$stages" = false ]; then changes; exit 0; fi

found=$(changes | while IFS= read -r line; do
  case "$line" in
    .github/agents/lib/*) echo all ;;
    .github/agents/*) stage=${line#.github/agents/}; echo "${stage%%/*}" ;;
    .github/workflows/agent-*)
      stage=${line#.github/workflows/agent-}; stage=${stage%%.y*}
      if [ -d ".github/agents/$stage" ]; then echo "$stage"; else echo all; fi ;;
  esac
done | sort -u)
if grep -qx all <<< "$found"; then echo all; elif [ -n "$found" ]; then echo "$found"; fi
