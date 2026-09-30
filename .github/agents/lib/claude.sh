# shellcheck shell=bash
# Running Claude for an agent stage: a draft, then an expert review of it, the
# output checks and the run summary. No Jira access — the Claude step never
# gets Jira credentials.
#
#   source "$AGENTS_DIR/lib/claude.sh"
#   claude_run "Prepare the work order for this Jira ticket." work_order
#   claude_check work_order needs-details missing      # the draft is usable
#   claude_review "Review this work order draft."
#   claude_check work_order needs-details missing      # the reviewed version is
#   claude_summary "Work order"                        # sets the step's `status`
#
# Revisions (RUNNER_TEMP/mode is "revision", set by the fetch step): Claude
# returns only the sections that change — `updates`, the stage's output with
# nothing required (to REVISION_DEPTH levels) — following lib/revise.md, and
# the review checks them against the whole revised document, which the
# stage's revise.sh builds (revision_preview). See docs/architecture.md.
#
# Reads: AGENT_DIR (prompt.md, schema.json, review.md, revise.sh), lib/review.md,
# lib/revise.md, lib/review-revision.md, RUNNER_TEMP/ticket.md, and the
# CLAUDE_* / REVIEW_CLAUDE_* settings from the workflow's env. Writes
# RUNNER_TEMP/claude-output.json (the draft, then the reviewed version with
# combined usage) and RUNNER_TEMP/review.json.

CLAUDE_OUTPUT="$RUNNER_TEMP/claude-output.json"
CLAUDE_REVIEW="$RUNNER_TEMP/review.json"

# Claude's answers hold ticket content, and run logs can be public (they are in
# public repositories), so they're never printed: logs show only outcomes and
# counts. The content goes to the ticket.

# _claude <model> <fallback> <budget> <system prompt file> <schema> <prompt> > output
_claude() {
  local tools domain
  # Read-only and scoped to the repository; page fetches only from
  # CLAUDE_FETCH_DOMAINS.
  tools="Read(./**),Grep(./**),Glob(./**),WebSearch"
  for domain in $CLAUDE_FETCH_DOMAINS; do tools="$tools,WebFetch(domain:$domain)"; done
  # Isolation: only the repository's own settings (not the runner owner's),
  # no hooks or MCP servers (they run outside the tool rules), and the write
  # and shell tools denied outright — allowlists alone don't bind subagents
  # whose definitions grant them.
  claude -p "$6" \
    --setting-sources project \
    --settings '{"disableAllHooks": true}' \
    --strict-mcp-config \
    --disallowedTools "Bash,Write,Edit,NotebookEdit" \
    --model "$1" \
    --fallback-model "$2" \
    --max-budget-usd "$3" \
    --append-system-prompt-file "$4" \
    --json-schema "$5" \
    --output-format json \
    --permission-mode dontAsk \
    --allowedTools "$tools" \
    < /dev/null || true
}

claude_revising() { [ "$(cat "$RUNNER_TEMP/mode" 2>/dev/null)" = revision ]; }

# claude_budget <cap>: the per-pass budget cap — a revision is scoped to the
# requested changes, so it has its own, lower cap (REVISION_MAX_BUDGET_USD)
# when the stage sets one.
claude_budget() {
  if claude_revising && [ -n "${REVISION_MAX_BUDGET_USD:-}" ]; then echo "$REVISION_MAX_BUDGET_USD"; else echo "$1"; fi
}

# claude_revision_schema <stage schema.json> <payload field>: a revision's
# output format — the stage's, with the payload replaced by `updates` (the
# same fields, none required to REVISION_DEPTH levels, so only what changes is
# returned; deeper objects stay complete) and revision_responses required.
claude_revision_schema() {
  jq -c --arg payload "$2" --argjson depth "${REVISION_DEPTH:-1}" '
    def optional($n): del(.required) | if $n > 1 and .properties
      then .properties |= map_values(if .type == "object" then optional($n - 1) else . end) else . end;
    (.properties[$payload] | optional($depth)
      | .description = "Only the sections that change, each complete. Everything left out stays exactly as it is.") as $updates
    | .properties |= (del(.[$payload]) + {updates: $updates})
    | .required = ((.required + ["revision_responses"]) | unique)' "$1"
}

# claude_run <instruction> <payload field>: the draft. Never fails itself —
# claude_check decides whether the result is usable.
claude_run() {
  local prompt="$AGENT_DIR/prompt.md" schema="$AGENT_DIR/schema.json"
  # Claude Code can update itself on the runner; record which version ran.
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1 | cut -d ' ' -f 1)
  if claude_revising; then
    # shellcheck source=/dev/null
    source "$AGENT_DIR/revise.sh"
    prompt="$RUNNER_TEMP/revise-prompt.md" schema="$RUNNER_TEMP/revision-schema.json"
    cat "$AGENT_DIR/prompt.md" "$AGENTS_DIR/lib/revise.md" > "$prompt"
    claude_revision_schema "$AGENT_DIR/schema.json" "$2" > "$schema"
  fi
  _claude "$CLAUDE_MODEL" "$CLAUDE_FALLBACK_MODEL" "$(claude_budget "$CLAUDE_MAX_BUDGET_USD")" \
    "$prompt" "$(jq -c . "$schema")" \
    "$(printf '%s\n\n<ticket>\n%s\n</ticket>' "$1" "$(cat "$RUNNER_TEMP/ticket.md")")" \
    > "$CLAUDE_OUTPUT"
}

# claude_check <payload field> <other status> <its field>: the result must be
# `ready` with the payload (`updates`, possibly empty, when revising), or
# <other status> with a non-empty <its field> (e.g. needs-details + missing).
# Fails the step otherwise.
claude_check() {
  local payload=$1
  claude_revising && payload=updates
  # Some jq versions (1.6) exit 0 on empty input, so check for output explicitly.
  if [ ! -s "$CLAUDE_OUTPUT" ] || ! jq -e --arg payload "$payload" --arg other "$2" --arg field "$3" '
        .is_error == false and (
          (.structured_output.status == "ready" and .structured_output[$payload] != null) or
          (.structured_output.status == $other and ((.structured_output[$field] // "") | length) > 0))' \
        "$CLAUDE_OUTPUT" > /dev/null 2>&1; then
    echo "::error::Claude returned no usable result."
    # The reason for the ticket's failure comment (see stage_fail).
    if jq -e '.subtype == "error_max_budget_usd"' "$CLAUDE_OUTPUT" > /dev/null 2>&1; then
      echo "Claude reached its budget cap before finishing. Comment $REVISE_COMMAND to try again; if it keeps happening, raise the stage's *_MAX_BUDGET_USD variable (docs/setup.md)." > "$RUNNER_TEMP/failure-reason"
    else
      echo "Claude didn't return a usable result (the run log has the error type). Comment $REVISE_COMMAND to try again." > "$RUNNER_TEMP/failure-reason"
    fi
    # The error type and messages only (e.g. error_max_budget_usd) — never
    # `result`, which can quote the ticket.
    jq -c '{is_error, subtype, errors, status: .structured_output.status}' "$CLAUDE_OUTPUT" 2>/dev/null \
      || echo "Claude Code produced no JSON output ($(wc -c < "$CLAUDE_OUTPUT" | tr -d ' ') bytes)."
    exit 1
  fi
  jq -r '"Claude returned \(.structured_output.status) in \(.num_turns) turns."' "$CLAUDE_OUTPUT"
}

# claude_review_schema <stage schema.json>: the review's output format — the
# stage's own format as `result`, plus the review notes.
claude_review_schema() {
  jq -c '{type: "object", additionalProperties: false, required: ["result", "review"],
    properties: {result: ., review: {type: "object", additionalProperties: false,
      required: ["note", "changes", "issues", "outcome_changed", "outcome_reason"],
      properties: {
        note: {type: "string", minLength: 1, maxLength: 300},
        changes: {type: "array", items: {type: "string", minLength: 1}},
        issues: {type: "array", items: {type: "string", minLength: 1}},
        outcome_changed: {type: "boolean"},
        outcome_reason: {type: "string"}}}}}' "$1"
}

# claude_review <instruction>: an expert review of the draft — verifies claims
# against the code, fixes errors, may change the outcome, simplifies and
# improves clarity — returning the final version in the draft's format plus
# review notes. claude-output.json becomes the reviewed version, with usage
# combined across both passes; review.json keeps the notes. Fails the step if
# the review doesn't produce a usable result: nothing unreviewed is applied.
claude_review() {
  local draft="$RUNNER_TEMP/claude-draft.json" prompt="$RUNNER_TEMP/review-prompt.md" schema input
  mv "$CLAUDE_OUTPUT" "$draft"
  input=$(printf '%s\n\n<ticket>\n%s\n</ticket>\n\n<draft>\n%s\n</draft>' "$1" \
    "$(cat "$RUNNER_TEMP/ticket.md")" "$(jq -c '.structured_output' "$draft")")
  # The shared review standard plus the stage's checklist.
  if claude_revising; then
    # shellcheck source=/dev/null
    source "$AGENT_DIR/revise.sh"
    # A revision: only the updates are returned, but the review sees the whole
    # document with them applied, to check it still hangs together.
    cat "$AGENTS_DIR/lib/review.md" "$AGENT_DIR/review.md" "$AGENTS_DIR/lib/review-revision.md" > "$prompt"
    schema=$(claude_review_schema "$RUNNER_TEMP/revision-schema.json")
    jq '.structured_output.updates // {}' "$draft" > "$RUNNER_TEMP/draft-updates.json"
    input=$(printf '%s\n\n<revised>\n%s\n</revised>' "$input" "$(revision_preview "$RUNNER_TEMP/draft-updates.json")")
  else
    cat "$AGENTS_DIR/lib/review.md" "$AGENT_DIR/review.md" > "$prompt"
    schema=$(claude_review_schema "$AGENT_DIR/schema.json")
  fi

  _claude "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$(claude_budget "$REVIEW_CLAUDE_MAX_BUDGET_USD")" "$prompt" "$schema" \
    "$input" > "$RUNNER_TEMP/claude-review-output.json"

  if [ ! -s "$RUNNER_TEMP/claude-review-output.json" ] || ! jq -e \
       '.is_error == false and .structured_output.result.status != null and .structured_output.review.note != null' \
       "$RUNNER_TEMP/claude-review-output.json" > /dev/null 2>&1; then
    echo "::error::The review returned no usable result, so the draft wasn't applied."
    echo "The expert review didn't return a usable result, so nothing was changed. Comment $REVISE_COMMAND to try again." > "$RUNNER_TEMP/failure-reason"
    jq -c '{is_error, subtype, errors}' "$RUNNER_TEMP/claude-review-output.json" 2>/dev/null \
      || echo "Claude Code produced no JSON output for the review."
    exit 1
  fi

  jq '.structured_output.review' "$RUNNER_TEMP/claude-review-output.json" > "$CLAUDE_REVIEW"
  # The reviewed version, with usage from both passes.
  jq -n --slurpfile d "$draft" --slurpfile r "$RUNNER_TEMP/claude-review-output.json" '
    $d[0] as $d | $r[0] as $r
    | {type: "result", subtype: $r.subtype, is_error: false,
       duration_ms: (($d.duration_ms // 0) + ($r.duration_ms // 0)),
       num_turns: (($d.num_turns // 0) + ($r.num_turns // 0)),
       total_cost_usd: (($d.total_cost_usd // 0) + ($r.total_cost_usd // 0)),
       modelUsage: (reduce (($d.modelUsage // {}), ($r.modelUsage // {}) | to_entries[]) as $e
         ({}; .[$e.key].costUSD += ($e.value.costUSD // 0))),
       permission_denials: (($d.permission_denials // []) + ($r.permission_denials // [])),
       draft_status: $d.structured_output.status,
       # The cost and turns of each pass, so the summary shows which costs what.
       draft_cost: ($d.total_cost_usd // 0), review_cost: ($r.total_cost_usd // 0),
       draft_turns: ($d.num_turns // 0), review_turns: ($r.num_turns // 0),
       # Characters of text in the draft and the reviewed version, to show
       # how much the review tightened it.
       draft_chars: ([$d.structured_output | .. | strings] | add // "" | length),
       final_chars: ([$r.structured_output.result | .. | strings] | add // "" | length),
       structured_output: $r.structured_output.result}' > "$CLAUDE_OUTPUT"

  jq -r --slurpfile out "$CLAUDE_OUTPUT" '"Review: \(.changes | length) change(s), \(.issues | length) issue(s) found, outcome \(if .outcome_changed then "changed" else "kept" end), \($out[0].draft_chars) → \($out[0].final_chars) characters."' "$CLAUDE_REVIEW"
  _fallback_warning "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$RUNNER_TEMP/claude-review-output.json" review
}

# _fallback_warning <model> <fallback> <output> <pass>: the fallback keeps runs
# working when a model is overloaded — or not supported by this Claude Code
# version — so say so rather than hide it.
_fallback_warning() {
  if jq -e --arg model "$1" '(.total_cost_usd // 0) as $total
       | [.modelUsage // {} | to_entries[] | select(.value.costUSD >= $total * 0.05) | .key]
       | length > 0 and (index($model) | not)' "$3" > /dev/null 2>&1; then
    echo "::warning title=Fallback model used::$1 wasn't used for the $4 (overloaded, or not supported by Claude Code ${CLAUDE_VERSION:-?} — try \`claude update\` on the runner). The run used the fallback, $2."
  fi
}

# claude_summary <title>: sets the step's `status` output and writes the run
# summary — result, the models that did the work (5%+ of the cost; Claude Code
# also uses a small model internally), whether the review changed the outcome,
# Claude Code version, duration, turns and API-equivalent cost.
claude_summary() {
  jq -r '"status=\(.structured_output.status)"' "$CLAUDE_OUTPUT" >> "$GITHUB_OUTPUT"
  jq -r --arg title "$1" --arg model "$CLAUDE_MODEL" --arg version "${CLAUDE_VERSION:-unknown}" \
      --slurpfile review "$CLAUDE_REVIEW" '
    (.total_cost_usd // 0) as $total
    | ([.modelUsage // {} | to_entries[] | select(.value.costUSD >= $total * 0.05) | .key]
       | join(", ") | if . == "" then $model else . end) as $models
    | ($review[0] // {}) as $r
    | "### \($title): \(env.TICKET_KEY)\n",
      "| Result | Review | Length | Models | Claude Code | Duration | Turns (draft + review) | Cost (API-equivalent) |",
      "|---|---|---|---|---|---|---|---|",
      "| \(.structured_output.status) | \(if $r.outcome_changed then "outcome changed (was \(.draft_status))" else "\($r.changes // [] | length) change(s)" end) | \(if (.draft_chars // 0) > 0 then "\(.final_chars) chars (\(((.final_chars - .draft_chars) * 100 / .draft_chars) | round)% vs draft)" else "-" end) | \($models) | \($version) | \(.duration_ms / 1000 | floor)s | \(.draft_turns) + \(.review_turns) | $\($total * 100 | round / 100) (draft $\(.draft_cost * 100 | round / 100), review $\(.review_cost * 100 | round / 100)) |",
      ""' \
    "$CLAUDE_OUTPUT" >> "$GITHUB_STEP_SUMMARY"
  _fallback_warning "$CLAUDE_MODEL" "$CLAUDE_FALLBACK_MODEL" "$RUNNER_TEMP/claude-draft.json" draft
}
