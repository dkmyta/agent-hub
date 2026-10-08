# shellcheck shell=bash
# A hub pull request was closed (step 5a; docs/workflows/build.md, "Revisions
# and reverse paths"). The no-agent agent-hub-pr-closed.yml only requests the
# build for the ticket (wake: closed); this, the build's fetch step, does the
# trusted work, from GitHub and the ticket as they are now — never from the
# event. The rule:
#
#   A ticket reaches Done only from a hub pull request that the hub handed
#   off and that GitHub reports as merged.
#
#   merged, after the hub's hand-off      → Done (with a note if people
#                                           pushed after the hand-off: the
#                                           person who merged owns those)
#   merged without the hub's hand-off     → not Done: a person decides
#   closed without merging                → never Done: a comment
#
# Nothing is built and no Claude runs. Sourced by stage.sh.

build_closed() {
  local branch pr number state handed head reason
  # Where a ticket with a hub pull request can be; anywhere else (Done
  # already, or moved by a person) there's nothing to do.
  stage_fetch "$PLAN_APPROVED_STATUS" "$READY_FOR_REVIEW_STATUS" "$APPROVED_STATUS" || exit 0
  branch="$BUILD_BRANCH_PREFIX$TICKET_KEY"
  pr=$(gh_pr_find "$branch") || stage_fail "Couldn't read $branch's pull request from GitHub, so the ticket wasn't changed."
  if [ -z "$pr" ] || ! jq -e --arg label "$BUILD_LABEL" 'any(.labels[]?; .name == $label)' <<< "$pr" > /dev/null; then
    _closed_end "no change needed" "$branch has no pull request of the hub's"
  fi
  number=$(jq -r '.number' <<< "$pr")
  [ "$(jq -r '.state' <<< "$pr")" = closed ] || _closed_end "no change needed" "pull request #$number is open again"

  if [ "$(jq -r '.merged_at != null' <<< "$pr")" != true ]; then
    _closed_person "$number" "🔒 Pull request closed" \
      "#$number was closed without merging, so the ticket stays in $(stage_start_status). To build the plan again, delete $branch and approve the plan again; to drop it, move the ticket out of the pipeline." \
      "closed without merging"
  fi

  # Merged: the hub's record, only if every edit to it was the hub's, and its
  # hand-off.
  head=$(jq -r '.head.sha' <<< "$pr")
  if state=$(gh_state_read "$number" 2> "$RUNNER_TEMP/state-error"); then
    handed=$(jq -r '.handoff.head // empty' <<< "$state")
    reason="the hub never handed it off (its required checks and items weren't all clear)"
  else
    handed="" reason="the hub's record in it can't be trusted ($(head -n 1 "$RUNNER_TEMP/state-error"))"
  fi
  if [ -z "$handed" ]; then
    _closed_person "$number" "🔎 Merged without the hub's hand-off" \
      "#$number was merged, but $reason, so the hub hasn't moved the ticket to $DONE_STATUS. A person checks the merge and moves it." \
      "merged without the hub's hand-off"
  fi

  stage_move "$(stage_transition_id "$DONE_STATUS")" "$DONE_STATUS"
  tracker_labels "-$NEEDS_HUMAN_LABEL" > /dev/null
  jq -n -L "$HUB_DIR/lib" --arg number "$number" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$number" \
      --arg merge "$(jq -r '.merge_commit_sha // "" | .[0:7]' <<< "$pr")" --arg head "${head:0:7}" --arg handed "${handed:0:7}" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong("✅ Done"), text(" — "), link("#\($number)"; $url),
      text(" was merged\(if $merge != "" then " (\($merge))" else "" end)"
        + (if $head == $handed then ", at the head the hub handed off. "
           else ", with commits pushed after the hub handed off \($handed) — the person who merged it owns those. " end)),
      link("Run details"; $run)])])' | tracker_comment > /dev/null
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$number merged — ticket moved to $DONE_STATUS." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome "done"
}

# _closed_person <number> <title> <text> <summary>: the ticket isn't moved;
# a comment says why, and needs-human. Ends the run.
_closed_person() {
  jq -n -L "$HUB_DIR/lib" --arg title "$2" --arg text "$3" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong($title), text(" — \($text) "), link("Run details"; $run)])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL" > /dev/null
  echo "::notice::Pull request #$1 $4: the ticket stays where it is."
  _closed_end blocked "pull request #$1 $4; the ticket stays in $(stage_start_status)"
}

# _closed_end <outcome> <why>: the run ends here.
_closed_end() {
  echo "[$TICKET_KEY]($TICKET_URL): $2." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "$1"
  exit 0
}
