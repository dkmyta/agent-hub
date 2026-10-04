# shellcheck shell=bash
# The build stage: turns an approved implementation plan into a draft pull
# request on branch agent-hub/<KEY>, or sends the ticket back with questions.
# Its steps, run by the shared stage workflow (.github/workflows/agent-hub-stage.yml,
# with code-stage on) with the settings, tracker, GitHub library and shared
# libraries already loaded. See docs/workflows/build.md.
#
# This version: start (the exact plan approved, its contract, the branch),
# validate and build in one agent pass, the gates, the secret scan and the
# draft pull request with its state block. The install, dependency and verify
# steps, the review, CI and hand-off come in later versions; until then a
# person reviews the draft.
#
# The agent can change anything in the checkout — .git included — so no
# later step trusts it: each loads the hub from the workflow's copy, and git
# runs with the repository's metadata as copied before the agent started
# (build_git), taking only the files' content from the checkout.

BUILD_CONTEXT="$RUNNER_TEMP/build-context.json"
BUILD_GIT="$RUNNER_TEMP/build-git"
# The agent's result (the runner's AGENT_OUTPUT), for the steps after it.
BUILD_OUTPUT="$RUNNER_TEMP/agent-output.json"
QUESTIONS_SECTION="Questions from the build"

# build_git: git, from here on in this step, with the metadata copied before
# the agent ran and none of the runner's or repository's configuration that
# could run a program (hooks, fsmonitor; global and system config ignored).
build_git() {
  export GIT_DIR="$BUILD_GIT" GIT_WORK_TREE="$PWD" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
}

# context <jq path>: a value recorded by the fetch step (build-context.json).
context() { jq -r "$1" "$BUILD_CONTEXT"; }

# step_fetch: Check the approval, read the plan's contract and the branch, and post the progress comment.
step_fetch() {
  stage_fetch "$PLAN_APPROVED_STATUS" || exit 0
  stage_set_mode new
  # Not for real tickets yet (settings.sh): stop before anything else.
  [ "$BUILD_PREVIEW" = true ] \
    || stage_fail "The build stage isn't enabled for real tickets yet: it needs its install step (the next version) so a build can't depend on whatever the runner has installed. Nothing was built. For development on a project without dependencies, set the repository variable AGENT_HUB_BUILD_PREVIEW to true."

  # The checkout as the workflow made it, and its git metadata kept before
  # any agent runs.
  if [ ! -d .git ] || [ -n "$(git status --porcelain)" ]; then
    stage_fail "The checkout isn't a clean git repository, so nothing was built. Re-run the workflow; if it happens again, clean the runner's work folder."
  fi
  rm -rf "$BUILD_GIT" && cp -R .git "$BUILD_GIT"
  build_git

  _approved_plan
  # The work order's acceptance criteria, which the build must verify.
  jq -L "$HUB_DIR/lib" 'include "adf";
    [.fields.description // {content: []} | section_blocks("Acceptance Criteria")[]
     | select(.type == "taskList") | .content[] | plain_text]' \
    "$RUNNER_TEMP/ticket.json" > "$RUNNER_TEMP/acceptance-criteria.json"
  if [ "$(jq length "$RUNNER_TEMP/acceptance-criteria.json")" = 0 ]; then
    stage_fail "The description has no Acceptance Criteria checklist, so there's nothing to verify the build against and nothing was built. Restore the work order's criteria, then approve the plan again."
  fi
  # A plan with only manual changes leaves the build nothing to do.
  if jq -e '(.changes | length) == 0' "$RUNNER_TEMP/contract.json" > /dev/null; then
    _manual_only
    exit 0
  fi
  _branch
  # The agent gets the work order and the approved plan — not the comments,
  # which nobody approved.
  stage_ticket_markdown
  {
    printf '\nApproved implementation plan (the attached %s):\n\n' "$TICKET_KEY-$PLAN_FILE_SUFFIX"
    cat "$RUNNER_TEMP/plan.md"
  } >> "$RUNNER_TEMP/ticket.md"
  stage_progress_comment "⏳ Building" \
    " — implementing the approved plan; usually takes 10–30 minutes. Refresh the page to see the result. "
}

# _approved_plan: the plan file people approved, exactly (docs/workflows/build.md,
# "Approval check"): the newest plan file, with no plan file added or deleted
# since the ticket entered Implementation Plan Approved — otherwise the
# approval is stale. Downloads it (plan.md), reads its contract
# (contract.json) and records what was approved (build-context.json).
_approved_plan() {
  local history attachments name="$TICKET_KEY-$PLAN_FILE_SUFFIX" problems
  history=$(tracker_history_since "$PLAN_APPROVED_STATUS") \
    || stage_fail "Couldn't read $TICKET_KEY's history from $TRACKER_NAME to check which plan was approved, so nothing was built."
  jq -e '.entered' <<< "$history" > /dev/null \
    || stage_fail "$TICKET_KEY's history shows no move to $PLAN_APPROVED_STATUS, so there's no approval to build from and nothing was built. A person approves the plan by moving the ticket there."
  # The automation account can't approve (docs/jira.md); a move it made
  # anyway isn't a person's approval.
  [ "$(jq -r '.by' <<< "$history")" != "$(tracker_account_id)" ] \
    || stage_fail "The move to $PLAN_APPROVED_STATUS was made by the automation account, not a person, so it isn't an approval and nothing was built. A person approves the plan by moving the ticket there."
  if jq -e --arg name "$name" 'any(.changes[]; .field == "Attachment" and (.toString == $name or .fromString == $name))' \
      <<< "$history" > /dev/null; then
    _approval_stale
    exit 0
  fi
  attachments=$(tracker_attachments) \
    || stage_fail "Couldn't read the ticket's attachments from $TRACKER_NAME, so nothing was built."
  jq -c --arg name "$name" '[.[] | select(.filename == $name)] | sort_by(.created) | last // empty' \
    <<< "$attachments" > "$RUNNER_TEMP/plan-attachment.json"
  [ -s "$RUNNER_TEMP/plan-attachment.json" ] \
    || stage_fail "There's no $name on the ticket to build from, so nothing was built. Write the plan (move the ticket to $WORK_ORDER_APPROVED_STATUS), then approve it."
  tracker_attachment_content "$(jq -r '.id' "$RUNNER_TEMP/plan-attachment.json")" > "$RUNNER_TEMP/plan.md" \
    || stage_fail "Couldn't download the approved plan from $TRACKER_NAME, so nothing was built."

  jq -Rs -L "$HUB_DIR/lib" -f "$STAGE_DIR/contract.jq" "$RUNNER_TEMP/plan.md" > "$RUNNER_TEMP/contract.json"
  problems=$(jq -r '.problems | join("; ")' "$RUNNER_TEMP/contract.json")
  [ -z "$problems" ] \
    || stage_fail "The approved plan can't be read as a build contract ($problems), so nothing was built. Move the ticket back to $PLAN_STATUS, revise the plan, and approve it again."

  jq -n --argjson history "$history" --slurpfile attachment "$RUNNER_TEMP/plan-attachment.json" \
      --arg sha256 "$(_sha256 "$RUNNER_TEMP/plan.md")" '{plan: {
    attachment: $attachment[0].id, uploaded: ($attachment[0].created // ""),
    uploaded_by: ($attachment[0].author.displayName // ""), sha256: $sha256,
    approved_at: $history.at, approved_by: $history.by_name}}' > "$BUILD_CONTEXT"
}

# _approval_stale: a plan file was uploaded or deleted after the approval, so
# what was approved may not be the plan on the ticket. Back to
# Implementation Plan for a person to check and approve again.
_approval_stale() {
  local transition
  transition=$(stage_transition_id "$PLAN_STATUS")
  # shellcheck disable=SC1112 # curly apostrophe intended
  jq -n -L "$HUB_DIR/lib" --arg status "$PLAN_STATUS" --arg approved "$PLAN_APPROVED_STATUS" 'include "adf";
    doc([para([strong("⚠️ Plan changed after approval"),
      text(" — a plan file was uploaded or removed after the plan was approved, so nothing was built from it. It’s back in \($status): check the newest plan file, then move the ticket to \($approved) again.")])])' \
    | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL"
  stage_move "$transition" "$PLAN_STATUS"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  echo "[$TICKET_KEY]($TICKET_URL) returned to $PLAN_STATUS: the plan files changed after its approval." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome stale
}

# _manual_only: the plan's changes are all for a person (docs/workflows/build.md,
# "A plan whose work is all manual changes"): list them on the ticket, flag
# it, and stop — no branch, no pull request.
_manual_only() {
  if jq -e '(.governance.manual_changes | length) == 0' "$RUNNER_TEMP/contract.json" > /dev/null; then
    stage_fail "The approved plan names no changes — none for the build and no manual ones — so there's nothing to build. Move the ticket back to $PLAN_STATUS and revise the plan."
  fi
  jq -L "$HUB_DIR/lib" 'include "adf";
    doc([para([strong("🧑‍🔧 Manual changes only"),
          text(" — every change in the approved plan is one only a person can make, so the build has nothing to do. Make these, then move the ticket on:")]),
         bullets([.governance.manual_changes[] | [code(.path), text(" — \(.change)")]])])' \
    "$RUNNER_TEMP/contract.json" | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  echo "[$TICKET_KEY]($TICKET_URL): the approved plan has only manual changes; flagged for a person." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome "no change needed"
}

# _branch: the target branch (checked out, and still its head), the stage's
# branch (it must not exist yet: docs/workflows/build.md, "Branch
# lifecycle") and the publication policy, added to build-context.json.
_branch() {
  local visibility target head base branch status publish=false
  visibility=$(gh_repo_visibility) \
    || stage_fail "Couldn't read the repository from GitHub, so nothing was built. Check the AGENT_HUB_GITHUB_TOKEN secret (docs/setup.md), then retry."
  target=$BUILD_TARGET_BRANCH
  [ -n "$target" ] || target=$(gh_api GET "/repos/$GITHUB_REPOSITORY" | jq -r '.default_branch // empty') || target=""
  [ -n "$target" ] || stage_fail "Couldn't read the repository's default branch from GitHub, so nothing was built."
  head=$(gh_branch_head "$target") || stage_fail "Couldn't read the target branch $target from GitHub, so nothing was built."
  base=$(git rev-parse HEAD)
  [ "$head" = "$base" ] \
    || stage_fail "The checkout isn't the head of the target branch $target: the branch moved since the run started, or the workflow checked out another one (AGENT_HUB_BUILD_TARGET_BRANCH). Nothing was built."
  branch="$BUILD_BRANCH_PREFIX$TICKET_KEY"
  status=$(gh_branch_status "$branch" "$BUILD_LABEL") \
    || stage_fail "Couldn't check GitHub for an existing $branch, so nothing was built."
  case "$status" in
    absent) ;;
    "open "*) stage_fail "$TICKET_KEY already has the hub's pull request #${status#open }, so nothing was built. Updating it comes in a later version; to build again, close it, delete $branch, then approve the plan again." ;;
    "foreign "*) stage_fail "Pull request #${status#foreign } from $branch wasn't opened by the hub (it has no $BUILD_LABEL label), so nothing was built. A person decides: to build, close it, delete the branch, then approve the plan again." ;;
    orphan) stage_fail "The branch $branch exists with no pull request (a failed earlier build?), so nothing was built. A person decides: delete it to build again." ;;
    "merged "*) stage_fail "Pull request #${status#merged } from $branch was already merged, so nothing was built." ;;
    # Closed unmerged: a person decides. Closing it and deleting the branch
    # only say what state it's in (a bot or a branch rule could do either);
    # building again needs a person's new approval of the plan after it
    # was closed.
    "closed "*)
      head=$(gh_branch_head "$branch") || stage_fail "Couldn't check GitHub for $branch, so nothing was built."
      [ -z "$head" ] \
        || stage_fail "Pull request #${status#closed } from $branch was closed unmerged and its branch is still there, so nothing was built. A person decides: to build again, delete the branch, then approve the plan again."
      _approved_after_close "$branch" \
        || stage_fail "Pull request #${status#closed } from $branch was closed unmerged after the plan's latest approval, so that approval isn't for a new build and nothing was built. To build again, approve the plan again." ;;
    "deleted "*) stage_fail "Pull request #${status#deleted } is open but its branch $branch is gone, so nothing was built. A person decides: to build again, close it, then approve the plan again." ;;
    *) stage_fail "Couldn't tell what state $branch is in, so nothing was built." ;;
  esac
  gh_publish_ticket_text "$visibility" "$PUBLISH_TICKET_CONTENT" && publish=true
  jq --arg target "$target" --arg base "$base" --arg branch "$branch" --arg visibility "$visibility" \
    --argjson publish "$publish" '. + {target: $target, base: $base, branch: $branch, visibility: $visibility, publish: $publish}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
}

# _approved_after_close <branch>: whether the plan's latest approval came
# after the branch's pull request was closed. Fails (closed) if either time
# can't be read.
_approved_after_close() {
  local closed
  closed=$(gh_pr_find "$1" | jq -r '.closed_at // empty') || return 1
  [ -n "$closed" ] || return 1
  jq -e --arg closed "$closed" '
    def epoch: capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
      | (.d + "Z" | fromdateiso8601)
        - (if .z == "Z" then 0 else ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end) end);
    (.plan.approved_at | epoch) > ($closed | epoch)' "$BUILD_CONTEXT" > /dev/null 2>&1
}

# step_agent: The agent: validate the plan against the code, then build it.
step_agent() {
  agent_run "Build the approved implementation plan for this ticket." build
  agent_check build needs-clarification questions no-change-needed reason blocked reason

  # A build must say how each acceptance criterion is verified, word for
  # word. The log names positions, never ticket text.
  if [ "$(jq -r '.structured_output.status' "$AGENT_OUTPUT")" = ready ]; then
    MISSING=$(jq -r --slurpfile out "$AGENT_OUTPUT" '
      def norm: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
      [$out[0].structured_output.build.verification[].criterion | norm] as $covered
      | [to_entries[] | select((.value | norm) as $c | $covered | any(. == $c) | not) | .key + 1]
      | join(", ")' "$RUNNER_TEMP/acceptance-criteria.json")
    if [ -n "$MISSING" ]; then
      stage_fail "The build didn't say how acceptance criteria $MISSING (by position in the work order) are verified, so nothing was pushed."
    fi
  fi
  agent_summary "Build"
}

# step_apply: Commit, check and push the build, and open its draft pull request.
step_apply() {
  local base branch target publish refused findings rc=0 number user message title url
  stage_require_status "$PLAN_APPROVED_STATUS"
  build_git
  _require_same_plan
  base=$(context .base) branch=$(context .branch) target=$(context .target) publish=$(context .publish)

  # Commit everything the agent left in the checkout, as the account the
  # token belongs to (the machine user): its login and its GitHub noreply
  # address (<id>+<login>@users.noreply.github.com), which GitHub attributes
  # to the account — from /user, so the token needs no email permission.
  git add -A
  if git diff --cached --quiet; then
    stage_fail "Claude reported the build finished but changed no files, so there's nothing to push."
  fi
  user=$(gh_api GET /user) || stage_fail "Couldn't read the machine user from GitHub, so nothing was pushed."
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  GIT_AUTHOR_NAME=$(jq -r '.login' <<< "$user")
  GIT_AUTHOR_EMAIL="$(jq -r '.id' <<< "$user")+$GIT_AUTHOR_NAME@users.noreply.github.com"
  GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
  # Claude's message comes from the ticket, so a public repository gets it
  # only if ticket content may be published.
  if [ "$publish" = true ]; then message=$(jq -r '.structured_output.build.commit_message' "$BUILD_OUTPUT")
  else message="Build $TICKET_KEY from its approved implementation plan"; fi
  printf '%s\n\nRefs: %s\n' "$message" "$TICKET_KEY" | git commit -q -F -

  # The gates, on the commit. Refused files stop the push; decision items
  # go to the pull request for a person.
  # shellcheck source=stages/build/gates.sh
  source "$STAGE_DIR/gates.sh"
  build_gates "$base" "$RUNNER_TEMP/contract.json" > "$RUNNER_TEMP/gates.json"
  refused=$(jq '.refused | length' "$RUNNER_TEMP/gates.json")
  if [ "$refused" -gt 0 ]; then
    # The paths come from Claude's changes, so they go only on the ticket.
    stage_fail "The build changed $refused file(s) the hub never pushes ($(jq -r '[.refused[].reason] | unique | join("; ")' "$RUNNER_TEMP/gates.json")), so nothing was pushed. If the plan needs them, they're manual changes for a person." \
      "Files: $(jq -r '[.refused[].path] | join(", ")' "$RUNNER_TEMP/gates.json")."
  fi

  # The secret scan covers everything the push sends; then the push, never forced.
  findings=$(gh_push "$branch" "$target" 2> "$RUNNER_TEMP/push-error") || rc=$?
  case "$rc" in
    0) ;;
    1) stage_fail "The secret scan found what look like secrets in the build's changes, so nothing was pushed. Check the files named here, then retry." \
         "Found: $(paste -sd ',' - <<< "$findings" | sed 's/,/, /g')." ;;
    2) stage_fail "The secret scan couldn't run ($(head -n 1 "$RUNNER_TEMP/push-error")), so nothing was pushed." ;;
    *) stage_fail "GitHub rejected the push to $branch (it was created meanwhile, or a rule blocks it), so nothing was pushed." ;;
  esac

  # The draft pull request: the hub's template, then the state block.
  jq -n --slurpfile context "$BUILD_CONTEXT" --slurpfile gates "$RUNNER_TEMP/gates.json" \
      --slurpfile contract "$RUNNER_TEMP/contract.json" --arg ticket "$TICKET_KEY" \
      --arg version "$(cat "$HUB_DIR/VERSION")" --arg head "$(git rev-parse HEAD)" '
    $context[0] as $c | {schema: 1, ticket: $ticket, generation: 1, hub_version: $version,
      plan: ($c.plan | {attachment, uploaded, sha256, approved_at}), target: $c.target, base: $c.base,
      plan_base: $contract[0].base_commit, heads: [{generation: 1, head: $head, hub_version: $version}],
      risk: $contract[0].governance.risk.level,
      flags: [$contract[0].governance.includes | to_entries[] | select(.value) | .key],
      items: ([$gates[0].decisions | to_entries[] | {id: "D\(.key + 1)", path: .value.path, reason: .value.reason, status: "open"}]
        + [$contract[0].governance.manual_changes | to_entries[] | {id: "C\(.key + 1)", path: .value.path, status: "open"}]),
      totals: $gates[0].totals}' > "$RUNNER_TEMP/state.json"
  url=""
  [ "$publish" != true ] || url=$TICKET_URL
  jq -nr -f "$STAGE_DIR/pr-body.jq" --slurpfile out "$BUILD_OUTPUT" --slurpfile context "$BUILD_CONTEXT" \
      --slurpfile gates "$RUNNER_TEMP/gates.json" --slurpfile contract "$RUNNER_TEMP/contract.json" \
      --slurpfile state "$RUNNER_TEMP/state.json" --arg ticket "$TICKET_KEY" --arg url "$url" --arg run "$RUN_URL" \
    | state_render "$(cat "$RUNNER_TEMP/state.json")" > "$RUNNER_TEMP/pr-body.md"
  title="$TICKET_KEY: build from the approved plan"
  [ "$publish" != true ] || title="$TICKET_KEY: $(jq -r '.fields.summary | .[0:200]' "$RUNNER_TEMP/ticket.json")"
  number=$(gh_pr_open_draft "$branch" "$target" "$title" < "$RUNNER_TEMP/pr-body.md") \
    || stage_fail "The branch $branch was pushed, but GitHub didn't open its pull request. Open a draft pull request from it by hand, or delete the branch and retry."
  gh_label "$number" "$BUILD_LABEL" \
    || stage_fail "Pull request #$number was opened, but its $BUILD_LABEL label couldn't be added. Add it by hand: the hub treats only labelled pull requests as its own."

  # Until the review, CI and hand-off steps exist, a person takes it from here.
  _pr_comment "$number"
  tracker_labels "+$NEEDS_HUMAN_LABEL"
  echo "[$TICKET_KEY]($TICKET_URL): draft pull request #$number opened from $branch, with $(jq '.decisions | length' "$RUNNER_TEMP/gates.json") decision item(s)." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome written
}

# _require_same_plan: stop, changing nothing, if a plan file was uploaded or
# removed since the run started — the approval it built from is stale.
_require_same_plan() {
  local newest
  newest=$(tracker_attachments | jq -r --arg name "$TICKET_KEY-$PLAN_FILE_SUFFIX" \
    '[.[] | select(.filename == $name)] | sort_by(.created) | last | .id // empty') \
    || stage_fail "Couldn't check $TRACKER_NAME for a newer plan file, so nothing was changed."
  [ "$newest" = "$(context .plan.attachment)" ] \
    || stage_fail "The plan files changed while the build was running, so its approval is stale and nothing was changed. Check the newest plan file, then retry."
}

# _pr_comment <number>: the ticket comment linking the draft pull request.
_pr_comment() {
  jq -n -L "$HUB_DIR/lib" --arg number "$1" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$1" \
      --slurpfile gates "$RUNNER_TEMP/gates.json" --slurpfile contract "$RUNNER_TEMP/contract.json" 'include "adf";
    ($gates[0].decisions | length) as $d | ($contract[0].governance.manual_changes | length) as $m
    | doc([para([strong("🔨 Draft pull request opened"), text(" — "), link("#\($number)"; $url),
        text(". Automated review and CI checks come in a later version, so review it on GitHub"
          + (if $d > 0 then "; \($d) decision item(s) need a person" else "" end)
          + (if $m > 0 then "; \($m) manual change(s) to make on the branch" else "" end) + ".")])])' \
    | tracker_comment > /dev/null
}

# step_return: Send the ticket back: the build can't go ahead as approved.
step_return() {
  stage_require_status "$PLAN_APPROVED_STATUS"
  case "$(jq -r '.structured_output.status' "$BUILD_OUTPUT")" in
    needs-clarification) _send_back_questions ;;
    no-change-needed) _no_change_needed ;;
    *) # blocked: Claude's reason goes only on the ticket.
       stage_fail "Claude couldn't build the plan in this environment (a tool missing, or the sandbox refusing something the plan needs), so nothing was changed." \
         "Claude's reason: $(jq -r '.structured_output.reason' "$BUILD_OUTPUT")" ;;
  esac
}

# _send_back_questions: the questions go into a new version of the plan file
# (its "Questions from the build" section) and a comment, and the ticket back
# to Implementation Plan: the answer comes as a plan revision and a new
# approval.
_send_back_questions() {
  local transition plan_file="$RUNNER_TEMP/$TICKET_KEY-$PLAN_FILE_SUFFIX"
  transition=$(stage_transition_id "$PLAN_STATUS")
  _require_same_plan
  jq -Rrs -L "$HUB_DIR/lib" --slurpfile out "$BUILD_OUTPUT" --arg title "$QUESTIONS_SECTION" 'include "markdown";
    md_sections as $sections
    | ([$sections[0]] + [$sections[1:][] | select(heading_key != $title) | "## " + .] | join("\n") | rtrimstr("\n"))
      + "\n\n## \($title)\n\n"
      + ([$out[0].structured_output.questions[] | "- **\(.question)** Why it matters: \(.why)"] | join("\n")) + "\n"' \
    "$RUNNER_TEMP/plan.md" > "$plan_file"
  tracker_attach "$plan_file" > /dev/null
  jq -L "$HUB_DIR/lib" --arg title "$NEEDS_CLARIFICATION_TITLE" --arg message "$NEEDS_CLARIFICATION_MESSAGE" 'include "adf";
    doc([para([strong($title), text(" — flagged by Claude (build).")]),
         para($message),
         bullets([.structured_output.questions[] | [strong(.question), text(" Why it matters: \(.why)")]])])' \
    "$BUILD_OUTPUT" | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_CLARIFICATION_LABEL" "+$NEEDS_HUMAN_LABEL"
  stage_move "$transition" "$PLAN_STATUS"
  echo "[$TICKET_KEY]($TICKET_URL) returned to $PLAN_STATUS as $NEEDS_CLARIFICATION_LABEL." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome "sent back"
}

# _no_change_needed: the code already does what the plan asks — no empty
# commit, no pull request; a person decides.
_no_change_needed() {
  jq -L "$HUB_DIR/lib" 'include "adf";
    doc([para([strong("🔍 No change needed"),
          text(" — Claude found the code already does what the approved plan asks, so nothing was built. A person decides what happens next.")]),
         para([text(.structured_output.reason)])])' \
    "$BUILD_OUTPUT" | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL"
  echo "[$TICKET_KEY]($TICKET_URL): no change needed; flagged for a person." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome "no change needed"
}
