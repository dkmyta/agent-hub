# shellcheck shell=bash
# The build's code review (docs/workflows/build.md, "Review (read-only)"): a
# fresh session with the review profile — commands, no edits, no web — reads
# the approved plan, the build's whole diff and the checks' results, and
# reports findings. The hub sorts each one by its policy (review/policy.json):
# a decision item for a person, fix-eligible (fixed once by the fix pass:
# fix.sh) or a review item. The review
# changes nothing, and one that can't finish never costs the build: Apply
# pushes the draft with the review as a decision item.
#
# Sourced by stage.sh. Writes code-review.json:
#   {status: reviewed | incomplete, head, reason?, summary?, cost,
#    findings: [{n, area, severity, kind, within_plan, file, line, title,
#                evidence, suggestion, policy: decision | fix | review}]}

CODE_REVIEW="$RUNNER_TEMP/code-review.json"
# Over this, the diff is left out of the prompt (the reviewer reads the
# changed files itself, from the list).
REVIEW_DIFF_MAX_BYTES=400000

# _review_incomplete <reason>: record a review that didn't finish, for Apply.
# The reason is the hub's own words, never Claude's.
_review_incomplete() {
  jq -n --arg reason "$1" --arg head "$2" '{status: "incomplete", head: $head, reason: $reason, findings: []}' > "$CODE_REVIEW"
  echo "::warning::The code review didn't finish ($1). The draft pull request carries it as a decision item for a person."
  echo "**Code review:** didn't finish — $1." >> "$GITHUB_STEP_SUMMARY"
}

# review_policy < findings JSON: each finding with its policy outcome.
review_policy() {
  jq -c --slurpfile p "$STAGE_DIR/review/policy.json" '$p[0] as $p
    | to_entries | map(.value + {n: (.key + 1), policy: (
        if (.value.kind | IN($p.decision_kinds[])) or (.value.within_plan | not) then "decision"
        elif (.value.kind | IN($p.fix_kinds[])) and (.value.severity | IN($p.fix_severities[])) then "fix"
        else "review" end)})'
}

step_review() {
  local head base input output="$RUNNER_TEMP/code-review-output.json" diff="$RUNNER_TEMP/review.diff" problems
  # The trusted metadata (build_git), in a subshell: the review's own
  # commands mustn't inherit it.
  head=$(build_git && git rev-parse HEAD)
  base=$(context .base)
  [ "$head" = "$(jq -r '.head' "$RUNNER_TEMP/verify.json" 2> /dev/null)" ] \
    || { _review_incomplete "the commit isn't the one the checks passed on" "$head"; return 0; }
  # A CI fix (handoff.sh): no code review — the failed checks are the
  # findings, each fix-eligible, for the fix pass (fix.sh) to work on, with
  # what the check reported as the evidence. The earlier review still
  # stands for the change.
  if reconciling && ci_fixing; then
    jq -n --arg head "$head" --slurpfile failures "$RUNNER_TEMP/ci-failures.json" '
      {status: "reviewed", source: "ci", head: $head, summary: "Required checks failed.", cost: 0, duration_ms: 0,
       findings: [$failures[0] | to_entries[] | {n: (.key + 1), area: "ci", severity: "high", kind: "ci-failure",
         within_plan: true, file: "", line: null, policy: "fix",
         title: "The required check \"\(.value.name)\" failed (\(.value.conclusions | unique | join(", ")))",
         evidence: (if .value.evidence == "" then "GitHub reported no details for it." else .value.evidence end),
         suggestion: "Find why it fails — in the code or in the test — and fix the cause."}]}' > "$CODE_REVIEW"
    echo "**Code review:** none — a CI fix: $(jq '.findings | length' "$CODE_REVIEW") failed required check(s) for the fix pass." >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi
  # An /apply (commands.sh): no code review — the requested items and review
  # threads are the findings, each for the fix pass, as the command built
  # them.
  if reconciling && applying; then
    jq -n --arg head "$head" --slurpfile f "$RUNNER_TEMP/apply-findings.json" \
      '{status: "reviewed", source: "apply", head: $head, summary: "Items an approver asked for.", cost: 0, duration_ms: 0, findings: $f[0]}' > "$CODE_REVIEW"
    echo "**Code review:** none — an /apply: $(jq '.findings | length' "$CODE_REVIEW") requested item(s) for the fix pass." >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi
  # Reconciling a merge of mechanical drift only: the earlier review still
  # applies (reconcile.sh), and no Claude runs.
  if reconciling && ! reconcile_reviews; then
    jq -n --arg head "$head" --slurpfile prev "$RECONCILE_STATE" \
      '{status: "carried", head: $head, reviewed: $prev[0].review.head, cost: 0, duration_ms: 0, findings: []}' > "$CODE_REVIEW"
    echo "**Code review:** carried over — the merge brought only mechanical drift, so the review of $(jq -r '.review.head[0:7]' "$RECONCILE_STATE") still applies." >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi
  (build_git && git diff --no-color --no-ext-diff "$base" "$head") > "$diff" \
    || { _review_incomplete "the build's changes couldn't be listed" "$head"; return 0; }
  if [ "$(wc -c < "$diff" | tr -d ' ')" -gt "$REVIEW_DIFF_MAX_BYTES" ]; then
    { echo "(The diff is too large to include: read each changed file yourself.)"; (build_git && git diff --stat=200 "$base" "$head"); } > "$diff"
  fi
  input=$(printf '<ticket>\n%s\n</ticket>\n\n<checks>\n%s\n</checks>\n\n<diff>\n%s\n</diff>\n' \
    "$(cat "$RUNNER_TEMP/ticket.md")" \
    "$(jq -r 'if (.checks | length) == 0 then "The repository declares no checks." else .checks[] | "\(.name) (\(.command)): \(.result)" end' "$RUNNER_TEMP/verify.json")" \
    "$(cat "$diff")")

  agent_pass review "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$BUILD_REVIEW_MAX_BUDGET_USD" \
    "$STAGE_DIR/review/prompt.md" "$STAGE_DIR/review/schema.json" "$input" > "$output"

  if [ ! -s "$output" ] || ! jq -e '.is_error == false and (.structured_output.findings | type == "array")
       and (.structured_output.summary | type == "string")' "$output" > /dev/null 2>&1; then
    if jq -e '.subtype == "error_max_budget_usd"' "$output" > /dev/null 2>&1; then
      _review_incomplete "it reached its budget cap (AGENT_HUB_BUILD_REVIEW_MAX_BUDGET_USD)" "$head"
    else
      _review_incomplete "Claude returned no usable result" "$head"
    fi
    # The error type only — never `result`, which can quote the ticket.
    jq -c '{is_error, subtype, errors}' "$output" 2> /dev/null || echo "Claude Code produced no JSON output for the review."
    return 0
  fi
  # Findings name files in the repository, by a relative path.
  problems=$(jq -r '[.structured_output.findings[] | .file | select(. != "" and (startswith("/") or test("(^|/)\\.\\.(/|$)")))] | length' "$output")
  [ "$problems" = 0 ] || { _review_incomplete "$problems finding(s) named a file outside the repository" "$head"; return 0; }

  jq -c '.structured_output.findings' "$output" | review_policy > "$RUNNER_TEMP/review-findings.json"
  jq -n --arg head "$head" --slurpfile out "$output" --slurpfile findings "$RUNNER_TEMP/review-findings.json" '
    {status: "reviewed", head: $head, summary: $out[0].structured_output.summary,
     cost: ($out[0].total_cost_usd // 0), duration_ms: ($out[0].duration_ms // 0), findings: $findings[0]}' > "$CODE_REVIEW"
  # Counts only: findings quote the code and can echo the ticket.
  jq -r '"**Code review:** \(.findings | length) finding(s) — \([.findings[] | select(.policy == "decision")] | length) decision item(s), \([.findings[] | select(.policy == "fix")] | length) fix-eligible, \([.findings[] | select(.policy == "review")] | length) review item(s); $\(.cost * 100 | round / 100)."' \
    "$CODE_REVIEW" | tee -a "$GITHUB_STEP_SUMMARY"
}
