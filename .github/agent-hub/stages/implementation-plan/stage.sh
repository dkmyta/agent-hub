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
  if [ "$(stage_acceptance_criteria)" = 0 ] \
    || ! jq -e -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" 'include "adf";
         .fields.description // {content: []} | section_index($section) != null' \
         "$RUNNER_TEMP/ticket.json" > /dev/null; then
    stage_fail "There's no work order to plan from: the description needs its Acceptance Criteria checklist and an \"$PLAN_SECTION\" section. Generate the work order first, or restore those sections, then move the ticket to Work Order Approved again."
  fi

  # A new plan is written only from the work order exactly as approved: one
  # edited after its approval (by anyone) needs approving again, and one
  # whose approval can't be found or read isn't planned at all. Before Claude
  # runs, so neither costs any Claude usage.
  if [ "$(stage_start_status)" = "$WORK_ORDER_APPROVED_STATUS" ]; then
    # One read of the history since the approval: whether the work order
    # changed, and who approved it.
    HISTORY=$(tracker_history_since "$WORK_ORDER_APPROVED_STATUS") \
      || stage_fail "Couldn't read $TICKET_KEY's history from $TRACKER_NAME to check the work order is the one approved, so nothing was changed. Move the ticket to $WORK_ORDER_APPROVED_STATUS again to retry."
    EDITED=$(jq -r 'if (.entered | not) then "unknown" elif any(.changes[]; .field == "description") then "yes" else "no" end' <<< "$HISTORY")
    case "$EDITED" in
      yes) _approval_stale; exit 0 ;;
      unknown) stage_fail "$TICKET_KEY's history shows no move to $WORK_ORDER_APPROVED_STATUS, so there's no approval to plan from and nothing was changed. Move the ticket to $WORK_ORDER_APPROVED_STATUS to approve the work order." ;;
    esac
    # Who approved: a person, not the automation account — and, with an
    # approvers group set, one of its members (as the build checks).
    APPROVER=$(jq -r '.by // ""' <<< "$HISTORY")
    [ "$APPROVER" != "$(tracker_account_id)" ] \
      || stage_fail "The move to $WORK_ORDER_APPROVED_STATUS was made by the automation account, not a person, so it isn't an approval and nothing was changed. A person approves the work order by moving the ticket there."
    rc=0
    stage_is_approver "$APPROVER" || rc=$?
    case "$rc" in
      1) stage_fail "The move to $WORK_ORDER_APPROVED_STATUS was made by someone who isn't in $APPROVERS_GROUP, so it isn't an approval and nothing was changed. One of its members approves the work order." ;;
      2) stage_fail "Couldn't check that the person who moved the ticket to $WORK_ORDER_APPROVED_STATUS is in $APPROVERS_GROUP, so nothing was changed (the Jira service account needs Browse users and groups)." ;;
    esac
  fi

  stage_ticket_markdown --with-comments

  # The plan files on the ticket as the run starts, oldest first: a
  # revision starts from the newest, and apply checks that no newer one
  # arrived meanwhile and replaces only these.
  ATTACHMENTS=$(tracker_attachments) \
    || stage_fail "Couldn't read the ticket's attachments from $TRACKER_NAME, so nothing was changed."
  jq --arg name "$PLAN_FILE_NAME" '[.[] | select(.filename == $name)] | sort_by(.created)' \
    <<< "$ATTACHMENTS" > "$RUNNER_TEMP/plan-attachments.json"

  # Revising: Claude starts from the attached plan (the description only
  # has its summary). Without one (e.g. deleted), write a new plan.
  MODE=new
  if [ "$(stage_start_status)" = "$PLAN_STATUS" ]; then
    # The newest one, and who uploaded it when — said in the version
    # line and the 🔁 reply, so a revision of a stale upload is visible.
    jq '.[-1] // {}' "$RUNNER_TEMP/plan-attachments.json" > "$RUNNER_TEMP/current-plan-attachment.json"
    PLAN_ID=$(jq -r '.id // empty' "$RUNNER_TEMP/current-plan-attachment.json")
    if [ -n "$PLAN_ID" ]; then
      # The attached file is the plan's source of truth: people may have
      # edited and re-uploaded it (the newest one wins).
      tracker_attachment_content "$PLAN_ID" > "$RUNNER_TEMP/current-plan.md"
      {
        printf '\nCurrent implementation plan (attached as %s):\n\n' "$PLAN_FILE_NAME"
        cat "$RUNNER_TEMP/current-plan.md"
      } >> "$RUNNER_TEMP/ticket.md"
      MODE=revision
    else
      echo "::notice::No attached plan to revise on $TICKET_KEY — writing a new one."
    fi
  fi
  stage_set_mode "$MODE"
  # A plan is revised only on request: with no open change requests this is
  # a duplicate (queued behind the run that handled them, or a second move
  # to Work Order Approved behind the run that wrote the plan).
  if [ "$MODE" = revision ] && [ "$(stage_open_change_requests)" = 0 ]; then
    stage_nothing_to_revise "no open $REVISE_COMMAND comments"
  fi

  if [ "$MODE" = revision ]; then
    stage_progress_comment "⏳ Revising implementation plan" \
      " — usually takes 5–10 minutes. Refresh the page to see the result. "
  else
    stage_progress_comment "⏳ Writing implementation plan" \
      " — usually takes 5–10 minutes. Refresh the page to see the result. "
  fi
}

# _approval_stale: the work order was edited after its approval — by anyone,
# including a plan run that wrote its summary and then failed. Move the ticket
# back to Work Order for a person to check and approve again; no plan is
# written from a work order nobody approved.
_approval_stale() {
  # shellcheck disable=SC1112 # curly apostrophe intended
  stage_send_back_stale "$WORK_ORDER_STATUS" "Work order changed after approval" \
    "the description changed after it was approved, so no plan was written from it. It’s back in $WORK_ORDER_STATUS: check the work order, then approve it again." \
    "the work order was edited after its approval."
}

# _work_order_changed: whether the description now (ticket-before.json)
# differs from the one the run read (ticket.json), apart from the plan's own
# section, which this run replaces. A section removed by hand counts as a
# change.
_work_order_changed() {
  local filter='include "adf"; .fields.description // {content: []} | try replace_section($section; []) catch "no plan section"'
  [ "$(jq -c -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" "$filter" "$RUNNER_TEMP/ticket.json")" \
    != "$(jq -c -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" "$filter" "$RUNNER_TEMP/ticket-before.json")" ]
}

# _stop_if_newer_plan [ours] [restore]: fail if a plan file was uploaded
# since the run started (a person's edit, which an older basis would bury),
# or if that can't be checked — first taking back this run's upload <ours>
# and, with <restore>, its description and label change, so the person's
# file stays the plan.
_stop_if_newer_plan() {
  local attachments newer why next done="nothing was changed"
  if attachments=$(tracker_attachments); then
    newer=$(jq -r --arg name "$(basename "$PLAN_FILE")" --arg ours "${1:-}" \
      --slurpfile start "$RUNNER_TEMP/plan-attachments.json" \
      '[.[] | select(.filename == $name) | .id] - [$start[0][].id] - [$ours] | join(", ")' <<< "$attachments")
    [ -n "$newer" ] || return 0
    why="A newer $(basename "$PLAN_FILE") was uploaded while this run was working"
    next="the run started from an older version. Comment $REVISE_COMMAND to revise the newest one."
  else
    why="Couldn't check $TRACKER_NAME for a newer $(basename "$PLAN_FILE") uploaded while this run was working"
    next="re-run it, or comment $REVISE_COMMAND."
  fi
  if [ -n "${1:-}" ]; then
    if tracker_delete_attachment "$1"; then
      done="this run's plan was removed again and nothing else was changed"
    else
      done="this run's plan couldn't be removed again — delete the newest $(basename "$PLAN_FILE") by hand"
    fi
  fi
  if [ -n "${2:-}" ]; then
    if tracker_set_description "$(jq -r --arg label "$NEEDS_CLARIFICATION_LABEL" \
        'if .fields.labels // [] | index($label) then "+" + $label else "" end' "$RUNNER_TEMP/ticket-before.json")" \
        < "$RUNNER_TEMP/description-before.json"; then
      case "$done" in
        *"nothing else was changed") done="${done% and nothing else was changed} and the description put back" ;;
        *) done="$done; the description was put back" ;;
      esac
    else
      done="$done; the description couldn't be put back — the run's summary is in it"
    fi
  fi
  stage_fail "$why, so $done: $next"
}

# _plan_path_problem <action> <path>: why the plan can't change this path —
# "outside the repository" (absolute, "..", or a link leading out of it),
# "doesn't exist" (a file to modify or delete must be one) or "already exists"
# (a file to add must be new — not even a link) — or nothing.
_plan_path_problem() {
  local path=${2#./} root dir real
  case "$path" in "" | /* | .. | ../* | */.. | */../*) echo "outside the repository"; return ;; esac
  # Workflows, Claude Code's settings and code owners are for a person to
  # change: the plan lists them as manual changes (governance), never as
  # changes the build makes.
  if hub_managed_path "$path"; then echo "for a person to change: list it as a manual change"; return; fi
  root=$(pwd -P)
  if [ "$1" = add ]; then
    # A new file: nothing there yet, and the nearest folder that exists
    # inside — with no link on the way to it (one that doesn't resolve could
    # lead anywhere once it's created).
    if [ -e "$path" ] || [ -L "$path" ]; then echo "already exists"; return; fi
    dir=$(dirname "$path")
    while [ ! -d "$dir" ]; do
      if [ -L "$dir" ]; then echo "outside the repository"; return; fi
      dir=$(dirname "$dir")
    done
    real=$(cd "$dir" && pwd -P)
  else
    [ -f "$path" ] || { echo "doesn't exist"; return; }
    # A link: where it really leads (readlink -f isn't on every macOS, nor
    # realpath before macOS 13), resolved one link at a time.
    real=$path
    while [ -L "$real" ]; do
      dir=$(dirname "$real") real=$(readlink "$real")
      case "$real" in /*) ;; *) real="$dir/$real" ;; esac
    done
    real=$(cd "$(dirname "$real")" 2> /dev/null && pwd -P) || { echo "outside the repository"; return; }
  fi
  case "$real/" in "$root"/*) ;; *) echo "outside the repository" ;; esac
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
    MISSING=""
    if jq -e 'has("acceptance_criteria")' "$RUNNER_TEMP/plan-checked.json" > /dev/null; then
      MISSING=$(stage_uncovered_criteria "$(jq -c '[.acceptance_criteria[].criterion]' "$RUNNER_TEMP/plan-checked.json")")
    fi
    if [ -n "$MISSING" ]; then
      stage_fail "The plan didn't cover acceptance criteria $MISSING (by position in the work order), so it wasn't applied. Comment $REVISE_COMMAND to try again."
    fi
    # A new plan changes something: files the build changes, or manual
    # changes for a person.
    if jq -e 'has("changes") and has("governance") and (.changes | length) == 0
        and (.governance.manual_changes | length) == 0' "$RUNNER_TEMP/plan-checked.json" > /dev/null; then
      stage_fail "The plan names no changes — none for the build and no manual ones — so it wasn't applied. Comment $REVISE_COMMAND to try again."
    fi
    BAD_FILES=$(jq -r '(.changes // [])[] | "\(.action)\t\(.path)"' "$RUNNER_TEMP/plan-checked.json" \
      | while IFS=$'\t' read -r ACTION FILE; do
          PROBLEM=$(_plan_path_problem "$ACTION" "$FILE")
          [ -z "$PROBLEM" ] || echo "$FILE ($PROBLEM)"
        done)
    if [ -n "$BAD_FILES" ]; then
      # The paths come from Claude, so they go only on the ticket.
      stage_fail "The plan names $(echo "$BAD_FILES" | wc -l | tr -d ' ') file(s) it can't change — missing, already there to add, outside the repository, or for a person to change — so it wasn't applied. Comment $REVISE_COMMAND to try again." \
        "Files: $(echo "$BAD_FILES" | paste -sd ',' - | sed 's/,/, /g')."
    fi
    # Each folder the plan's dependency changes name is an npm project the
    # build can change (a package.json and package-lock.json, real files,
    # not a path only people change) — checked here, before a person
    # approves the plan; the build checks again, and resolves them.
    BAD_FOLDERS=$(jq -r '[(.governance.dependency_changes // [])[].folder] | unique | .[]' "$RUNNER_TEMP/plan-checked.json" \
      | while IFS= read -r FOLDER; do
          if hub_managed_path "$FOLDER/package.json"; then echo "$FOLDER (for a person to change)"
          elif [ ! -f "$FOLDER/package.json" ] || [ -L "$FOLDER/package.json" ] \
            || [ ! -f "$FOLDER/package-lock.json" ] || [ -L "$FOLDER/package-lock.json" ]; then
            echo "$FOLDER (not an npm project with a package.json and package-lock.json)"
          fi
        done)
    if [ -n "$BAD_FOLDERS" ]; then
      stage_fail "The plan's dependency changes name $(echo "$BAD_FOLDERS" | wc -l | tr -d ' ') folder(s) the build can't apply them in — it changes npm projects with a lockfile only; a change anywhere else is a manual change — so it wasn't applied. Comment $REVISE_COMMAND to try again." \
        "Folders: $(echo "$BAD_FOLDERS" | paste -sd ',' - | sed 's/,/, /g')."
    fi
  fi
  agent_summary "Implementation plan"
}

# step_apply: Write the result to the ticket.
step_apply() {
  MODE=$(stage_mode)
  START_STATUS=$(stage_start_status)
  stage_require_status "$START_STATUS"
  # Before changing anything, so a misconfigured tracker workflow can't
  # leave a half-processed ticket. A revision is already there.
  TRANSITION_ID=""
  [ "$START_STATUS" = "$PLAN_STATUS" ] || TRANSITION_ID=$(stage_transition_id "$PLAN_STATUS")

  # The full plan, as Markdown, to attach to the ticket. A revision
  # changes only its updated sections of the attached file, so the rest
  # — including people's edits to it — stays as it is.
  PLAN_FILE="$RUNNER_TEMP/$PLAN_FILE_NAME"
  if [ "$MODE" = revision ]; then
    source "$STAGE_DIR/revise.sh"
    jq '.structured_output.updates' "$RUNNER_TEMP/agent-output.json" > "$RUNNER_TEMP/updates.json"
    # Like work orders: a section the revision changes may have been
    # removed or renamed by hand — say which, before changing anything.
    MISSING_SECTIONS=$(revision_missing_sections "$RUNNER_TEMP/updates.json" "$RUNNER_TEMP/current-plan.md")
    if [ -n "$MISSING_SECTIONS" ]; then
      stage_fail "The revision changes sections the attached plan no longer has: $MISSING_SECTIONS. Nothing was changed. Put the heading(s) back in the file (same name, as a \"## \" heading), upload it with the same name, then comment $REVISE_COMMAND again."
    fi
    DUPLICATED_SECTIONS=$(revision_duplicated_sections "$RUNNER_TEMP/updates.json" "$RUNNER_TEMP/current-plan.md")
    if [ -n "$DUPLICATED_SECTIONS" ]; then
      stage_fail "The attached plan has more than one section the revision changes: $DUPLICATED_SECTIONS. Nothing was changed. Merge or rename them in the file, upload it with the same name, then comment $REVISE_COMMAND again."
    fi
  else
    jq '.structured_output.plan' "$RUNNER_TEMP/agent-output.json" > "$RUNNER_TEMP/plan.json"
  fi
  # A version line under the title says when and how this file was made,
  # so a stale download is easy to spot before editing it by hand.
  NOW=$(date -u '+%Y-%m-%d %H:%M UTC')
  # The commit the plan describes (the code the agent read), so the build
  # can tell what changed since.
  BASE_COMMIT=$(git rev-parse HEAD 2> /dev/null) || BASE_COMMIT=unknown
  if [ "$MODE" = revision ]; then
    BASIS=$(jq -r '"the attachment uploaded \((.created // "")[0:16] | sub("T"; " ")) by \(.author.displayName // "someone")"' \
      "$RUNNER_TEMP/current-plan-attachment.json")
    VERSION="_Version: $NOW — revised after change requests, from $BASIS; against commit $BASE_COMMIT._"
  else
    VERSION="_Version: $NOW — written from the approved work order on $TICKET_KEY, against commit $BASE_COMMIT._"
  fi
  {
    if [ "$MODE" = revision ]; then
      # The build's questions (if it sent the plan back) are answered by this
      # revision (prompt.md), so their section goes.
      revision_plan_markdown "$RUNNER_TEMP/updates.json" "$RUNNER_TEMP/current-plan.md" \
        | stage_drop_md_section "$BUILD_QUESTIONS_SECTION" | revision_version_line "$VERSION"
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

  # The build's own reading of the file (stages/build/contract.jq): the
  # summary shows what it will hold the build to, so the approval covers it.
  jq -Rs -L "$HUB_DIR/lib" -f "$HUB_DIR/stages/build/contract.jq" "$PLAN_FILE" > "$RUNNER_TEMP/plan-contract.json" \
    || stage_fail "Couldn't read the plan's scope the way the build will, so nothing was changed."

  # The summary goes into the Implementation Plan section of the current
  # description (read fresh, so edits made during the run are kept);
  # the work order around it is untouched.
  if [ "$MODE" = revision ]; then
    tracker_issue description | jq '.fields.description' \
      | revision_summary "$RUNNER_TEMP/updates.json" "$(basename "$PLAN_FILE")"
  else
    jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode summary \
      --arg file "$(basename "$PLAN_FILE")" --argjson level 5 "$RUNNER_TEMP/plan.json"
  fi | jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode scope --arg file "" --argjson level 5 \
      --slurpfile contract "$RUNNER_TEMP/plan-contract.json" \
    | jq -L "$HUB_DIR/lib" --slurpfile review "$RUNNER_TEMP/review.json" 'include "adf";
        . + [para([em("Expert review: \($review[0].note)")])]' > "$RUNNER_TEMP/plan-summary.json"
  # The description and labels as they are now are kept, to put back if the
  # plan can't be published after all (see below).
  tracker_issue description,labels > "$RUNNER_TEMP/ticket-before.json"
  jq '.fields.description' "$RUNNER_TEMP/ticket-before.json" > "$RUNNER_TEMP/description-before.json"
  # The work order must still be the one the plan was written from: edited
  # during the run, the plan may no longer match it. A new plan's approval
  # is then stale; a revision stops for a person to check.
  if _work_order_changed; then
    if [ "$START_STATUS" = "$WORK_ORDER_APPROVED_STATUS" ]; then _approval_stale; exit 0; fi
    stage_fail "The work order changed while the plan was being revised, so nothing was changed. Check it, then comment $REVISE_COMMAND to revise the plan against it."
  fi
  jq -L "$HUB_DIR/lib" --arg section "$PLAN_SECTION" --slurpfile blocks "$RUNNER_TEMP/plan-summary.json" \
      'include "adf"; replace_section($section; $blocks[0])' "$RUNNER_TEMP/description-before.json" \
    > "$RUNNER_TEMP/description.json"
  SIZE=$(jq -r -L "$HUB_DIR/lib" 'include "adf"; to_markdown | length' "$RUNNER_TEMP/description.json")
  if [ "$SIZE" -gt "$DESCRIPTION_MAX_CHARS" ]; then
    stage_fail "With the plan summary, the description would be $SIZE characters — over $TRACKER_NAME's limit ($DESCRIPTION_MAX_CHARS) — so nothing was changed. Shorten the work order, or comment $REVISE_COMMAND asking for a shorter plan."
  fi

  # A plan file uploaded since the run started stops the run before
  # anything changes.
  _stop_if_newer_plan
  # The earlier plan files this one replaces: the hub's own uploads only.
  # A person's upload is never deleted — it stays on the ticket as a
  # record; the newest file is always the plan.
  PREVIOUS=""
  if [ "$(jq length "$RUNNER_TEMP/plan-attachments.json")" -gt 0 ]; then
    PREVIOUS=$(jq -r --arg me "$(tracker_account_id)" '.[] | select(.author.accountId == $me) | .id' "$RUNNER_TEMP/plan-attachments.json")
  fi

  # Upload the new plan first: if anything fails after this, the ticket
  # still has a plan. The hub's earlier ones are removed only once the new
  # one is in place.
  OURS=$(tracker_attach "$PLAN_FILE")
  # One can still land while this one publishes: checked again after each
  # write, and this run's changes taken back.
  _stop_if_newer_plan "$OURS"
  # Waiting for a person to review and approve the plan; questions answered.
  tracker_set_description "-$NEEDS_CLARIFICATION_LABEL" "+$NEEDS_HUMAN_LABEL" < "$RUNNER_TEMP/description.json"
  _stop_if_newer_plan "$OURS" restore
  # Cleanup: an earlier file left behind is harmless (the newest is the
  # plan), so it doesn't stop the run.
  for ATTACHMENT in $PREVIOUS; do
    tracker_delete_attachment "$ATTACHMENT" > /dev/null \
      || echo "::warning::Couldn't remove the hub's earlier plan file (attachment $ATTACHMENT); the newest file is the plan."
  done
  [ -z "$TRANSITION_ID" ] || stage_move "$TRANSITION_ID" "$PLAN_STATUS"

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
  stage_outcome "$(stage_written_outcome "$MODE")"
}

# step_return: Send the ticket back: the result says it can't go ahead yet.
step_return() {
  stage_require_status "$(stage_start_status)"
  TRANSITION_ID=$(stage_transition_id "$WORK_ORDER_STATUS")

  jq -L "$HUB_DIR/lib" --arg title "$NEEDS_CLARIFICATION_TITLE" --arg message "$NEEDS_CLARIFICATION_MESSAGE" 'include "adf";
    doc([para([strong($title), text(" — flagged by Claude (implementation plan review).")]),
         para($message),
         bullets([.structured_output.questions[]
           | [strong(.question), text(" Why it matters: \(.why) Best answered by: \(.who).")]])])' \
    "$RUNNER_TEMP/agent-output.json" | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_CLARIFICATION_LABEL" "+$NEEDS_HUMAN_LABEL"
  stage_move "$TRANSITION_ID" "$WORK_ORDER_STATUS"

  echo "[$TICKET_KEY]($TICKET_URL) returned to $WORK_ORDER_STATUS as $NEEDS_CLARIFICATION_LABEL." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome "sent back"
}
