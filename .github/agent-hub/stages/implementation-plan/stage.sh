# shellcheck shell=bash
# The implementation-plan stage: turns an approved work order into a plan
# detailed enough for someone new to the task, or sends the ticket back to
# Work Order with product or scope questions. Its steps, run by the shared
# stage workflow (.github/workflows/agent-hub-stage.yml) with the settings,
# tracker and shared libraries already loaded.
#
# Thorough plans outgrow the tracker's field limit, so the full plan is attached as
# Markdown and a summary goes in the work order's Implementation Plan section.
# A "/revise" on a ticket in Implementation Plan revises the attached plan
# instead of starting over, and the ticket stays there. See
# docs/workflows/implementation-plan.md.

# step_fetch: Fetch the ticket, decide new or revision, and post the progress comment.
step_fetch() {
  # Work Order Approved: a new plan (or a fresh re-plan). Implementation
  # Plan: a revision of the attached plan.
  stage_fetch "$WORK_ORDER_APPROVED_STATUS" "$PLAN_STATUS" || exit 0

  # The ticket must carry a work order: its acceptance criteria (which
  # the plan must cover) and the section the plan goes into. Checked
  # before Claude runs, so no Claude usage is spent on a ticket without one.
  jq -L "$HUB_DIR/lib" 'include "adf";
    [.fields.description // {content: []} | section_blocks("Acceptance Criteria")[]
     | select(.type == "taskList") | .content[] | plain_text]' \
    "$RUNNER_TEMP/ticket.json" > "$RUNNER_TEMP/acceptance-criteria.json"
  if [ "$(jq length "$RUNNER_TEMP/acceptance-criteria.json")" = 0 ] \
    || ! jq -e -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" 'include "adf";
         .fields.description // {content: []} | section_index($section) != null' \
         "$RUNNER_TEMP/ticket.json" > /dev/null; then
    stage_fail "There's no work order to plan from: the description needs its Acceptance Criteria checklist and an \"$PLAN_SECTION\" section. Generate the work order first, or restore those sections, then move the ticket to Work Order Approved again."
  fi

  stage_ticket_markdown --with-comments

  # Revising: Claude starts from the attached plan (the description only
  # has its summary). Without one (e.g. deleted), write a new plan.
  MODE=new
  if [ "$(stage_start_status)" = "$PLAN_STATUS" ]; then
    # The newest one, and who uploaded it when — said in the version
    # line and the 🔁 reply, so a revision of a stale upload is visible.
    tracker_attachments | jq --arg name "$TICKET_KEY-$PLAN_FILE_SUFFIX" \
      '[.[] | select(.filename == $name)] | sort_by(.created) | last // {}' > "$RUNNER_TEMP/current-plan-attachment.json"
    PLAN_ID=$(jq -r '.id // empty' "$RUNNER_TEMP/current-plan-attachment.json")
    if [ -n "$PLAN_ID" ]; then
      # The attached file is the plan's source of truth: people may have
      # edited and re-uploaded it (the newest one wins).
      tracker_attachment_content "$PLAN_ID" > "$RUNNER_TEMP/current-plan.md"
      {
        printf '\nCurrent implementation plan (attached as %s):\n\n' "$TICKET_KEY-$PLAN_FILE_SUFFIX"
        cat "$RUNNER_TEMP/current-plan.md"
      } >> "$RUNNER_TEMP/ticket.md"
      MODE=revision
    else
      echo "::notice::No attached plan to revise on $TICKET_KEY — writing a new one."
    fi
  fi
  stage_set_mode "$MODE"

  if [ "$MODE" = revision ]; then
    stage_progress_comment "⏳ Revising implementation plan" \
      " — usually takes 5–10 minutes. Refresh the page to see the result. "
  else
    stage_progress_comment "⏳ Writing implementation plan" \
      " — usually takes 5–10 minutes. Refresh the page to see the result. "
  fi
}

# step_agent: The agent: draft, check, expert review, check, and this stage's own checks.
step_agent() {
  MODE=$(stage_mode)
  if [ "$MODE" = revision ]; then
    agent_run "Revise the current implementation plan for this ticket, addressing the change requests in its comments." plan
  else
    agent_run "Write the implementation plan for this ticket." plan
  fi
  agent_check plan needs-clarification questions
  agent_review "Review this implementation plan draft and return the final version."
  agent_check plan needs-clarification questions

  # A ready plan must cover every acceptance criterion, word for word,
  # and only modify or delete files that exist — checked on the reviewed
  # plan (for a revision, on the sections it changes; the rest was
  # checked before). The log names positions and paths, never ticket text.
  if [ "$(jq -r '.structured_output.status' "$AGENT_OUTPUT")" = ready ]; then
    jq '.structured_output.plan // .structured_output.updates' "$AGENT_OUTPUT" > "$RUNNER_TEMP/plan-checked.json"
    MISSING=$(jq -r --slurpfile plan "$RUNNER_TEMP/plan-checked.json" '
      def norm: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
      if $plan[0] | has("acceptance_criteria") | not then ""
      else [$plan[0].acceptance_criteria[].criterion | norm] as $covered
      | [to_entries[] | select((.value | norm) as $c | $covered | any(. == $c) | not) | .key + 1]
      | join(", ") end' "$RUNNER_TEMP/acceptance-criteria.json")
    if [ -n "$MISSING" ]; then
      stage_fail "The plan didn't cover acceptance criteria $MISSING (by position in the work order), so it wasn't applied. Comment $REVISE_COMMAND to try again."
    fi
    MISSING_FILES=$(jq -r '(.changes // [])[] | select(.action != "add") | .path' "$RUNNER_TEMP/plan-checked.json" \
      | while read -r FILE; do [ -e "${FILE#./}" ] || echo "$FILE"; done)
    if [ -n "$MISSING_FILES" ]; then
      # The paths come from Claude, so they go only on the ticket.
      stage_fail "The plan changes $(echo "$MISSING_FILES" | wc -l | tr -d ' ') file(s) that don't exist, so it wasn't applied. Comment $REVISE_COMMAND to try again." \
        "Files: $(echo "$MISSING_FILES" | paste -sd ',' - | sed 's/,/, /g')."
    fi
  fi
  agent_summary "Implementation plan"
}

# step_apply: Write the result to the ticket.
step_apply() {
  MODE=$(stage_mode)
  START_STATUS=$(stage_start_status)
  tracker_require_status "$START_STATUS" || exit 0
  # Before changing anything, so a misconfigured tracker workflow can't
  # leave a half-processed ticket. A revision is already there.
  TRANSITION_ID=""
  [ "$START_STATUS" = "$PLAN_STATUS" ] || TRANSITION_ID=$(stage_transition_id "$PLAN_STATUS")

  # The full plan, as Markdown, to attach to the ticket. A revision
  # changes only its updated sections of the attached file, so the rest
  # — including people's edits to it — stays as it is.
  PLAN_FILE="$RUNNER_TEMP/$TICKET_KEY-$PLAN_FILE_SUFFIX"
  if [ "$MODE" = revision ]; then
    source "$STAGE_DIR/revise.sh"
    jq '.structured_output.updates' "$RUNNER_TEMP/agent-output.json" > "$RUNNER_TEMP/updates.json"
    # Like work orders: a section the revision changes may have been
    # removed or renamed by hand — say which, before changing anything.
    MISSING_SECTIONS=$(revision_missing_sections "$RUNNER_TEMP/updates.json" "$RUNNER_TEMP/current-plan.md")
    if [ -n "$MISSING_SECTIONS" ]; then
      stage_fail "The revision changes sections the attached plan no longer has: $MISSING_SECTIONS. Nothing was changed. Put the heading(s) back in the file (same name, as a \"## \" heading), upload it with the same name, then comment $REVISE_COMMAND again."
    fi
  else
    jq '.structured_output.plan' "$RUNNER_TEMP/agent-output.json" > "$RUNNER_TEMP/plan.json"
  fi
  # A version line under the title says when and how this file was made,
  # so a stale download is easy to spot before editing it by hand.
  NOW=$(date -u '+%Y-%m-%d %H:%M UTC')
  if [ "$MODE" = revision ]; then
    BASIS=$(jq -r '"the attachment uploaded \((.created // "")[0:16] | sub("T"; " ")) by \(.author.displayName // "someone")"' \
      "$RUNNER_TEMP/current-plan-attachment.json")
    VERSION="_Version: $NOW — revised after change requests, from $BASIS._"
  else
    VERSION="_Version: $NOW — written from the approved work order on $TICKET_KEY._"
  fi
  {
    if [ "$MODE" = revision ]; then
      revision_plan_markdown "$RUNNER_TEMP/updates.json" "$RUNNER_TEMP/current-plan.md" \
        | revision_version_line "$VERSION"
    else
      jq -r '"# Implementation plan: \(env.TICKET_KEY) — \(.fields.summary)\n"' "$RUNNER_TEMP/ticket.json"
      echo "$VERSION"
      echo
      jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode full --arg file "" --argjson level 2 "$RUNNER_TEMP/plan.json" \
        | jq -r -L "$HUB_DIR/lib" 'include "adf"; {content: .} | to_markdown'
    fi
    # The expert review's full notes (the attachment is private to the tracker;
    # they're never logged).
    jq -r '"\n## Expert review\n\n\(.note)\n",
      (if (.changes | length) > 0 then "**Changes made**\n", (.changes[] | "- \(.)"), "" else empty end),
      (if (.issues | length) > 0 then "**Issues found in the draft**\n", (.issues[] | "- \(.)"), "" else empty end)' \
      "$RUNNER_TEMP/review.json"
  } > "$PLAN_FILE"

  # The summary goes into the Implementation Plan section of the current
  # description (read fresh, so edits made during the run are kept);
  # the work order around it is untouched.
  if [ "$MODE" = revision ]; then
    tracker_issue description | jq '.fields.description' \
      | revision_summary "$RUNNER_TEMP/updates.json" "$(basename "$PLAN_FILE")"
  else
    jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode summary \
      --arg file "$(basename "$PLAN_FILE")" --argjson level 5 "$RUNNER_TEMP/plan.json"
  fi | jq -L "$HUB_DIR/lib" --slurpfile review "$RUNNER_TEMP/review.json" 'include "adf";
        . + [para([em("Expert review: \($review[0].note)")])]' > "$RUNNER_TEMP/plan-summary.json"
  tracker_issue description \
    | jq -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" --slurpfile blocks "$RUNNER_TEMP/plan-summary.json" \
        'include "adf"; .fields.description | replace_section($section; $blocks[0])' \
    > "$RUNNER_TEMP/description.json"
  SIZE=$(jq -r -L "$HUB_DIR/lib" 'include "adf"; to_markdown | length' "$RUNNER_TEMP/description.json")
  if [ "$SIZE" -gt "$DESCRIPTION_MAX_CHARS" ]; then
    stage_fail "With the plan summary, the description would be $SIZE characters — over $TRACKER_NAME's limit ($DESCRIPTION_MAX_CHARS) — so nothing was changed. Shorten the work order, or comment $REVISE_COMMAND asking for a shorter plan."
  fi

  # Upload the new plan first: if anything fails after this, the ticket
  # still has a plan. Earlier plans are removed only once the new one
  # is in place, so the build stage always finds exactly one.
  PREVIOUS=$(tracker_attachments | jq -r --arg name "$(basename "$PLAN_FILE")" '.[] | select(.filename == $name) | .id')
  tracker_attach "$PLAN_FILE" > /dev/null
  # Waiting for a person to review and approve the plan; questions answered.
  tracker_set_description "-$NEEDS_CLARIFICATION_LABEL" "+$NEEDS_HUMAN_LABEL" < "$RUNNER_TEMP/description.json"
  for ATTACHMENT in $PREVIOUS; do tracker_delete_attachment "$ATTACHMENT"; done
  [ -z "$TRANSITION_ID" ] || tracker_transition "$TRANSITION_ID"

  # Say how each change request was handled, then mark them and the
  # clarification requests as resolved.
  if [ "$MODE" = revision ]; then
    stage_revision_reply "implementation plan" \
      "Revised from $BASIS. To edit the plan by hand, download the newest attachment first and check its Version line."
  else
    stage_revision_reply "implementation plan"
  fi
  tracker_comments > "$RUNNER_TEMP/comments.json"
  RESOLVED=$(stage_resolve_comments "$RUNNER_TEMP/comments.json" \
    "the questions were answered and the implementation plan was written." "$NEEDS_CLARIFICATION_TITLE")
  REVISIONS=$(stage_resolve_revisions "$RUNNER_TEMP/comments.json")

  echo "Implementation plan $([ "$MODE" = revision ] && echo revised || echo written) on [$TICKET_KEY]($TICKET_URL), in $PLAN_STATUS; resolved $RESOLVED clarification comment(s) and $REVISIONS change request(s)." >> "$GITHUB_STEP_SUMMARY"
}

# step_return: Send the ticket back: the result says it can't go ahead yet.
step_return() {
  tracker_require_status "$(stage_start_status)" || exit 0
  TRANSITION_ID=$(stage_transition_id "$WORK_ORDER_STATUS")

  jq -L "$HUB_DIR/lib" --arg title "$NEEDS_CLARIFICATION_TITLE" --arg message "$NEEDS_CLARIFICATION_MESSAGE" 'include "adf";
    doc([para([strong($title), text(" — flagged by Claude (implementation plan review).")]),
         para($message),
         bullets([.structured_output.questions[]
           | [strong(.question), text(" Why it matters: \(.why) Best answered by: \(.who).")]])])' \
    "$RUNNER_TEMP/agent-output.json" | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_CLARIFICATION_LABEL" "+$NEEDS_HUMAN_LABEL"
  tracker_transition "$TRANSITION_ID"

  echo "[$TICKET_KEY]($TICKET_URL) returned to $WORK_ORDER_STATUS as $NEEDS_CLARIFICATION_LABEL." >> "$GITHUB_STEP_SUMMARY"
}
