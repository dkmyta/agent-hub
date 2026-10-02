# shellcheck shell=bash
# The work-order stage: turns an intake ticket into a work order a developer
# can start technical planning from, or sends it back for more detail. Its
# steps, run by the shared stage workflow (.github/workflows/agent-hub-stage.yml)
# with the settings, tracker and shared libraries already loaded.
#
# The tracker dispatches `agent-hub-work-order-requested` with only the ticket key;
# everything else is read from the ticket. The agent reads the ticket and the
# repository read-only and returns structured output; these steps apply it.
# When the ticket already has a work order (a "/revise" comment, or a work
# order edited and resubmitted from Intake), the agent revises it with the
# change requests instead of starting over. See docs/workflows/work-order.md.

# step_fetch: Fetch the ticket, decide new or revision, and post the progress comment.
step_fetch() {
  stage_fetch "$WORK_ORDER_STATUS" || exit 0
  # A description that's already a work order (it has any of the work
  # order's group headings — one removed by hand doesn't change that)
  # is revised rather than replaced.
  if jq -e -L "$HUB_DIR/lib" 'include "adf";
       .fields.description // {content: []} | . as $d
       | any("Overview", "Scope", "Developer Notes", "Risk & Open Questions", "Delivery"; . as $title | $d | section_index($title) != null)' \
       "$RUNNER_TEMP/ticket.json" > /dev/null; then
    MODE=revision
  else
    MODE=new
  fi
  stage_set_mode "$MODE"
  # Comments hold extra details and change requests.
  stage_ticket_markdown --with-comments
  # Shows people on the ticket that a run is going; cleared when it
  # ends, or turned into the failure notice.
  if [ "$MODE" = revision ]; then
    stage_progress_comment "⏳ Revising work order" \
      " — usually takes 1–3 minutes. Refresh the page to see the result. "
  else
    stage_progress_comment "⏳ Generating work order" \
      " — usually takes 1–2 minutes. Refresh the page to see the result. "
  fi
}

# step_agent: The agent: draft, check, expert review, check, and this stage's own checks.
step_agent() {
  MODE=$(stage_mode)
  if [ "$MODE" = revision ]; then
    agent_run "Revise the work order in this ticket's description, addressing the change requests in its comments." work_order
  else
    agent_run "Prepare the work order for this ticket." work_order
  fi
  agent_check work_order needs-details missing
  agent_review "Review this work order draft and return the final version."
  agent_check work_order needs-details missing
  agent_summary "Work order"
}

# step_apply: Write the result to the ticket.
step_apply() {
  tracker_require_status "$WORK_ORDER_STATUS" || exit 0
  MODE=$(stage_mode)

  # The reviewed work order, with the review's note at the top. A
  # revision changes only its updated sections of the current
  # description (read fresh, so people's edits — even during the run —
  # are kept), and replaces the previous review note.
  if [ "$MODE" = revision ]; then
    source "$STAGE_DIR/revise.sh"
    jq '.structured_output.updates' "$RUNNER_TEMP/agent-output.json" > "$RUNNER_TEMP/updates.json"
    tracker_issue description | jq '.fields.description' > "$RUNNER_TEMP/current-description.json"
    # A section the revision changes may have been removed by hand: say
    # which, before changing anything, rather than guess where it goes.
    MISSING_SECTIONS=$(revision_missing_sections "$RUNNER_TEMP/updates.json" < "$RUNNER_TEMP/current-description.json")
    if [ -n "$MISSING_SECTIONS" ]; then
      stage_fail "The revision changes sections this work order no longer has: $MISSING_SECTIONS. Nothing was changed. Put the heading(s) back in the description (same name and heading level as the other sections), then comment $REVISE_COMMAND again."
    fi
    revision_description "$RUNNER_TEMP/updates.json" < "$RUNNER_TEMP/current-description.json"
  else
    jq '.structured_output.work_order' "$RUNNER_TEMP/agent-output.json" \
      | jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq"
  fi | jq -L "$HUB_DIR/lib" --slurpfile review "$RUNNER_TEMP/review.json" 'include "adf";
        .content = [para([em("Expert review: \($review[0].note)")])]
          + (.content | if (.[0].type == "paragraph" and (.[0] | plain_text | startswith("Expert review:"))) then .[1:] else . end)' \
    > "$RUNNER_TEMP/description.json"
  tracker_comments > "$RUNNER_TEMP/comments.json"

  # A revised work order supersedes any plan written for the previous
  # version: say so where its summary was (the plan stage replaces the
  # attachment when the work order is approved again).
  PLAN_FILE="$TICKET_KEY-$PLAN_FILE_SUFFIX"
  if [ "$MODE" = revision ] \
     && tracker_attachments | jq -e --arg name "$PLAN_FILE" 'any(.[]; .filename == $name)' > /dev/null; then
    # shellcheck disable=SC1112 # curly apostrophe intended
    jq -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" --arg file "$PLAN_FILE" 'include "adf";
      if section_index($section) == null then . else
      replace_section($section; [para([text("The attached plan ("), code($file),
        text(") was written for an earlier version of this work order and is out of date. It’s replaced when the work order is approved again, by a new plan written from this work order — changes made to the old plan (by hand or with /revise) don’t carry over.")])]) end' \
      "$RUNNER_TEMP/description.json" > "$RUNNER_TEMP/description.new" && mv "$RUNNER_TEMP/description.new" "$RUNNER_TEMP/description.json"
  fi

  # A new work order keeps the original request as a comment before
  # overwriting it — read fresh so formatting survives and edits made
  # during the run are captured; if the comment fails, nothing is
  # overwritten. Not when revising (the description is a work order,
  # and the request was captured the first time), nor if this exact
  # request was already captured (a retry after a failed update).
  if [ "$MODE" = new ]; then
    tracker_issue description > "$RUNNER_TEMP/original-request.json"
    ALREADY_CAPTURED=$(jq -L "$HUB_DIR/lib" --arg note "$ORIGINAL_REQUEST_NOTE" \
      --slurpfile issue "$RUNNER_TEMP/original-request.json" 'include "adf";
      ($issue[0].fields.description | to_markdown) as $current
      | [.comments[].body | select([.. | objects | select(.type == "text") | .text] | last == $note)
         | {content: .content[:-2]} | to_markdown] | any(. == $current)' "$RUNNER_TEMP/comments.json")
    if [ "$ALREADY_CAPTURED" = true ]; then
      echo "::notice::Original request already captured on $TICKET_KEY — not posting it again."
    elif jq -e '.fields.description.content | length > 0' "$RUNNER_TEMP/original-request.json" > /dev/null; then
      jq -L "$HUB_DIR/lib" --arg note "$ORIGINAL_REQUEST_NOTE" 'include "adf";
        doc(.fields.description.content + [divider, para([em($note)])])' \
        "$RUNNER_TEMP/original-request.json" | tracker_comment > /dev/null
    fi
  fi

  tracker_set_description < "$RUNNER_TEMP/description.json"
  # Waiting for a person to review and approve the work order.
  tracker_add_label "$NEEDS_HUMAN_LABEL"

  # Say how each change request was handled, then mark them and earlier
  # needs-details comments (from the tracker's intake check or Claude) as resolved.
  stage_revision_reply "work order"
  RESOLVED=$(stage_resolve_comments "$RUNNER_TEMP/comments.json" \
    "details were added and the work order was generated." "$NEEDS_DETAILS_TITLE")
  REVISIONS=$(stage_resolve_revisions "$RUNNER_TEMP/comments.json")
  # The plan stage's open questions are now answered: no longer waiting
  # on a decision, only on approval.
  if jq -e '.structured_output.clarification_settled == true' "$RUNNER_TEMP/agent-output.json" > /dev/null; then
    tracker_remove_label "$NEEDS_CLARIFICATION_LABEL"
    stage_resolve_comments "$RUNNER_TEMP/comments.json" \
      "settled in the work order; approve it to write the plan." "$NEEDS_CLARIFICATION_TITLE" > /dev/null
  fi

  echo "Work order $([ "$MODE" = revision ] && echo revised || echo written) on [$TICKET_KEY]($TICKET_URL); resolved $RESOLVED needs-details comment(s) and $REVISIONS change request(s)." >> "$GITHUB_STEP_SUMMARY"
}

# step_return: Send the ticket back: the result says it can't go ahead yet.
step_return() {
  tracker_require_status "$WORK_ORDER_STATUS" || exit 0
  # Before changing anything, so a misconfigured tracker workflow can't
  # leave a half-processed ticket.
  TRANSITION_ID=$(stage_transition_id "$INTAKE_STATUS")

  # Same standard message as the tracker's no-details comment, plus
  # the source and Claude's specifics. (Curly apostrophes intended.)
  # shellcheck disable=SC1112
  jq -L "$HUB_DIR/lib" --arg title "$NEEDS_DETAILS_TITLE" --arg message "$NEEDS_DETAILS_MESSAGE" 'include "adf";
    doc([para([strong($title), text(" — flagged by Claude (work order review).")]),
         para($message),
         para([strong("What’s missing: "), text(.structured_output.missing)])])' \
    "$RUNNER_TEMP/agent-output.json" | tracker_comment > /dev/null
  tracker_add_label "$NEEDS_DETAILS_LABEL"
  # Waiting on the requester now, not a reviewer (set when revising).
  tracker_remove_label "$NEEDS_HUMAN_LABEL"
  tracker_transition "$TRANSITION_ID"

  echo "[$TICKET_KEY]($TICKET_URL) returned to $INTAKE_STATUS as $NEEDS_DETAILS_LABEL." >> "$GITHUB_STEP_SUMMARY"
}
