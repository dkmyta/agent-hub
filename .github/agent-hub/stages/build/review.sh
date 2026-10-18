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

# DECIDED: what approvers already decided on earlier reviews' items —
# skipped, or accepted (a decision) — with the finding each was about, for a
# re-review not to raise them again (2.28.0) and for the hint on a new item
# that looks like one (wording.jq, like_decided). Made by a reconcile run's
# start (reconcile.sh), which can read the ticket, when it goes on to a
# re-review. Carried from record to record (build_review_record), so a
# decision outlives the next review — and only from a record the hub can
# vouch for (2.28.1):
#   - none named (a first build, or no review yet): [].
#   - one named that can't be read: the run stops before anything changes,
#     so the re-review never replaces the record and loses its decisions.
#     A re-run tries again.
#   - one named that isn't it (changed on the ticket, or from before
#     2.21.0): nothing of it is carried — never decisions the hub can't
#     vouch for — and the re-check's report says the earlier decisions
#     weren't carried, so people know to decide them again.
# The 40 newest are kept: the record's own, in the order they were made,
# then this run's, by when they were decided.
DECIDED="$RUNNER_TEMP/decided.json"
_decided_findings() {
  local want record
  rm -f "$RUNNER_TEMP/decided-not-carried"
  want=$(jq -r '.review.record // ""' "$RECONCILE_STATE")
  if [ -z "$want" ]; then echo '[]' > "$DECIDED"; return 0; fi
  record=$(tracker_property agent-hub-review) \
    || stage_fail "Couldn't read $TICKET_KEY's record of the last review from $TRACKER_NAME — it holds what approvers decided on it, which the new review would lose — so nothing was changed. Re-run the build."
  if [ "$(review_record_hash <<< "$record")" != "$want" ]; then
    echo "::warning::$TICKET_KEY's record of the review isn't the one the pull request's record names (changed on the ticket, or from before 2.21.0), so what approvers decided on earlier reviews isn't carried into this one."
    : > "$RUNNER_TEMP/decided-not-carried"
    echo '[]' > "$DECIDED"
    return 0
  fi
  jq -n --argjson rec "$record" --slurpfile state "$RECONCILE_STATE" '
    def cut: if type == "string" and length > 300 then .[0:300] + "…" else . end;
    ($rec.decided // []) as $old
    | ([($state[0].items // [])[] | select(.status == "skipped" or .status == "accepted") | . as $i
        | (if .source == "review" then [($rec.review.findings // [])[] | select(.n == $i.finding)][0]
           elif .source == "fix-check" then [($rec.fix.new_concerns // [])[] | select(.n == $i.concern)][0]
           else null end) as $f
        | select($f != null)
        | {id: $i.id, status: $i.status, at: ($i.at // ""), kind: $f.kind, area: $f.area, file: ($f.file // ""), line: $f.line,
           title: $f.title, evidence: ($f.evidence | cut)}] | sort_by(.at)) as $new
    # Each once, the first time it was decided; in the order they were
    # decided (those in the record, then this run by when: the times in
    # the state, which the hub wrote); the newest 40.
    | reduce ($old[], $new[]) as $d ([]; if any(.[]; .id == $d.id) then . else . + [$d] end)
    | .[-40:]' > "$DECIDED" \
    || stage_fail "Couldn't read what approvers decided from $TICKET_KEY's record of the last review, so nothing was changed. Re-run the build."
}

# review_policy < findings JSON: each finding with its policy outcome — a
# decision kind or a decision area (a security finding, whatever its kind),
# or one outside the plan, is a person's decision. (The fix check's new
# concerns go through it too; /apply's findings don't: an approver chose them.)
review_policy() {
  jq -c --slurpfile p "$STAGE_DIR/review/policy.json" '$p[0] as $p
    | to_entries | map(.value + {n: (.key + 1), policy: (
        if (.value.kind | IN($p.decision_kinds[])) or (.value.area | IN(($p.decision_areas // [])[])) or (.value.within_plan | not) then "decision"
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
  # Made when the run started (reconcile.sh), where the ticket can be read.
  [ -s "$DECIDED" ] || echo '[]' > "$DECIDED"
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
  # A re-review: what approvers already decided, for it not to raise again.
  if [ "$(jq 'length' "$DECIDED")" -gt 0 ]; then
    input+=$(printf '\n\n<decided>\n%s\n</decided>\n' "$(jq -r '.[] | "- \(.id), \(.status) by an approver: \(.title) (\(.kind)\(if .file != "" then ", \(.file)\(if .line then ":\(.line)" else "" end)" else "" end)). \(.evidence)"' "$DECIDED")")
  fi

  # In its own clean copy of exactly the verified commit — not the checkout,
  # where the build agent may have left files (ignored ones too) — which its
  # sandbox keeps it from writing to.
  build_clean_copy "$head" "$RUNNER_TEMP/review-copy" 2> "$RUNNER_TEMP/review-copy-error" \
    || { _review_incomplete "a clean copy of the commit couldn't be made for it ($(head -n 1 "$RUNNER_TEMP/review-copy-error"))" "$head"; return 0; }
  (cd "$RUNNER_TEMP/review-copy" && agent_pass review "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$BUILD_REVIEW_MAX_BUDGET_USD" \
    "$STAGE_DIR/review/prompt.md" "$STAGE_DIR/review/schema.json" "$input") > "$output"

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
