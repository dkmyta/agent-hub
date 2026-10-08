# shellcheck shell=bash
# People's commands on a build's items, from the ticket (step 5;
# docs/workflows/build.md, "Review items and /apply"). The tracker's Build
# Command rule only wakes the build (wake: command) when a comment starts
# with /skip or /apply; this, the build's fetch step, reads the ticket's open
# commands itself, oldest first, and answers each one exactly once (marking
# it resolved with what was done).
#
#   /skip D1 R2 C3   close those open items — a decision (D) is accepted — no
#                    Claude; the CI gate then runs again (the CI sweep)
#   /apply …         a later version (5b-2)
#
# Rules that hold for every command:
#   - Commenting on a ticket never authorises a change: the commenter must be
#     in AGENT_HUB_APPROVERS_GROUP, read from the tracker; if that can't be
#     checked, or the group isn't set, nothing is done.
#   - Only the first paragraph is read, and it may hold only item ids:
#     anything else and the whole command is refused — this is not a way to
#     give the agent instructions. Later paragraphs are a note for people.
#   - Only items open in the pull request's current record count.
#   - Who accepted or skipped what is kept on the ticket (the private
#     agent-hub-items property), not on a public pull request.
#
# Sourced by stage.sh.

build_command() {
  local comments commands branch pr number state record before cmd
  stage_fetch "$PLAN_APPROVED_STATUS" "$READY_FOR_REVIEW_STATUS" "$APPROVED_STATUS" || exit 0
  comments=$(tracker_comments) || stage_fail "Couldn't read $TICKET_KEY's comments from $TRACKER_NAME, so no command was handled."
  printf '%s\n' "$comments" > "$RUNNER_TEMP/comments-seen.json"
  commands=$(jq -c -L "$HUB_DIR/lib" 'include "adf";
    [.comments[] | select((automation_comment | not)
      and ((.body | first_text) as $t | ($t | is_command("/skip")) or ($t | is_command("/apply"))))]
    | sort_by(.created) | .[]' <<< "$comments")
  [ -n "$commands" ] || _command_end "no change needed" "no open /skip or /apply comments"

  branch="$BUILD_BRANCH_PREFIX$TICKET_KEY"
  pr=$(gh_pr_find "$branch") || stage_fail "Couldn't read $branch's pull request from GitHub, so no command was handled."
  if [ -z "$pr" ] || [ "$(jq -r '.state' <<< "$pr")" != open ] \
     || ! jq -e --arg label "$BUILD_LABEL" 'any(.labels[]?; .name == $label)' <<< "$pr" > /dev/null; then
    _command_refuse_all "$commands" "there's no open pull request of the hub's for this ticket"
  fi
  number=$(jq -r '.number' <<< "$pr")
  if ! state=$(gh_state_read "$number" 2> "$RUNNER_TEMP/state-error"); then
    _command_refuse_all "$commands" "the hub's record in pull request #$number can't be trusted ($(head -n 1 "$RUNNER_TEMP/state-error"))"
  fi
  printf '%s\n' "$state" > "$RUNNER_TEMP/command-state.json"
  before=$state
  : > "$RUNNER_TEMP/command-log.jsonl"
  while IFS= read -r cmd; do
    _command_handle "$cmd" "$number"
  done <<< "$commands"

  state=$(cat "$RUNNER_TEMP/command-state.json")
  if [ "$state" = "$before" ]; then
    _command_end "no change needed" "$(grep -c . <<< "$commands") command(s) answered; no item changed"
  fi
  # The record (the CI gate runs again: its last result is cleared, so the
  # CI sweep wakes it), the description's items from the kept review, a
  # comment on the pull request, and who did what on the ticket.
  jq -c 'del(.ci)' <<< "$state" > "$RUNNER_TEMP/state.json"
  record=$(tracker_property agent-hub-review 2> /dev/null) || record='{}'
  if jq -e '.review.status != null' <<< "$record" > /dev/null 2>&1; then
    jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile state "$RUNNER_TEMP/state.json" --argjson rec "$record" \
      'include "wording"; status_lines($state[0]; $rec.review; $rec.fix; {governance: {manual_changes: ($rec.manual_changes // [])}}; $rec.publish; $rec.what)' \
      | sed '1{/^$/d;}' > "$RUNNER_TEMP/status.md"
    gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" "$RUNNER_TEMP/status.md" 2> "$RUNNER_TEMP/state-error"
  else
    gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" 2> "$RUNNER_TEMP/state-error"
  fi || stage_fail "Pull request #$number's description couldn't be updated ($(head -n 1 "$RUNNER_TEMP/state-error")), so the items weren't changed. A person checks it."
  jq -r -s '"🧾 Items updated by an approver on the ticket: " + ([.[] | "\(.id) \(.status)"] | join(", ")) + "."' "$RUNNER_TEMP/command-log.jsonl" \
    | gh_pr_comment "$number" || echo "::warning::Couldn't comment on pull request #$number."
  tracker_set_property agent-hub-items < <(tracker_property agent-hub-items | jq -c --slurpfile log "$RUNNER_TEMP/command-log.jsonl" '.log = ((.log // []) + $log)') \
    || echo "::warning::Couldn't keep who changed which items on $TICKET_KEY."
  _command_end revised "items changed on pull request #$number: $(jq -r -s '[.[] | "\(.id) \(.status)"] | join(", ")' "$RUNNER_TEMP/command-log.jsonl")"
}

# _command_handle <comment JSON> <number>: one command, answered.
_command_handle() {
  local cmd=$1 number=$2 id author name words verb ids item status done="" refused=""
  id=$(jq -r '.id' <<< "$cmd") author=$(jq -r '.author.accountId // ""' <<< "$cmd") name=$(jq -r '.author.displayName // "someone"' <<< "$cmd")
  # The first paragraph's words, in lower case; the first is the command.
  words=$(jq -r '.body.content[0] | [.. | .text? // empty] | join("") | ascii_downcase | gsub("^\\s+|\\s+$"; "")' <<< "$cmd")
  verb=${words%%[[:space:]]*}
  ids=$(tr -s '[:space:]' '\n' <<< "${words#"$verb"}" | grep . || true)

  if [ -z "$APPROVERS_GROUP" ]; then
    _command_reply "$id" "not done: item commands need the approvers group set (the AGENT_HUB_APPROVERS_GROUP repository variable)"; return
  fi
  if [ -z "$author" ] || ! tracker_user_groups "$author" > "$RUNNER_TEMP/command-groups" 2> /dev/null; then
    _command_reply "$id" "not done: the hub couldn't check that the commenter is in $APPROVERS_GROUP"; return
  fi
  grep -qxF -- "$APPROVERS_GROUP" "$RUNNER_TEMP/command-groups" \
    || { _command_reply "$id" "not done: only members of $APPROVERS_GROUP can change a build's items"; return; }
  if [ "$verb" = /apply ]; then
    _command_reply "$id" "not done: /apply arrives in a later version of the hub — for now, /skip closes items, and people change the pull request themselves"; return
  fi
  if [ -z "$ids" ] || grep -qvE '^[drc][0-9]+$' <<< "$ids"; then
    _command_reply "$id" "not done: /skip takes only item ids from the pull request's Items (e.g. /skip D1 R2) — nothing else on that line"; return
  fi
  for item in $(tr 'a-z' 'A-Z' <<< "$ids" | awk '!seen[$0]++'); do
    if jq -e --arg i "$item" 'any(.items[]?; .id == $i and .status == "open")' "$RUNNER_TEMP/command-state.json" > /dev/null; then
      if [ "${item:0:1}" = D ]; then status=accepted; else status=skipped; fi
      jq -c --arg i "$item" --arg status "$status" --arg comment "$id" \
        '.items |= map(if .id == $i then .status = $status | .by_command = $comment | .at = (now | todate) else . end)' \
        "$RUNNER_TEMP/command-state.json" > "$RUNNER_TEMP/command-state.new" && mv "$RUNNER_TEMP/command-state.new" "$RUNNER_TEMP/command-state.json"
      jq -nc --arg i "$item" --arg status "$status" --arg by "$author" --arg name "$name" --arg comment "$id" \
        --arg head "$(jq -r '.heads[-1].head // ""' "$RUNNER_TEMP/command-state.json")" \
        '{id: $i, status: $status, by: $by, by_name: $name, comment: $comment, head: $head, at: (now | todate)}' >> "$RUNNER_TEMP/command-log.jsonl"
      done+="${done:+, }$item $status"
    else
      refused+="${refused:+, }$item"
    fi
  done
  _command_reply "$id" "${done:-nothing changed}${refused:+; not open on pull request #$number: $refused}"
}

# _command_reply <comment id> <what>: the command is answered — marked
# resolved, saying what was done — so it's never handled twice.
_command_reply() {
  _resolve_matching "$RUNNER_TEMP/comments-seen.json" "$2" '.id == $args[0]' "$1" > /dev/null \
    || echo "::warning::Couldn't mark comment $1 as handled."
}

# _command_refuse_all <commands> <why>: every command is answered with why
# nothing was done. Ends the run.
_command_refuse_all() {
  local cmd
  while IFS= read -r cmd; do _command_reply "$(jq -r '.id' <<< "$cmd")" "not done: $2"; done <<< "$1"
  _command_end "no change needed" "$2"
}

# _command_end <outcome> <why>: the run ends here.
_command_end() {
  echo "[$TICKET_KEY]($TICKET_URL): $2." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "$1"
  exit 0
}
