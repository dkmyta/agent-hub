# shellcheck shell=bash
# The CI gate and the hand-off (4d-1; docs/workflows/build.md, "CI gate",
# "Hand-off" and "Contracts"). When a reconcile run finds the pull request
# exactly as the hub last left it, and up to date with its target, it reads
# the repository's required checks for exactly that head:
#
#   pending (or not reported yet)  → nothing, until they finish (the CI sweep
#                                    wakes the run again), or a person after
#                                    AGENT_HUB_BUILD_CI_WAIT_MINUTES
#   any failed                     → a person (CI fixes are 4d-2)
#   nothing required on the target → a person: the hub can't tell when CI passed
#   all passed                     → hand-off, if the pull request is eligible;
#                                    otherwise a person, told why
#
# Each result is reported once per head (the state block's ci record), so the
# sweep doesn't wake the run again until something changes. Sourced by
# stage.sh; runs in the fetch step, before anything installs or runs code.

# handoff_problems <head> < state: why the pull request isn't eligible for
# hand-off, one reason per line (none: eligible). The hand-off rule, from the
# record alone — the hub's words, never Claude's:
#   - the head is the last one the hub recorded;
#   - the reviewed commit is among the recorded heads, and every head after
#     it is the hub's: a fix verified on exactly that commit, or a merge of
#     the target with mechanical drift verified on exactly that commit — a
#     person's commit, or any other, needs a full review first;
#   - the review finished, and no decision item is open.
handoff_problems() {
  jq -r --arg head "$1" '
    (.heads // []) as $heads | (.review.head // "") as $reviewed
    | ([$heads[].head] | index($reviewed)) as $at
    | (if ($heads | length) == 0 or $heads[-1].head != $head then
        "the pull request'"'"'s head isn'"'"'t the last commit the hub recorded" else empty end),
      (if $at == null then
        "the hub'"'"'s record doesn'"'"'t show which recorded commit was reviewed (a record from an older version of the hub)"
       else
        ($heads[$at + 1:][] | select((.by == "hub" and (.verified.head // "") == .head
              and (.kind == "fix" or (.kind == "sync" and .sync.drift == "mechanical"))) | not)
          | "commit \(.head[0:7]), after the last full review, isn'"'"'t a verified fix or a mechanical merge of the target by the hub, so the change needs reviewing again")
       end),
      (if (.review.status // "") == "incomplete" then "the automated review didn'"'"'t finish" else empty end),
      ([.items[]? | select((.id | startswith("D")) and .status == "open")] | length
        | if . > 0 then "\(.) decision item\(if . == 1 then "" else "s" end) still open" else empty end)'
}

# _reconcile_ci <number> <head>: the CI gate, on the head _reconcile_start
# found. Ends the run.
_reconcile_ci() {
  local number=$1 head=$2 target required ci state at waited
  target=$(context .target)
  required=$(ci_required "$target") \
    || stage_fail "Couldn't read which checks $target requires from GitHub, so nothing was changed."
  ci=$(ci_status "$head" "$required") \
    || stage_fail "Couldn't read pull request #$number's checks from GitHub, so nothing was changed."
  printf '%s\n' "$ci" > "$RUNNER_TEMP/ci.json"
  state=$(jq -r '.state' <<< "$ci")
  # Names and results only: the checks are the repository's own.
  jq -r '.checks[] | "CI \(.name): \(.result)"' <<< "$ci"
  case "$state" in
    pending)
      at=$(jq -r '.heads[-1].at // empty' "$RECONCILE_STATE")
      waited=$(jq -rn --arg at "$at" 'if $at == "" then 0 else (now - ($at | fromdate)) / 60 | floor end')
      if [ "$waited" -ge "$BUILD_CI_WAIT_MINUTES" ]; then
        _ci_person "timed out" "the repository's required checks haven't all reported on $(_short "$head") after $BUILD_CI_WAIT_MINUTES minutes ($(_ci_names "$ci" pending missing)) — a required check that's path-filtered never runs" \
          "re-run or fix the checks, then the hub picks the result up; or review the pull request without them"
      fi
      _ci_done "waiting for the required checks on $(_short "$head") ($(_ci_names "$ci" pending missing))" ;;
    failed)
      _ci_person failed "required checks failed on $(_short "$head"): $(_ci_names "$ci" failed)" \
        "fix the failures on the branch (the hub re-checks what's pushed), or re-run the checks if they were flaky" ;;
    unconfigured)
      _ci_person unconfigured "$target requires no checks (branch protection or a ruleset), so the hub can't tell when CI has passed" \
        "require the repository's CI checks on $target (docs/setup.md), or review the pull request without the hub's hand-off" ;;
    green) _handoff "$number" "$head" ;;
  esac
}

_short() { printf '%s' "${1:0:7}"; }

# _ci_names <ci JSON> <result>...: the checks with those results, as a list.
_ci_names() {
  local ci=$1
  shift
  jq -r '[.checks[] | select(.result | IN($ARGS.positional[])) | .name] | join(", ")' --args "$@" <<< "$ci"
}

# _ci_done <why>: the run ends with nothing to do.
_ci_done() {
  echo "Pull request #$(context .pr): $1."
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$(context .pr) — $1; nothing to do." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "no change needed"
  exit 0
}

# _ci_record <result> [handed off]: the CI result for the current head, in
# the state block — so it's reported once, and the sweep leaves it until it
# changes — and, with a second argument, the hand-off.
_ci_record() {
  jq -c --slurpfile ci "$RUNNER_TEMP/ci.json" --arg result "$1" --arg handoff "${2:-}" '
    .ci = {head: $ci[0].head, result: $result, checks: $ci[0].checks, at: (now | todate)} | del(.superseded)
    | if $handoff != "" then .handoff = {head: $ci[0].head, at: .ci.at} else . end' "$RECONCILE_STATE" > "$RUNNER_TEMP/state.json"
  gh_state_write "$(context .pr)" "$(cat "$RUNNER_TEMP/state.json")" 2> "$RUNNER_TEMP/state-error" \
    || stage_fail "Pull request #$(context .pr)'s description couldn't be updated ($(head -n 1 "$RUNNER_TEMP/state-error")). A person checks it."
}

# _ci_person <result> <why> <what to do>: a person takes it from here — once
# per head and result: the pull request and the ticket say why, and the
# ticket gets needs-human. Ends the run (blocked).
_ci_person() {
  local number head
  number=$(context .pr) head=$(jq -r '.head' "$RUNNER_TEMP/ci.json")
  if jq -e --arg head "$head" --arg result "$1" '.ci.head == $head and .ci.result == $result' "$RECONCILE_STATE" > /dev/null; then
    _ci_done "already reported: $2"
  fi
  _ci_record "$1"
  printf '🔎 Not handed off: %s. A person takes it from here: %s.\n' "$2" "$3" | gh_pr_comment "$number" \
    || echo "::warning::Couldn't comment on pull request #$number."
  jq -n -L "$HUB_DIR/lib" --arg number "$number" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$number" \
      --arg why "$2" --arg what "$3" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong("🔎 Not handed off"), text(" — "), link("#\($number)"; $url), text(": \($why). A person takes it from here: \($what). "),
      link("Run details"; $run)])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL" > /dev/null
  echo "::notice::Pull request #$number not handed off ($1): a person takes it from here."
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$number not handed off — $2." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome blocked
  exit 0
}

# _handoff <number> <head>: the required checks all passed on exactly <head>.
# If the pull request is eligible (handoff_problems), and still exactly so
# when re-read just before the writes, it's marked ready for review and the
# ticket moves to Ready for Review, for a person's code review.
_handoff() {
  local number=$1 head=$2 problems pr
  problems=$(handoff_problems "$head" < "$RECONCILE_STATE")
  if [ -n "$problems" ]; then
    _ci_person green "the required checks passed on $(_short "$head"), but $(paste -sd ';' - <<< "$problems" | sed 's/;/; /g')" \
      "resolve what's listed (the pull request's Items), or review it without the hub's hand-off"
  fi
  # Publication freshness: the same head, plan, approval and status, read
  # again just before anything is written.
  [ "$(gh_branch_head "$(context .branch)")" = "$head" ] \
    || stage_fail "Someone pushed to $(context .branch) while the hub was checking it, so it wasn't handed off. The next check picks up the new commits."
  stage_require_status "$PLAN_APPROVED_STATUS"
  _require_same_plan
  pr=$(gh_pr_find "$(context .branch)") && [ "$(jq -r '.number' <<< "$pr")" = "$number" ] \
    || stage_fail "Couldn't read pull request #$number from GitHub, so it wasn't handed off."

  # The record first: a hand-off that stops part-way is finished by the next
  # run (each write is safe to repeat).
  _ci_record green handed-off
  if [ "$(jq -r '.draft' <<< "$pr")" = true ]; then
    gh_pr_ready "$(jq -r '.node_id' <<< "$pr")" \
      || stage_fail "Pull request #$number couldn't be marked ready for review. Mark it ready by hand, or re-run the build."
  fi
  stage_move "$(stage_transition_id "$READY_FOR_REVIEW_STATUS")" "$READY_FOR_REVIEW_STATUS"
  printf '✅ Ready for review: every required check passed on %s, the commit the hub verified and reviewed (with any fix and merge since, verified on exactly their commits). Over to a person for the code review.\n' "$(_short "$head")" \
    | gh_pr_comment "$number" || echo "::warning::Couldn't comment on pull request #$number."
  jq -n -L "$HUB_DIR/lib" --arg number "$number" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$number" \
      --arg head "$(_short "$head")" --slurpfile state "$RUNNER_TEMP/state.json" --arg run "$RUN_URL" 'include "adf";
    ([$state[0].items[]? | select(.status == "open")] | length) as $open
    | doc([para([strong("✅ Ready for review"), text(" — "), link("#\($number)"; $url),
        text(" passed every required check on \($head) and is ready for a person'"'"'s code review"
          + (if $open > 0 then ", with \($open) open review item\(if $open == 1 then "" else "s" end) listed on it. " else ". " end)),
        link("Run details"; $run)])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL" > /dev/null
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$number handed off — ready for review, ticket in $READY_FOR_REVIEW_STATUS." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "handed off"
  exit 0
}
