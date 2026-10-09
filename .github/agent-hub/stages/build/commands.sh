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
#   /apply R2 D1     fix those open items (a decision only by its id), through
#   /apply all       the fix pass's path; all is every open R item, never a D
#   /apply comments  the pull request's unresolved review threads from people
#                    with write access (asked of GitHub for each commenter), as
#                    read now (combinable: /apply R2
#                    comments). The run becomes a fix of exactly those, as a
#                    review's fix pass: the fix check, the Verify-fix gate, a
#                    push never forced; then CI and the hand-off gate again on
#                    the new commit (a handed-off pull request goes back to
#                    draft). Only on the head the hub last recorded and
#                    reviewed — after anyone else's push, a person re-runs the
#                    build first. One /apply per run; a later command waits
#                    for the next.
#
# Rules that hold for every command:
#   - Commenting on a ticket never authorises a change: the commenter must be
#     in AGENT_HUB_APPROVERS_GROUP, read from the tracker; if that can't be
#     checked, or the group isn't set, nothing is done. And the comment must
#     be the commenter's own words: one someone else edited (Jira's "Edit All
#     Comments") is refused — its author never wrote the command.
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
  # Kept apart too: the rest of an /apply's fetch step reads the ticket again.
  cp "$RUNNER_TEMP/comments-seen.json" "$RUNNER_TEMP/command-comments.json"
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
  rm -f "$RUNNER_TEMP/apply-request.json"
  while IFS= read -r cmd; do
    # One /apply per run: the commands after it wait for the next run (each
    # comment wakes one).
    [ ! -s "$RUNNER_TEMP/apply-request.json" ] || break
    _command_handle "$cmd" "$number" "$pr"
  done <<< "$commands"

  state=$(cat "$RUNNER_TEMP/command-state.json")
  if [ "$state" = "$before" ]; then
    # An accepted /apply: the run carries on (step_fetch) as its fix.
    [ ! -s "$RUNNER_TEMP/apply-request.json" ] || return 0
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
  [ ! -s "$RUNNER_TEMP/apply-request.json" ] || return 0
  _command_end revised "items changed on pull request #$number: $(jq -r -s '[.[] | "\(.id) \(.status)"] | join(", ")' "$RUNNER_TEMP/command-log.jsonl")"
}

# _command_handle <comment JSON> <number> <pull request JSON>: one command,
# answered — or, for an /apply that's accepted, made the run's request
# (apply-request.json), answered when its fix is applied.
_command_handle() {
  local cmd=$1 number=$2 pr=$3 id author name words verb ids item status done="" refused=""
  id=$(jq -r '.id' <<< "$cmd") author=$(jq -r '.author.accountId // ""' <<< "$cmd") name=$(jq -r '.author.displayName // "someone"' <<< "$cmd")
  # The first paragraph's words, in lower case; the first is the command.
  words=$(jq -r '.body.content[0] | [.. | .text? // empty] | join("") | ascii_downcase | gsub("^\\s+|\\s+$"; "")' <<< "$cmd")
  verb=${words%%[[:space:]]*}
  ids=$(tr -s '[:space:]' '\n' <<< "${words#"$verb"}" | grep . || true)

  if [ "$(jq -r '.updateAuthor.accountId // .author.accountId // ""' <<< "$cmd")" != "$author" ]; then
    _command_reply "$id" "not done: the comment was edited by someone other than its author, so it isn't their command — they post it again themselves"; return
  fi
  if [ -z "$APPROVERS_GROUP" ]; then
    _command_reply "$id" "not done: item commands need the approvers group set (the AGENT_HUB_APPROVERS_GROUP repository variable)"; return
  fi
  if [ -z "$author" ] || ! tracker_user_groups "$author" > "$RUNNER_TEMP/command-groups" 2> /dev/null; then
    _command_reply "$id" "not done: the hub couldn't check that the commenter is in $APPROVERS_GROUP"; return
  fi
  grep -qxF -- "$APPROVERS_GROUP" "$RUNNER_TEMP/command-groups" \
    || { _command_reply "$id" "not done: only members of $APPROVERS_GROUP can change a build's items"; return; }
  if [ "$verb" = /apply ]; then
    _apply_request "$cmd" "$number" "$pr" "$ids"; return
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

# _apply_request <comment JSON> <number> <pull request JSON> <words>: an
# /apply from an approver, checked; if anything is left to apply, the run's
# request (apply-request.json) and the fix pass's findings
# (apply-findings.json), numbered 1…, each from exactly one item or thread.
_apply_request() {
  local cmd=$1 number=$2 pr=$3 words=$4 id head record threads login refused="" n=0 item finding
  id=$(jq -r '.id' <<< "$cmd")
  if [ -z "$words" ] || grep -qvE '^([drc][0-9]+|all|comments)$' <<< "$words"; then
    _command_reply "$id" "not done: /apply takes only item ids from the pull request's Items, all (every open R item) or comments (its unresolved review threads) — nothing else on that line"; return
  fi
  # Only on the head the hub last recorded, and with the findings it kept for
  # the current review.
  head=$(gh_branch_head "$BUILD_BRANCH_PREFIX$TICKET_KEY") || { _command_reply "$id" "not done: the hub couldn't read the branch from GitHub"; return; }
  if [ "$head" != "$(jq -r '.heads[-1].head // ""' "$RUNNER_TEMP/command-state.json")" ]; then
    _command_reply "$id" "not done: pull request #$number has commits the hub hasn't checked — re-run the build to have them verified and reviewed, then /apply what that review lists"; return
  fi
  record=$(tracker_property agent-hub-review 2> /dev/null) || record='{}'
  : > "$RUNNER_TEMP/apply-findings.jsonl"
  : > "$RUNNER_TEMP/apply-sources.jsonl"
  # The items: open in the current record, by id (a decision only that way)
  # or as all (every open R item).
  for item in $(jq -r --argjson words "$(jq -R . <<< "$words" | jq -sc .)" -s '.[0] as $s
      | ($words | map(ascii_upcase)) as $w
      | ([$w[] | select(test("^[DRC][0-9]+$"))] + (if any($w[]; . == "ALL") then [$s.items[]? | select(.status == "open" and (.id | startswith("R"))) | .id] else [] end))
      | unique[]' "$RUNNER_TEMP/command-state.json"); do
    finding=$(jq -c --arg i "$item" --argjson rec "$record" '
      ([.items[]? | select(.id == $i and .status == "open")] | first) as $it
      | if $it == null then {refuse: "not open"}
        elif ($i | startswith("C")) then {refuse: "a manual change, for a person"}
        elif $it.source == "review" then
          if $rec.review.head != .review.head then {refuse: "the hub has no record of its finding"}
          else ([$rec.review.findings[]? | select(.n == $it.finding)] | first) // {refuse: "the hub has no record of its finding"} end
        elif $it.source == "fix-check" then
          ([$rec.fix.new_concerns[]? | select(.n == $it.concern)] | first) // {refuse: "the hub has no record of its finding"}
        elif ($it.source // "gate") == "gate" and ($it.path // "") != "" then
          {title: "\($it.path): \($it.reason)", file: $it.path, line: null, severity: "medium", kind: "scope", area: "scope",
           evidence: "The hub'"'"'s gates flagged this change to \($it.path): \($it.reason).",
           suggestion: "Bring this change within the approved plan: undo it, or change it as the plan allows."}
        else {refuse: "it can'"'"'t be applied — resolve it by hand, or /skip it"} end' "$RUNNER_TEMP/command-state.json")
    if jq -e '.refuse' <<< "$finding" > /dev/null; then
      refused+="${refused:+, }$item ($(jq -r '.refuse' <<< "$finding"))"; continue
    fi
    n=$((n + 1))
    jq -c --argjson n "$n" '{n: $n, area, severity, kind, within_plan: true, file: (.file // ""), line, title, evidence, suggestion: (.suggestion // ""), policy: "fix"}' <<< "$finding" >> "$RUNNER_TEMP/apply-findings.jsonl"
    jq -nc --argjson n "$n" --arg i "$item" '{n: $n, item: $i}' >> "$RUNNER_TEMP/apply-sources.jsonl"
  done
  # The review threads: unresolved, from people with write access, as read
  # now — the snapshot the fix is attributed to.
  if grep -qx comments <<< "$words"; then
    local writers="[]" who
    login=$(gh_login) && threads=$(gh_graphql 'query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes {
          id isResolved path line comments(first: 30) { nodes { databaseId body authorAssociation author { login } } } } } } } }' \
        "$(jq -nc --arg o "$GH_OWNER" --arg n "$GH_NAME" --argjson num "$number" '{owner: $o, name: $n, number: $num}')") \
      || { _command_reply "$id" "not done: the hub couldn't read the pull request's review threads"; rm -f "$RUNNER_TEMP/apply-findings.jsonl"; return; }
    # Who may ask for changes: write access, as GitHub says for each one.
    for who in $(jq -r --arg me "$login" '[.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
        | .comments.nodes[].author.login // empty | select(. != $me and (endswith("[bot]") | not))] | unique[]' <<< "$threads"); do
      if gh_user_can_write "$who"; then writers=$(jq -c --arg w "$who" '. + [$w]' <<< "$writers"); fi
    done
    while IFS= read -r thread; do
      n=$((n + 1))
      jq -c --argjson n "$n" '{n: $n, area: "review", severity: "medium", kind: "review-comment", within_plan: true,
        file: (.path // ""), line, policy: "fix",
        title: "A reviewer'"'"'s comment on \(.path // "the pull request")\(if .line then ":\(.line)" else "" end)",
        evidence: ([.people[] | .body[0:1500]] | join("\n\n---\n\n"))[0:4000],
        suggestion: "Make the change the reviewer asks for, if it is within the approved plan; otherwise leave it and say why."}' <<< "$thread" >> "$RUNNER_TEMP/apply-findings.jsonl"
      # Replies go to the thread's first comment: GitHub takes no reply to a reply.
      jq -c --argjson n "$n" '{n: $n, thread: .id, reply_to: .root}' <<< "$thread" >> "$RUNNER_TEMP/apply-sources.jsonl"
    done < <(jq -c --argjson writers "$writers" '.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
      | . + {people: [.comments.nodes[] | select(.author.login != null and (.author.login | IN($writers[])))],
             root: .comments.nodes[0].databaseId}
      | select((.people | length) > 0) | del(.comments)' <<< "$threads")
  fi
  if [ "$n" = 0 ]; then
    _command_reply "$id" "nothing to apply${refused:+: $refused}"; return
  fi
  jq -s -c . "$RUNNER_TEMP/apply-findings.jsonl" > "$RUNNER_TEMP/apply-findings.json"
  jq -n -c --slurpfile sources "$RUNNER_TEMP/apply-sources.jsonl" --argjson c "$cmd" --arg head "$head" --arg refused "$refused" \
    '{comment: $c.id, by: ($c.author.accountId // ""), by_name: ($c.author.displayName // ""), head: $head, sources: $sources, refused: $refused}' \
    > "$RUNNER_TEMP/apply-request.json"
  echo "/apply accepted: $n item(s) and thread(s) to fix on ${head:0:7}${refused:+; not applied: $refused}."
}

# applying: whether this run fixes an /apply's items (_apply_start).
applying() { jq -e '.apply != null' "$BUILD_CONTEXT" > /dev/null 2>&1; }

# _apply_start <number> <head> <base>: in the fetch step (_reconcile_start),
# the run becomes the fix of an accepted /apply — the pull request's head
# checked out, and the build context saying what's requested.
_apply_start() {
  git checkout -q --detach "$2" || stage_fail "Couldn't check out pull request #$1's head, so nothing was changed."
  jq --argjson number "$1" --arg head "$2" --arg base "$3" --slurpfile req "$RUNNER_TEMP/apply-request.json" \
    '. + {mode: "reconcile", pr: $number, start_head: $head, previous_head: $head, base: $base, target_head: .base,
          people_commits: 0, sync: null, apply: $req[0]}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
  echo "Pull request #$1: applying $(jq '.sources | length' "$RUNNER_TEMP/apply-request.json") requested item(s) on ${2:0:7}."
}

# apply_fix_apply: Apply for an /apply's fix (reconcile_apply). A fix Verify
# fix kept is pushed without force, as the hub's (kind fix, verified on
# exactly its commit, with the /apply it answers); each requested item whose
# fix the fix check found resolved is closed as fixed; each review thread
# gets a reply — the commit, or that it wasn't applied (Claude's words only
# go to the ticket) — and is resolved when applied. A handed-off pull
# request goes back to draft until every required check passes on the new
# commit. The /apply is answered on the ticket with each item's result.
apply_fix_apply() {
  local branch target number start status after pr kept=false
  stage_require_status "$(stage_start_status)"
  build_git
  _require_same_plan
  branch=$(context .branch) target=$(context .target) number=$(context .pr) start=$(context .start_head)
  [ -s "$RUNNER_TEMP/agent-access.json" ] || echo '{}' > "$RUNNER_TEMP/agent-access.json"
  _settle_fix
  status=$(jq -r '.status' "$FIX_RESULT")
  after=$start
  if [ "$status" = kept ]; then
    after=$(git rev-parse HEAD)
    [ "$after" = "$(jq -r '.head' "$RUNNER_TEMP/verify.json" 2> /dev/null)" ] && [ "$after" = "$(jq -r '.after' "$FIX_RESULT")" ] \
      || stage_fail "The fix's commit isn't the one the checks passed on, so nothing was pushed."
    _reconcile_push "$branch" "$target" "$number"
    kept=true
  fi
  # Each source's result: applied (kept, and the fix check found it
  # resolved) or not, with what the fix pass said.
  jq -n --slurpfile fix "$FIX_RESULT" --argjson kept "$kept" --argjson req "$(context '.apply')" '
    [$req.sources[] | .n as $n
     | . + {applied: ($kept and any($fix[0].checks[]?; .finding == $n and .verdict == "resolved")),
            what: ((first($fix[0].fixes[]? | select(.finding == $n)) | .what) // ($fix[0].reason // "not attempted"))}]' \
    > "$RUNNER_TEMP/apply-results.json"
  jq -c --slurpfile results "$RUNNER_TEMP/apply-results.json" --arg version "$(cat "$HUB_DIR/VERSION")" \
      --arg after "$after" --argjson kept "$kept" --argjson req "$(context '.apply')" '
    (.generation + 1) as $g | (now | todate) as $at
    | . + {generation: $g, hub_version: $version}
    | if $kept then
        .heads += [{generation: $g, head: $after, hub_version: $version, by: "hub", kind: "fix",
                    verified: {head: $after, by: "verify-fix"}, applied: {comment: $req.comment}, at: $at}]
        | del(.ci) | del(.handoff)
      else . end
    | ([$results[0][] | select(.applied and .item) | .item]) as $fixed
    | .items |= map(if (.id | IN($fixed[])) then .status = "fixed" | .by_command = $req.comment | .at = $at else . end)' \
    "$RECONCILE_STATE" > "$RUNNER_TEMP/state.json"
  local record
  record=$(tracker_property agent-hub-review 2> /dev/null) || record='{}'
  if jq -e '.review.status != null' <<< "$record" > /dev/null 2>&1; then
    jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile state "$RUNNER_TEMP/state.json" --argjson rec "$record" \
      'include "wording"; status_lines($state[0]; $rec.review; $rec.fix; {governance: {manual_changes: ($rec.manual_changes // [])}}; $rec.publish; $rec.what)' \
      | sed '1{/^$/d;}' > "$RUNNER_TEMP/status.md"
    gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" "$RUNNER_TEMP/status.md" 2> "$RUNNER_TEMP/state-error"
  else
    gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" 2> "$RUNNER_TEMP/state-error"
  fi || stage_fail "Pull request #$number's description couldn't be updated ($(head -n 1 "$RUNNER_TEMP/state-error"))$([ "$kept" = false ] || echo ", though the fix was pushed"). A person checks it."

  # The review threads: a reply each, resolved when applied — hub facts only.
  local thread
  while IFS= read -r thread; do
    if [ "$(jq -r '.applied' <<< "$thread")" = true ]; then
      printf '✅ Applied by the agent hub in %s, and checked. CI and the hand-off run again on it.\n' "${after:0:7}" \
        | gh_thread_reply "$number" "$(jq -r '.reply_to' <<< "$thread")" || echo "::warning::Couldn't reply on a review thread."
      gh_thread_resolve "$(jq -r '.thread' <<< "$thread")" || echo "::warning::Couldn't resolve a review thread."
    else
      printf 'Not applied by the agent hub (an /apply on the ticket asked for it); the reason is on the ticket.\n' \
        | gh_thread_reply "$number" "$(jq -r '.reply_to' <<< "$thread")" || echo "::warning::Couldn't reply on a review thread."
    fi
  done < <(jq -c '.[] | select(.thread)' "$RUNNER_TEMP/apply-results.json")

  # Back to draft, so it isn't merged on the old result.
  pr=$(gh_pr_find "$branch") || pr=""
  if [ "$kept" = true ] && [ "$(jq -r 'if .draft == false then "ready" else "draft" end' <<< "${pr:-"{}"}")" = ready ]; then
    gh_pr_draft "$(jq -r '.node_id' <<< "$pr")" || echo "::warning::Couldn't turn pull request #$number back into a draft."
  fi
  if [ "$kept" = true ]; then
    printf '🔁 Applied by the agent hub (an /apply by an approver on the ticket): %s, in %s — verified, and checked by a fresh read-only session. It'"'"'s a draft until every required check passes on the new commit; then it'"'"'s handed off again.\n' \
      "$(jq -r '[.[] | select(.applied) | (.item // "a review thread")] | join(", ")' "$RUNNER_TEMP/apply-results.json")" "${after:0:7}"
  else
    printf 'An /apply on the ticket was tried, but its changes weren'"'"'t kept (%s), so nothing changed.\n' "$(jq -r '.reason // "it did not finish"' "$FIX_RESULT")"
  fi | gh_pr_comment "$number" || echo "::warning::Couldn't comment on pull request #$number."

  # The /apply, answered on the ticket, item by item (with what the fix pass
  # said: the ticket is private), and who asked kept there too — only ever
  # the comment as the hub read it.
  cp "$RUNNER_TEMP/command-comments.json" "$RUNNER_TEMP/comments-seen.json"
  _command_reply "$(context .apply.comment)" "$(jq -r --argjson kept "$kept" --arg after "${after:0:7}" --argjson req "$(context '.apply')" '
    (if $kept then "applied in \($after): " else "nothing applied: " end)
    + ([.[] | "\(.item // "a review thread") \(if .applied then "fixed" else "not fixed" end) — \(.what)"] | join("; "))
    + (if $req.refused != "" then "; not applied: \($req.refused)" else "" end)' "$RUNNER_TEMP/apply-results.json")"
  tracker_set_property agent-hub-items < <(tracker_property agent-hub-items | jq -c --argjson req "$(context '.apply')" \
      --slurpfile results "$RUNNER_TEMP/apply-results.json" --arg after "$after" --argjson kept "$kept" \
      '.log = ((.log // []) + [{apply: $req.comment, by: $req.by, by_name: $req.by_name, head: $req.head,
         after: (if $kept then $after else null end), results: [$results[0][] | {item, thread, applied}], at: (now | todate)}])') \
    || echo "::warning::Couldn't keep who applied what on $TICKET_KEY."
  echo "[$TICKET_KEY]($TICKET_URL): /apply on pull request #$number — $(jq '[.[] | select(.applied)] | length' "$RUNNER_TEMP/apply-results.json") of $(jq length "$RUNNER_TEMP/apply-results.json") applied." >> "$GITHUB_STEP_SUMMARY"
  if [ "$kept" = true ]; then stage_outcome revised; else stage_outcome "no change needed"; fi
}
