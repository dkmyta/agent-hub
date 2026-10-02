#!/usr/bin/env bash
# Lists changes between <base> and HEAD that can change how the agents decide
# — prompts, review and revision standards (lib/*.md), output schemas, how
# the agent is run (lib/runners/), the repository's extensions, and Claude
# settings —
# so CI can remind the author to run the evals (Agent hub: Evals). Prints nothing if none.
#
# With --stages, prints which stages' evals to run instead: one per line, or
# just `all` when a change affects every stage (the shared lib, the shared
# extensions, or a workflow that isn't a stage's own, e.g. agent-hub-evals.yml).
#
# Usage: agent-behaviour-changes.sh [--stages] <base ref or sha>   (run from the repository root)
set -euo pipefail
stages=false
if [ "${1:-}" = --stages ]; then stages=true; shift; fi
base=$1

HUB=.github/agent-hub
EXT=.github/agent-hub-extensions

changes() {
  git diff --name-only "$base"...HEAD -- "$HUB/stages/*/prompt.md" "$HUB/stages/*/schema.json" \
    "$HUB/stages/*/review.md" "$HUB/lib/*.md" "$HUB/lib/runners/*" "$EXT/*" ":(exclude)$EXT/*/README.md"

  # Claude settings — model, fallback, budget, fetch domains, allowed tools —
  # in the settings files and the agent-hub workflows.
  local file
  for file in $(git diff --name-only "$base"...HEAD -- "$HUB/lib/settings.sh" "$HUB/stages/*/settings.sh" \
      '.github/workflows/agent-hub-*.yml'); do
    git diff --unified=0 "$base"...HEAD -- "$file" \
      | grep -E '^[+-][^+-].*(CLAUDE_[A-Z_]+|_MAX_BUDGET_USD|--allowedTools|TOOLS=)' \
      | sed -E "s|^([+-])[[:space:]]*|$file: setting \\1 |" || true
  done
}

if [ "$stages" = false ]; then changes; exit 0; fi

found=$(changes | while IFS= read -r line; do
  case "$line" in
    "$HUB"/lib/*) echo all ;;
    "$HUB"/stages/*) stage=${line#"$HUB"/stages/}; echo "${stage%%/*}" ;;
    "$EXT"/shared/*) echo all ;;
    "$EXT"/*) stage=${line#"$EXT"/}; echo "${stage%%/*}" ;;
    .github/workflows/agent-hub-*)
      stage=${line#.github/workflows/agent-hub-}; stage=${stage%%.y*}
      if [ -d "$HUB/stages/$stage" ]; then echo "$stage"; else echo all; fi ;;
  esac
done | sort -u)
if grep -qx all <<< "$found"; then echo all; elif [ -n "$found" ]; then echo "$found"; fi
