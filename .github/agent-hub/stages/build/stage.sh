# shellcheck shell=bash
# The build stage: turns an approved implementation plan into a draft pull
# request on branch agent-hub/<KEY>, or sends the ticket back with questions.
# Its steps, run by the shared stage workflow (.github/workflows/agent-hub-stage.yml,
# with code-stage on) with the settings, tracker, GitHub library and shared
# libraries already loaded. See docs/workflows/build.md.
#
# This version: start (the exact plan approved, its contract, the branch,
# the declared Node version), the dependencies installed from the lockfile
# and the plan's dependency changes applied (install; dependencies.sh),
# validate and build in one agent pass, the commit and the repository's own
# checks run on it by the hub (verify), the code review (review.sh), the fix
# pass and its check, and verifying the fix (fix.sh), then the gates, the
# secret scan and the draft pull request with its state block (apply). Later
# runs reconcile it (reconcile.sh), wait for CI and hand it off (handoff.sh),
# act on people's item commands (commands.sh) and follow it to Done once
# merged (closed.sh).
#
# The agent can change anything in the checkout — .git included — so no
# later step trusts it: each loads the hub from the workflow's copy, and git
# runs with the repository's metadata as copied before the agent started
# (build_git), taking only the files' content from the checkout.

# The dependency step (the plan's dependency changes, before the agent).
# shellcheck source=stages/build/dependencies.sh
source "$(dirname "${BASH_SOURCE[0]}")/dependencies.sh"
# The code review (after Verify; its findings go to Apply).
# shellcheck source=stages/build/review.sh
source "$(dirname "${BASH_SOURCE[0]}")/review.sh"
# The fix pass and fix check (after the review), and verifying the fix.
# shellcheck source=stages/build/fix.sh
source "$(dirname "${BASH_SOURCE[0]}")/fix.sh"
# An existing pull request: reconciled rather than built again (4c).
# shellcheck source=stages/build/reconcile.sh
source "$(dirname "${BASH_SOURCE[0]}")/reconcile.sh"
# The CI gate and the hand-off (4d-1).
# shellcheck source=stages/build/handoff.sh
source "$(dirname "${BASH_SOURCE[0]}")/handoff.sh"
# A closed pull request: Done, or a comment (step 5a).
# shellcheck source=stages/build/closed.sh
source "$(dirname "${BASH_SOURCE[0]}")/closed.sh"
# People's commands on the items, from the ticket (step 5b).
# shellcheck source=stages/build/commands.sh
source "$(dirname "${BASH_SOURCE[0]}")/commands.sh"

BUILD_CONTEXT="$RUNNER_TEMP/build-context.json"
BUILD_GIT="$RUNNER_TEMP/build-git"
# The agent's result (the runner's AGENT_OUTPUT), for the steps after it.
BUILD_OUTPUT="$RUNNER_TEMP/agent-output.json"

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
  # What woke the run, when not a person's approval: only the hub's own
  # values. (Anyone who can request a run can set it.)
  case "${AGENT_HUB_WAKE:-}" in
    "" | ci | closed | command) ;;
    *) stage_fail "The run was requested with an unknown wake value, so nothing was done." ;;
  esac
  # A hub pull request was closed (agent-hub-pr-closed.yml): Done, or a
  # comment — nothing is built (closed.sh).
  if [ "${AGENT_HUB_WAKE:-}" = closed ]; then build_closed; exit 0; fi
  # A person's /skip or /apply on the ticket (commands.sh): it ends the run,
  # unless an /apply was accepted — then the run carries on as a fix of the
  # requested items.
  [ "${AGENT_HUB_WAKE:-}" != command ] || build_command
  # A new build starts only from Implementation Plan Approved. A run for a
  # ticket already handed off (Ready for Review, or Approved) — the CI gate,
  # an item command, or a person re-running the build to have people's
  # commits checked — reconciles its pull request (checked after _branch).
  # The hub never moves a ticket back into Implementation Plan Approved: its
  # own move there wouldn't be an approval.
  stage_fetch "$PLAN_APPROVED_STATUS" "$READY_FOR_REVIEW_STATUS" "$APPROVED_STATUS" || exit 0
  stage_set_mode new
  # Not for real tickets yet (settings.sh): stop before anything else.
  [ "$BUILD_PREVIEW" = true ] \
    || stage_fail "The build stage is in preview: it runs only where the repository variable AGENT_HUB_BUILD_PREVIEW is true, until its manual test and the runner requirements are done (docs/workflows/build.md, Status). Nothing was built."
  _require_pinned_claude
  _require_limits
  # A Node project builds only with the Node version it declares (the
  # workflow sets it up): the build's result mustn't depend on the runner.
  if toolchain_uses_node && [ -z "$(toolchain_node_file)" ]; then
    stage_fail "The repository is a Node project but doesn't declare its Node version, so the build can't run it the same way every time and nothing was built. Add an .nvmrc (e.g. 22) — or .node-version, or engines.node in package.json — then retry."
  fi

  # The checkout as the workflow made it, and its git metadata kept before
  # any agent runs.
  # (With git's settings that could run a program turned off, and only the
  # repository's own config read: this step holds the credentials.)
  if [ ! -d .git ] || [ -n "$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c core.fsmonitor=false -c core.hooksPath=/dev/null \
       -c core.untrackedCache=false status --porcelain --no-renames)" ]; then
    stage_fail "The checkout isn't a clean git repository, so nothing was built. Re-run the workflow; if it happens again, clean the runner's work folder."
  fi
  rm -rf "$BUILD_GIT" && cp -R .git "$BUILD_GIT"
  _trust_build_git
  build_git
  _snapshot_guidance "$(git rev-parse HEAD)"

  _approved_plan
  # The work order's acceptance criteria, which the build must verify.
  if [ "$(stage_acceptance_criteria)" = 0 ]; then
    stage_fail "The description has no Acceptance Criteria checklist, so there's nothing to verify the build against and nothing was built. Restore the work order's criteria, then approve the plan again."
  fi
  # A plan with only manual changes leaves the build nothing to do.
  if jq -e '(.changes | length) == 0' "$RUNNER_TEMP/contract.json" > /dev/null; then
    _manual_only
    exit 0
  fi
  _branch
  # Past the plan's approval, only an existing pull request is worked on.
  if ! reconciling && [ "$(stage_start_status)" != "$PLAN_APPROVED_STATUS" ]; then
    echo "::notice::$TICKET_KEY is in $(stage_start_status) and has no open pull request of the hub's, so there's nothing to build: a new build starts from $PLAN_APPROVED_STATUS."
    echo "proceed=false" >> "$GITHUB_OUTPUT"
    stage_outcome "no change needed"
    exit 0
  fi
  _committer
  # An existing pull request whose target moved: merged in, before anything
  # else reads the code (reconcile.sh).
  reconciling && _reconcile_sync
  # The agent gets the work order and the approved plan — not the comments,
  # which nobody approved.
  stage_ticket_markdown
  {
    printf '\nApproved implementation plan (the attached %s):\n\n' "$PLAN_FILE_NAME"
    cat "$RUNNER_TEMP/plan.md"
  } >> "$RUNNER_TEMP/ticket.md"
  if reconciling; then
    if applying; then
      stage_progress_comment "⏳ Applying to pull request #$(context .pr)" \
        " — what an approver asked for with /apply ($(context '.apply.sources | length') item(s) or review thread(s)), through the fix pass, verified before it's pushed. Refresh the page to see the result. "
      return
    fi
    if ci_fixing; then
      stage_progress_comment "⏳ Fixing CI on pull request #$(context .pr)" \
        " — required checks failed ($(context '.ci_fix.checks | join(", ")')), so the hub is trying a fix ($(context .ci_fix.attempt) of $BUILD_CI_FIX_ATTEMPTS), verified before it's pushed. Refresh the page to see the result. "
      return
    fi
    stage_progress_comment "⏳ Re-checking pull request #$(context .pr)" " — $(reconcile_why), so it's being verified$(reconcile_reviews && echo " and reviewed") again. Refresh the page to see the result. "
    return
  fi
  stage_progress_comment "⏳ Building" \
    " — implementing the approved plan$(context 'if .plan.by_person then " (a plan file a person uploaded, not the plan stage: the build follows its scope and must-not-touch rules as written)" else "" end'); usually takes 10–30 minutes. Refresh the page to see the result. "
}

# stage_max_cost: the most one build run's Claude passes can cost together
# (lib/stage.sh, stage_run_max_cost): the build, the code review, the fix
# pass and the fix check, each at its configured maximum plus the overshoot
# allowance.
stage_max_cost() {
  # A reconcile run has no build pass, and one that only merged a mechanical
  # drift has no review either: no Claude at all.
  if reconciling; then
    # A CI fix: the fix pass and its check only.
    if ci_fixing || applying; then stage_passes_max_usd "$BUILD_FIX_MAX_BUDGET_USD" "$BUILD_FIX_CHECK_MAX_BUDGET_USD"; return; fi
    reconcile_reviews || { echo 0; return; }
    stage_passes_max_usd "$BUILD_REVIEW_MAX_BUDGET_USD" "$BUILD_FIX_MAX_BUDGET_USD" "$BUILD_FIX_CHECK_MAX_BUDGET_USD"; return
  fi
  stage_passes_max_usd "$CLAUDE_MAX_BUDGET_USD" "$BUILD_REVIEW_MAX_BUDGET_USD" "$BUILD_FIX_MAX_BUDGET_USD" "$BUILD_FIX_CHECK_MAX_BUDGET_USD"
}

# _require_limits: the size and time limits (settings.sh) are whole numbers —
# checked before any Claude usage, since the gates and steps need them.
_require_limits() {
  local limit
  for limit in "MAX_FILES=$BUILD_MAX_FILES" "MAX_LINES=$BUILD_MAX_LINES" "MAX_FILE_LINES=$BUILD_MAX_FILE_LINES"; do
    [[ "${limit#*=}" =~ ^[0-9]+$ ]] \
      || stage_fail "The repository variable AGENT_HUB_BUILD_${limit%%=*} must be a whole number, not '${limit#*=}', so nothing was built."
  done
  [[ "$BUILD_MIN_RELEASE_AGE_DAYS" =~ ^[0-9]+$ ]] \
    || stage_fail "The repository variable AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS must be a whole number of days (0 for none), not '$BUILD_MIN_RELEASE_AGE_DAYS', so nothing was built."
  [[ "$BUILD_ALLOWED_LICENSES" =~ ^[A-Za-z0-9.+-]+(,[A-Za-z0-9.+-]+)*$ ]] \
    || stage_fail "The repository variable AGENT_HUB_BUILD_ALLOWED_LICENSES must be SPDX licence ids separated by commas (e.g. MIT,Apache-2.0), not '$BUILD_ALLOWED_LICENSES', so nothing was built."
  [[ "$BUILD_BASELINE" =~ ^(stop|warn|off)$ ]] \
    || stage_fail "The repository variable AGENT_HUB_BUILD_BASELINE must be stop, warn or off, not '$BUILD_BASELINE', so nothing was built."
  # A time limit of 0 would be none at all.
  for limit in "INSTALL_MINUTES=$BUILD_INSTALL_MINUTES" "CHECK_MINUTES=$BUILD_CHECK_MINUTES"; do
    [[ "${limit#*=}" =~ ^[1-9][0-9]*$ ]] \
      || stage_fail "The repository variable AGENT_HUB_BUILD_${limit%%=*} must be a whole number of minutes, at least 1, not '${limit#*=}', so nothing was built."
  done
}

# _require_pinned_claude: the runner's Claude Code is exactly the pinned
# version (settings.sh) — checked before any Claude usage (--version uses
# none). The pin keeps the version from changing beneath the build; it
# doesn't prove the sandbox works on this runner: that's the sandbox check,
# run by hand on a new runner and after every upgrade (docs/runners.md).
_require_pinned_claude() {
  local installed
  [[ "$CLAUDE_CODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || stage_fail "The build needs an exact Claude Code version, so nothing was built: set the repository variable AGENT_HUB_CLAUDE_CODE_VERSION to the version on the runner (from \`claude --version\`, e.g. 2.1.280) — not 'latest' or empty. See docs/runners.md."
  installed=$(claude --version 2> /dev/null | head -n 1 | cut -d ' ' -f 1) || installed=""
  [ "$installed" = "$CLAUDE_CODE_VERSION" ] \
    || stage_fail "The runner has Claude Code ${installed:-(not found)}, but AGENT_HUB_CLAUDE_CODE_VERSION pins $CLAUDE_CODE_VERSION, so nothing was built. Install the pinned version on the runner, or — after running the sandbox check on the new version — change the variable (docs/runners.md)."
}

# _approved_plan: the plan file people approved, exactly (docs/workflows/build.md,
# "Approval check"): see _approval_problem. Downloads it (plan.md), checks the
# approval again (nothing changed while it downloaded), reads its contract
# (contract.json) and records what was approved (build-context.json).
_approved_plan() {
  local first second problems
  _automation_account
  first=$(_approval_snapshot) \
    || stage_fail "Couldn't read $TICKET_KEY's history and attachments from $TRACKER_NAME to check which plan was approved, so nothing was built."
  _require_approval "$first"
  tracker_attachment_content "$(jq -r '.plans[-1].id' <<< "$first")" > "$RUNNER_TEMP/plan.md" \
    || stage_fail "Couldn't download the approved plan from $TRACKER_NAME, so nothing was built."
  second=$(_approval_snapshot) \
    || stage_fail "Couldn't read $TICKET_KEY's history and attachments from $TRACKER_NAME again, so nothing was built."
  _require_approval "$second"
  [ "$(_approval_key "$first")" = "$(_approval_key "$second")" ] || { _approval_stale; exit 0; }

  jq -Rs -L "$HUB_DIR/lib" -f "$STAGE_DIR/contract.jq" "$RUNNER_TEMP/plan.md" > "$RUNNER_TEMP/contract.json"
  problems=$(jq -r '.problems | join("; ")' "$RUNNER_TEMP/contract.json")
  [ -z "$problems" ] \
    || stage_fail "The approved plan can't be read as a build contract ($problems), so nothing was built. Move the ticket back to $PLAN_STATUS, revise the plan, and approve it again."

  # What was approved; plan.files (every plan file's id) and approved_at are
  # the approval's identity (_approval_key).
  jq --arg sha256 "$(_sha256 "$RUNNER_TEMP/plan.md")" --arg automation "$AUTOMATION_ACCOUNT" '.plans[-1] as $plan | {plan: {
    attachment: $plan.id, uploaded: ($plan.created // ""), uploaded_by: ($plan.author.displayName // ""),
    # A plan file a person uploaded (not the plan stage, as the automation
    # account): the progress comment and the pull request say so.
    by_person: (($plan.author.accountId // "") != $automation),
    sha256: $sha256, approved_at: .history.at, approved_by: .history.by_name, files: [.plans[].id]}}' \
    <<< "$second" > "$BUILD_CONTEXT"
}

# _approval_snapshot: the approval and the plan files, read together —
# {history (tracker_history_since), plans: the plan files, oldest first}.
_approval_snapshot() {
  local history attachments
  history=$(tracker_history_since "$PLAN_APPROVED_STATUS") || return 1
  attachments=$(tracker_attachments) || return 1
  jq -nc --argjson history "$history" --argjson attachments "$attachments" --arg name "$PLAN_FILE_NAME" \
    '{history: $history, plans: ([$attachments[] | select(.filename == $name)] | sort_by(.created))}'
}

# _approval_problem <snapshot>: why the snapshot isn't a person's approval of
# the newest plan file, as "<kind> <reason>" — kind "stale" (approve again)
# or "fail" (nothing to approve, or not a person's approval) — or nothing if
# it is one. The approval is the ticket's last move to Implementation Plan
# Approved: after it, no plan file may have been added or removed and the
# work order (the description) not edited, and the newest plan file must
# predate it.
_approval_problem() {
  local snapshot=$1 created approved
  jq -e '.history.entered' <<< "$snapshot" > /dev/null \
    || { echo "fail $TICKET_KEY's history shows no move to $PLAN_APPROVED_STATUS, so there's no approval to build from and nothing was built. A person approves the plan by moving the ticket there."; return; }
  # The automation account can't approve (docs/jira.md); a move it made
  # anyway isn't a person's approval.
  [ "$(jq -r '.history.by' <<< "$snapshot")" != "$AUTOMATION_ACCOUNT" ] \
    || { echo "fail The move to $PLAN_APPROVED_STATUS was made by the automation account, not a person, so it isn't an approval and nothing was built. A person approves the plan by moving the ticket there."; return; }
  # With an approvers group set, the person must be in it.
  local rc=0
  stage_is_approver "$(jq -r '.history.by' <<< "$snapshot")" || rc=$?
  case "$rc" in
    1) echo "fail The move to $PLAN_APPROVED_STATUS was made by someone who isn't in $APPROVERS_GROUP, so it isn't an approval and nothing was built. One of its members approves the plan by moving the ticket there."; return ;;
    2) echo "fail Couldn't check that the person who moved the ticket to $PLAN_APPROVED_STATUS is in $APPROVERS_GROUP, so nothing was built (the Jira service account needs Browse users and groups)."; return ;;
  esac
  [ "$(jq '.plans | length' <<< "$snapshot")" -gt 0 ] \
    || { echo "fail There's no $PLAN_FILE_NAME on the ticket to build from, so nothing was built. Write the plan (move the ticket to $WORK_ORDER_APPROVED_STATUS), then approve it."; return; }
  # The newest plan file must predate the approval; times that can't be read
  # can't show that, so they count as stale too.
  created=$(jq -r '.plans[-1].created // ""' <<< "$snapshot") approved=$(jq -r '.history.at // ""' <<< "$snapshot")
  _later "$approved" "$created" || { echo "stale"; return; }
  # A plan file added or removed, or the work order edited, since — by
  # anyone except the automation account, whose only edit after an approval
  # is the build's own (the description's Pull Request section, after it
  # opens the pull request), which every later run on the ticket would
  # otherwise take for a change to the work order.
  if jq -e --arg name "$PLAN_FILE_NAME" --arg automation "$AUTOMATION_ACCOUNT" 'any(.history.changes[];
       (.kind == "attachment" and .file == $name) or (.kind == "description" and .author != $automation))' <<< "$snapshot" > /dev/null; then
    echo "stale"
  fi
}

# _automation_account: the tracker's automation account (AUTOMATION_ACCOUNT),
# looked up once per step; the run stops if it can't be identified.
_automation_account() {
  AUTOMATION_ACCOUNT=$(tracker_account_id) && [ -n "$AUTOMATION_ACCOUNT" ] && [ "$AUTOMATION_ACCOUNT" != null ] \
    || stage_fail "Couldn't identify $TRACKER_NAME's automation account to check who approved the plan, so nothing was changed."
}

# _require_approval <snapshot>: continue only with a valid approval —
# otherwise fail, or send the ticket back to be approved again.
_require_approval() {
  local problem
  problem=$(_approval_problem "$1")
  case "$problem" in
    "") ;;
    stale) _approval_stale; exit 0 ;;
    *) stage_fail "${problem#fail }" ;;
  esac
}

# _approval_key <snapshot>: the approval's identity — when it was made, and
# the set of plan files — to compare with another snapshot's, or with what
# the run recorded (build-context.json).
_approval_key() { jq -c '[.history.at, [.plans[].id]]' <<< "$1"; }

# _later <time> <other time>: whether the first is later than the second —
# 0 later, 1 not, 2 either can't be read (callers treat 2 as failure). ISO
# 8601 with a Z or ±hh[:]mm offset (Jira's and GitHub's formats); fractions
# of a second count.
_later() {
  local result
  result=$(jq -nr --arg a "$1" --arg b "$2" '
    def instant: (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
        // error("unreadable time"))
      | (.d + "Z" | fromdateiso8601) + ("0\(.f // "")" | tonumber)
        - (if .z == "Z" then 0 else ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end) end);
    ($a | instant) > ($b | instant)' 2> /dev/null) || return 2
  [ "$result" = true ]
}

# _approval_stale: a plan file was uploaded or deleted, or the work order
# edited, after the approval, so what was approved may not be what's on the
# ticket. Back to Implementation Plan for a person to check and approve again.
_approval_stale() {
  # shellcheck disable=SC1112 # curly apostrophe intended
  stage_send_back_stale "$PLAN_STATUS" "Plan changed after approval" \
    "a plan file was uploaded or removed, or the work order edited, after the plan was approved, so nothing was built from it. It’s back in $PLAN_STATUS: check the newest plan file and the work order, then move the ticket to $PLAN_APPROVED_STATUS again." \
    "the plan files or the work order changed after its approval."
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
  local repo visibility target head base branch status publish=false
  repo=$(gh_api GET "/repos/$GITHUB_REPOSITORY") && visibility=$(gh_repo_visibility "$repo") \
    || stage_fail "Couldn't read the repository from GitHub, so nothing was built. Check the AGENT_HUB_GITHUB_TOKEN secret (docs/setup.md), then retry."
  target=${BUILD_TARGET_BRANCH:-$(jq -r '.default_branch // empty' <<< "$repo")}
  [ -n "$target" ] || stage_fail "Couldn't read the repository's default branch from GitHub, so nothing was built."
  head=$(gh_branch_head "$target") || stage_fail "Couldn't read the target branch $target from GitHub, so nothing was built."
  base=$(git rev-parse HEAD)
  [ "$head" = "$base" ] \
    || stage_fail "The checkout isn't the head of the target branch $target: the branch moved since the run started, or the workflow checked out another one (AGENT_HUB_BUILD_TARGET_BRANCH). Nothing was built."
  branch="$BUILD_BRANCH_PREFIX$TICKET_KEY"
  status=$(gh_branch_status "$branch" "$BUILD_LABEL") \
    || stage_fail "Couldn't check GitHub for an existing $branch, so nothing was built."
  # Each says what's in the way, and — instead of the usual "approve it
  # again or re-run", which would stop here again — what a person does first.
  case "$status" in
    absent) ;;
    # The hub's own open pull request: reconciled (reconcile.sh), below.
    "open "*) ;;
    "foreign "*) stage_retry "a person decides: close pull request #${status#foreign } and delete $branch, then approve the plan again."
      stage_fail "Pull request #${status#foreign } from $branch wasn't opened by the hub (it has no $BUILD_LABEL label), so nothing was built." ;;
    orphan) stage_retry "a person decides: delete $branch, then approve the plan again."
      stage_fail "The branch $branch exists with no pull request (a failed earlier build?), so nothing was built." ;;
    "merged "*) stage_retry "nothing to retry: the plan was built and merged. A change needs a new ticket."
      stage_fail "Pull request #${status#merged } from $branch was already merged, so nothing was built." ;;
    # Closed unmerged: a person decides. Closing it and deleting the branch
    # only say what state it's in (a bot or a branch rule could do either);
    # building again needs a person's new approval of the plan after it
    # was closed.
    "closed "*)
      head=$(gh_branch_head "$branch") || stage_fail "Couldn't check GitHub for $branch, so nothing was built."
      if [ -n "$head" ]; then
        stage_retry "a person decides: delete $branch, then approve the plan again."
        stage_fail "Pull request #${status#closed } from $branch was closed unmerged and its branch is still there, so nothing was built."
      fi
      if ! _approved_after_close "$branch"; then
        stage_retry "approve the plan again (move the ticket back to $PLAN_STATUS, then to $PLAN_APPROVED_STATUS)."
        stage_fail "Pull request #${status#closed } from $branch was closed unmerged after the plan's latest approval, so that approval isn't for a new build and nothing was built."
      fi ;;
    "deleted "*) stage_retry "a person decides: close pull request #${status#deleted }, then approve the plan again."
      stage_fail "Pull request #${status#deleted } is open but its branch $branch is gone, so nothing was built." ;;
    *) stage_fail "Couldn't tell what state $branch is in, so nothing was built." ;;
  esac
  gh_publish_ticket_text "$visibility" "$PUBLISH_TICKET_CONTENT" && publish=true
  jq --arg target "$target" --arg base "$base" --arg branch "$branch" \
    --argjson publish "$publish" '. + {target: $target, base: $base, branch: $branch, publish: $publish}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
  case "$status" in "open "*) _reconcile_start "${status#open }" ;; esac
}

# _committer: the account the token belongs to (the machine user), for the
# commit the verify step makes (it has no token): its login and its GitHub
# noreply address (<id>+<login>@users.noreply.github.com), which GitHub
# attributes to the account — from /user, so the token needs no email
# permission. Added to build-context.json.
_committer() {
  local user
  user=$(gh_api GET /user) || stage_fail "Couldn't read the machine user from GitHub, so nothing was built."
  jq --argjson user "$user" '. + {committer: {name: $user.login, email: "\($user.id)+\($user.login)@users.noreply.github.com"}}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
}

# _approved_after_close <branch>: whether the plan's latest approval came
# after the branch's pull request was closed. Fails (closed) if either time
# can't be read.
_approved_after_close() {
  local closed
  closed=$(gh_pr_find "$1" | jq -r '.closed_at // empty') || return 1
  [ -n "$closed" ] || return 1
  _later "$(context .plan.approved_at)" "$closed"
}

# step_agent: The agent: validate the plan against the code, then build it.
step_agent() {
  if reconciling; then reconcile_agent; return; fi
  agent_run "Build the approved implementation plan for this ticket." build
  agent_check build needs-clarification questions no-change-needed reason blocked reason

  # A build must say how each acceptance criterion is verified, word for
  # word. The log names positions, never ticket text.
  if [ "$(jq -r '.structured_output.status' "$AGENT_OUTPUT")" = ready ]; then
    MISSING=$(stage_uncovered_criteria "$(jq -c '[.structured_output.build.verification[].criterion]' "$AGENT_OUTPUT")")
    if [ -n "$MISSING" ]; then
      stage_fail "The build didn't say how acceptance criteria $MISSING (by position in the work order) are verified, so nothing was pushed."
    fi
  fi
  agent_summary "Build"
}

# step_install: Install the repository's dependencies, from its lockfile, in the sandbox.
step_install() {
  local rc folder where log="$RUNNER_TEMP/install.log" allowed unexpected
  # The plan's dependency changes first (dependencies.sh), so the install
  # below installs them too — not when reconciling: the pull request has them.
  if reconciling; then echo '{}' > "$RUNNER_TEMP/dependencies.json"; else build_dependency_step; fi
  while IFS= read -r folder; do
    [ "$folder" = . ] && where="" || where=" in $folder"
    rc=0
    _install_dependencies "$PWD/$folder" "$log" || rc=$?
    case "$rc" in
      0) ;;
      2) stage_fail "The repository has dependencies$where but no lockfile (package-lock.json, pnpm-lock.yaml or yarn.lock), so they can't be installed the same way every time and nothing was built. Commit a lockfile, then retry." ;;
      3) stage_fail "The repository's .npmrc$where points at a private registry or holds credentials, which the build doesn't support yet, so nothing was built." ;;
      124) stage_fail "Installing the dependencies$where took longer than $BUILD_INSTALL_MINUTES minutes, so nothing was built. Raise AGENT_HUB_BUILD_INSTALL_MINUTES if it's expected, then retry." ;;
      125) stage_fail "The sandbox couldn't start for the install ($(tail -n 1 "$log" 2> /dev/null || true)), so nothing was built." ;;
      *) stage_fail "Installing the dependencies$where failed (exit $rc), so nothing was built. The install's output is on the runner; retry, and check the lockfile if it fails again." ;;
    esac
  done < <(build_install_folders "$(context .base)")
  # The install changes nothing tracked and leaves nothing untracked — apart
  # from the manifests and lockfiles of the plan's dependency changes: the
  # agent starts from the repository exactly as it is, plus those.
  # (Through the hub's own copy of the git metadata — whose HEAD, when
  # reconciling, is the pull request's head the fetch step checked out.)
  build_git
  allowed=$(jq -r '.governance.dependency_changes // [] | [.[].folder] | unique[]
    | if . == "." then "package.json", "package-lock.json" else "\(.)/package.json", "\(.)/package-lock.json" end' "$RUNNER_TEMP/contract.json")
  unexpected=$(git status --porcelain | while IFS= read -r line; do
    [ "${line:0:3}" = " M " ] && [ -n "$allowed" ] && grep -qxF -- "${line:3}" <<< "$allowed" && continue
    echo "$line"; done)
  [ -z "$unexpected" ] \
    || stage_fail "Installing the dependencies changed files in the repository (a lockfile rewritten, or installed files not ignored — e.g. node_modules/ missing from .gitignore), so nothing was built."
  reconciling || build_dependency_checks

  # A rehearsal of the verify step on the base commit, before Claude runs (and
  # is paid for): the copy, its install, the list of checks and the sandbox
  # runtime. Whatever would stop the verify step for the environment's sake
  # stops the build here instead; after the agent only the checks can fail.
  build_git
  _verify_copy "$(context .base)" "$RUNNER_TEMP/verify" \
    || stage_fail "Couldn't make a copy of the repository to run its checks in, so nothing was built." "Git said: $(_git_said)"
  _checks "$(context .base)" > /dev/null || stage_fail "$(_checks_invalid "nothing was built")"
  while IFS= read -r folder; do
    # (The plan's dependency changes aren't on the base commit: its folders
    # install as they were.)
    [ -d "$RUNNER_TEMP/verify/$folder" ] || continue
    rc=0
    _install_dependencies "$RUNNER_TEMP/verify/$folder" "$RUNNER_TEMP/verify-install.log" > /dev/null || rc=$?
    [ "$rc" = 0 ] || stage_fail "Installing the dependencies in a copy of the repository for its checks failed (exit $rc), so nothing was built."
  done < <(build_install_folders "$(context .base)")
  sandbox_install > /dev/null 2> "$RUNNER_TEMP/sandbox-install.log" \
    || stage_fail "The sandbox runtime the checks run in couldn't be installed ($(tail -n 1 "$RUNNER_TEMP/sandbox-install.log")), so nothing was built."
  # And it runs a command, as the checks will: the toolchain starting in the
  # sandbox (Node, when there is one) — the install above may have run none.
  rc=0
  sandbox_run check "$RUNNER_TEMP/verify" 1 "$RUNNER_TEMP/sandbox-check.log" "if command -v node > /dev/null; then node --version; fi" || rc=$?
  [ "$rc" = 0 ] || stage_fail "The sandbox the checks run in can't run commands on this runner (exit $rc), so nothing was built. Run .github/agent-hub/scripts/check-sandbox.sh on the runner, and see docs/runners.md." \
    "Its output ended: $(grep -v '^[[:space:]]*$' "$RUNNER_TEMP/sandbox-check.log" | tail -n 3 | cut -c1-300 | paste -sd ' ' - || true)"
  _baseline
}

# _baseline: the repository's checks on the base commit, before the agent
# (AGENT_HUB_BUILD_BASELINE, docs/workflows/build.md, "Baseline"). A check
# that already fails there would fail the verify step after Claude has run,
# so — "stop", the default — nothing is built; "warn" goes ahead (a plan that
# fixes a failing check); "off" skips it. A failing check runs once more
# first, in case it's flaky. Results in baseline.json.
_baseline() {
  local results failing
  [ "$BUILD_BASELINE" != off ] || return 0
  _checks "$(context .base)" > "$RUNNER_TEMP/baseline-checks.tsv"
  results=$(_run_checks "$RUNNER_TEMP/verify" "$RUNNER_TEMP/baseline-checks.tsv" "$RUNNER_TEMP/baseline" 2 "Baseline check")
  jq -n --argjson checks "$results" '{checks: $checks}' > "$RUNNER_TEMP/baseline.json"
  failing=$(jq -r '[.checks[] | select(.result != "passed") | "\(.name) (\(.result))"] | join(", ")' "$RUNNER_TEMP/baseline.json")
  [ -n "$failing" ] || return 0
  if [ "$BUILD_BASELINE" = warn ]; then
    echo "::warning::The repository's checks already fail on $(context .target) before the agent runs: $failing. Building anyway (AGENT_HUB_BUILD_BASELINE=warn); they must pass on the build's commit for anything to be pushed."
    return 0
  fi
  stage_fail "The repository's checks already fail on $(context .target), before the agent: $failing. The build would fail them too, so nothing was built and Claude wasn't used; the output is in the next comment. Fix them first. If a check needs the network or a service, which the sandbox doesn't have, list the checks that can run offline in build/checks.json (docs/extending.md). For a plan that fixes a failing check, set AGENT_HUB_BUILD_BASELINE to warn."
}

# _verify_copy <commit> <folder>: a clean copy of the commit from the
# metadata copied before the agent ran (build_git). The workflow's checkout
# is sparse and partial — the hub's own test data left out, and with it
# those files' content — so the copy takes the same sparse patterns, or its
# checkout would need content that was never fetched. Git's messages go to
# verify-clone.log (_git_said).
_verify_copy() {
  rm -rf "$2"
  (
    unset GIT_DIR GIT_WORK_TREE
    git clone -q --no-hardlinks --no-checkout "$BUILD_GIT" "$2" || exit 1
    if [ "$(git --git-dir="$BUILD_GIT" config --bool core.sparseCheckout)" = true ]; then
      git -C "$2" config core.sparseCheckout true
      cp "$BUILD_GIT/info/sparse-checkout" "$2/.git/info/sparse-checkout" || exit 1
    fi
    git -C "$2" checkout -q --detach "$1"
  ) 2> "$RUNNER_TEMP/verify-clone.log"
}

# build_clean_copy <commit> <folder>: a clean copy of exactly <commit> — not
# the checkout an agent may have left files in (ignored ones too, like
# node_modules) — with its dependencies installed from the lockfile in the
# sandbox, as the verify step's. For the passes that judge a commit (the code
# review, the fix check): they work there, and their sandbox keeps them from
# writing to it. Fails, with a reason on standard error, if it can't be made.
build_clean_copy() {
  local folder rc
  (build_git && _verify_copy "$1" "$2") || { echo "a copy of the commit couldn't be made"; return 1; } >&2
  while IFS= read -r folder; do
    [ -d "$2/$folder" ] || continue
    rc=0
    _install_dependencies "$2/$folder" "$RUNNER_TEMP/clean-copy-install.log" > /dev/null || rc=$?
    [ "$rc" = 0 ] || { echo "installing its dependencies failed (exit $rc)" >&2; return 1; }
  done < <(build_git && build_install_folders "$(context .base)")
}

# _git_said: the end of git's errors from _verify_copy, for the ticket only
# (it can name files; the run log can be public).
_git_said() { grep -E '^(fatal|error):' "$RUNNER_TEMP/verify-clone.log" | tail -n 3 | cut -c1-300 | paste -sd ' ' - || true; }

# _checks_invalid <what happened>: the message for a checks.json that isn't valid.
_checks_invalid() { echo "The repository's list of checks (build/checks.json in its extensions) isn't valid, so $1. It's {\"checks\": [{\"name\": …, \"command\": …}]} (docs/extending.md)."; }

# _install_dependencies <folder> <log>: the frozen install its lockfile asks
# for, in the sandbox (the registries only), or nothing for a repository
# without package.json or dependencies. 0 done, 2 dependencies but no
# lockfile, 3 an unsupported registry, otherwise the install's exit code
# (sandbox_run: 124 out of time, 125 no sandbox).
_install_dependencies() {
  local folder=$1 log=$2 command
  [ -f "$folder/package.json" ] || { echo "No package.json: nothing to install."; : > "$log"; return 0; }
  # Credentials or another registry would need secrets the sandbox doesn't
  # pass, and a registry it doesn't allow.
  if [ -f "$folder/.npmrc" ] && grep -qiE '(_auth|_authToken|_password|^\s*registry\s*=|:registry\s*=)' "$folder/.npmrc"; then
    return 3
  fi
  if [ -f "$folder/package-lock.json" ] || [ -f "$folder/npm-shrinkwrap.json" ]; then command="npm ci --no-audit --no-fund"
  elif [ -f "$folder/pnpm-lock.yaml" ]; then command="corepack pnpm install --frozen-lockfile"
  elif [ -f "$folder/yarn.lock" ]; then
    # Yarn 2+ (a .yarnrc.yml, or packageManager yarn@2+) or classic Yarn.
    if [ -f "$folder/.yarnrc.yml" ] || jq -e '.packageManager // "" | test("^yarn@[2-9]")' "$folder/package.json" > /dev/null 2>&1; then
      command="corepack yarn install --immutable"
    else command="corepack yarn install --frozen-lockfile"; fi
  elif jq -e '[.dependencies, .devDependencies, .optionalDependencies] | map(. // {} | length) | add > 0' "$folder/package.json" > /dev/null 2>&1; then
    return 2
  else echo "No dependencies: nothing to install."; : > "$log"; return 0
  fi
  echo "Installing the dependencies: $command"
  sandbox_run install "$folder" "$BUILD_INSTALL_MINUTES" "$log" "$command"
}

# step_verify: Commit the agent's changes and run the repository's checks on exactly that commit, in the sandbox.
step_verify() {
  local base publish message results
  if reconciling; then reconcile_verify; return; fi
  build_git
  base=$(context .base) publish=$(context .publish)
  # A hard link would pull in a file from elsewhere on the runner that the
  # sandbox kept the agent from reading (it can't create one today: this is
  # a second line), so a file with more than one link is never committed.
  _refuse_hard_links
  # Commit everything the agent left in the checkout, as the machine user.
  git add -A
  if git diff --cached --quiet; then
    stage_fail "Claude reported the build finished but changed no files, so there's nothing to push."
  fi
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  GIT_AUTHOR_NAME=$(context .committer.name) GIT_AUTHOR_EMAIL=$(context .committer.email)
  GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
  # Claude's message comes from the ticket, so a public repository gets it
  # only if ticket content may be published; trailers in it (Co-authored-by
  # and the like) would attribute the commit to someone, so they're dropped.
  if [ "$publish" = true ]; then
    message=$(jq -r '.structured_output.build.commit_message' "$BUILD_OUTPUT" \
      | grep -viE '^(co-authored-by|signed-off-by|reviewed-by|acked-by|tested-by|refs):' || true)
  else message="Build $TICKET_KEY from its approved implementation plan"; fi
  printf '%s\n\nRefs: %s\n' "$message" "$TICKET_KEY" | git commit -q -F -

  # (The install step rehearsed all of this on the base commit, before the
  # agent ran.)
  _check_commit "$base" || stage_fail "$(cat "$RUNNER_TEMP/check-commit-error")"
  results=$(jq -c '.checks' "$RUNNER_TEMP/check-commit.json")
  [ "$results" != "[]" ] || echo "The repository declares no checks (no test, lint, typecheck or build script)."
  cp "$RUNNER_TEMP/check-commit.json" "$RUNNER_TEMP/verify.json"
  if jq -e 'any(.checks[]; .result != "passed")' "$RUNNER_TEMP/verify.json" > /dev/null; then
    stage_fail "The repository's checks failed when the hub ran them: $(jq -r '[.checks[] | select(.result != "passed") | "\(.name) (\(.result))"] | join(", ")' "$RUNNER_TEMP/verify.json"). Nothing was pushed; the output is in the next comment."
  fi
}

# _check_commit <base>: the repository's checks on HEAD — a clean copy of
# exactly that commit (not the checkout, which something the agent left
# running could still change), its dependencies installed the same way —
# into check-commit.json ({head, checks}); the checks' output in checks/.
# Fails, with the reason in check-commit-error, if it can't run them.
_check_commit() {
  local clone="$RUNNER_TEMP/verify" folder rc results
  rm -rf "$clone" "$RUNNER_TEMP/checks"
  _verify_copy "$(git rev-parse HEAD)" "$clone" \
    || { echo "Couldn't make a copy of the build's commit to check, so nothing was pushed. Git said: $(_git_said)" > "$RUNNER_TEMP/check-commit-error"; return 1; }
  while IFS= read -r folder; do
    [ -d "$clone/$folder" ] || continue
    rc=0
    _install_dependencies "$clone/$folder" "$RUNNER_TEMP/verify-install.log" > /dev/null || rc=$?
    [ "$rc" = 0 ] || { echo "Installing the dependencies for the checks failed (exit $rc), so nothing was pushed." > "$RUNNER_TEMP/check-commit-error"; return 1; }
  done < <(build_install_folders "$1")
  mkdir -p "$RUNNER_TEMP/checks"
  _checks "$1" > "$RUNNER_TEMP/checks.tsv" || { _checks_invalid "nothing was pushed" > "$RUNNER_TEMP/check-commit-error"; return 1; }
  results=$(_run_checks "$clone" "$RUNNER_TEMP/checks.tsv" "$RUNNER_TEMP/checks" 1 Check)
  jq -n --argjson checks "$results" --arg head "$(git rev-parse HEAD)" '{head: $head, checks: $checks}' > "$RUNNER_TEMP/check-commit.json"
}

# _run_checks <folder> <checks.tsv> <log folder> <tries> <label>: run each check
# (_checks' "name<TAB>command" lines) in <folder>, in the sandbox with no
# network, each with its time limit; prints the results as a JSON array
# ({n, name, command, result: passed | failed | timed out, exit, seconds}).
# With 2 tries a failing check runs once more (a flaky test), and passes if
# either run does. The run log gets "<label> <name>: <result>" only:
# names and commands come from the repository's own files (as they were
# before the agent ran), and their output can quote anything.
_run_checks() {
  local folder=$1 list=$2 logs=$3 tries=$4 label=$5 n=0 name command started seconds rc result try results="[]"
  mkdir -p "$logs"
  while IFS=$'\t' read -r name command; do
    n=$((n + 1))
    for ((try = 1; try <= tries; try++)); do
      started=$(date +%s) rc=0
      sandbox_run check "$folder" "$BUILD_CHECK_MINUTES" "$logs/$n.log" "$command" < /dev/null || rc=$?
      seconds=$(($(date +%s) - started))
      [ "$rc" != 0 ] || break
    done
    case "$rc" in 0) result=passed ;; 124) result="timed out" ;; *) result=failed ;; esac
    echo "$label $name: $result (${seconds}s)" >&2
    results=$(jq -c --arg name "$name" --arg command "$command" --arg result "$result" --argjson exit "$rc" \
      --argjson seconds "$seconds" --argjson n "$n" \
      '. + [{n: $n, name: $name, command: $command, result: $result, exit: $exit, seconds: $seconds}]' <<< "$results")
  done < "$list"
  echo "$results"
}

# _checks <base commit>: the repository's checks, one "name<TAB>command" per
# line, as the repository was before the agent ran (so a build can't change
# which checks judge it): its build/checks.json extension if there is one
# (docs/extending.md), otherwise the package.json scripts named test, lint,
# typecheck (or type-check) and build, run with its package manager. Fails
# if checks.json isn't valid.
_checks() {
  local listed runner=npm
  if listed=$(git show "$1:$EXTENSIONS_DIR/build/checks.json" 2> /dev/null); then
    build_install_list_valid <<< "$listed" || return 1
    build_checks_list <<< "$listed"
    return
  fi
  git show "$1:package.json" > "$RUNNER_TEMP/base-package.json" 2> /dev/null || return 0
  if git cat-file -e "$1:pnpm-lock.yaml" 2> /dev/null; then runner="corepack pnpm"
  elif git cat-file -e "$1:yarn.lock" 2> /dev/null; then runner="corepack yarn"; fi
  jq -r --arg runner "$runner" '.scripts // {} | ["test", "lint", "typecheck", "type-check", "build"] as $names
    | [$names[] as $n | select(has($n)) | $n] | .[] | "\(.)\t\($runner) run \(.)"' "$RUNNER_TEMP/base-package.json"
}

# build_checks_list < checks.json: its checks, one "name<TAB>command" per
# line (none for an empty list) — or a failure if it isn't
# {"checks": [{"name": …, "command": …}, …]} with each a non-empty string
# without tabs or line breaks.
build_checks_list() {
  local listed
  listed=$(cat)
  jq -er '.checks | if type == "array" and all(.[]; (.name | type == "string" and length > 0)
      and (.command | type == "string" and length > 0) and ((.name + .command) | test("[\t\n]") | not))
    then .[] | "\(.name)\t\(.command)" else error("invalid") end' <<< "$listed" 2> /dev/null \
    || [ "$(jq -c '.checks' <<< "$listed" 2> /dev/null)" = "[]" ]
}

# stage_failure_details: when the checks failed, a comment with each failing
# check's command, result and the end of its output — on the ticket only
# (it's private; the run log may not be).
stage_failure_details() {
  local results logs title before="[]"
  _failed() { [ -s "$1" ] && jq -e 'any(.checks[]; .result != "passed")' "$1" > /dev/null; }
  # shellcheck disable=SC1112 # curly apostrophes intended
  if _failed "$RUNNER_TEMP/verify.json"; then
    results="$RUNNER_TEMP/verify.json" logs="$RUNNER_TEMP/checks"
    title=" — the hub ran the repository’s checks on the build’s commit, in the sandbox (no network), and these didn’t pass, so nothing was pushed:"
    [ ! -s "$RUNNER_TEMP/baseline.json" ] \
      || before=$(jq -c '[.checks[] | select(.result != "passed") | .name]' "$RUNNER_TEMP/baseline.json")
  elif _failed "$RUNNER_TEMP/baseline.json" && [ "$BUILD_BASELINE" = stop ]; then
    results="$RUNNER_TEMP/baseline.json" logs="$RUNNER_TEMP/baseline"
    title=" — the hub ran the repository’s checks on the base commit before the agent, in the sandbox (no network), and these already fail (each run twice), so nothing was built:"
  else return 0; fi
  jq -n -L "$HUB_DIR/lib" --slurpfile results "$results" --arg title "$title" --argjson before "$before" --rawfile outputs <(
      jq -r '.checks[] | select(.result != "passed") | .n' "$results" | while read -r n; do
        tail -n 40 "$logs/$n.log" 2> /dev/null | cut -c1-300 | jq -Rs . ; done | jq -s .) 'include "adf";
    ($outputs | fromjson) as $logs
    | [$results[0].checks[] | select(.result != "passed")] as $failed
    | doc([para([strong("🧪 Checks that failed"), text($title)])]
      + [$failed | to_entries[] | .key as $i | .value
         | para([code(.command), text(" — \(.result) (exit \(.exit), \(.seconds)s)"
             + (if (.name | IN($before[])) then "; it also failed before the agent ran" else "" end)
             + ". The end of its output:")]),
           {type: "codeBlock", attrs: {}, content: (if ($logs[$i] // "") == "" then [] else [text($logs[$i])] end)}])' \
    | tracker_comment > /dev/null
}

# step_apply: Check and push the verified build, and open its draft pull request.
step_apply() {
  local base branch target publish refused findings rc=0 number title url reviewed
  if reconciling; then reconcile_apply; return; fi
  stage_require_status "$PLAN_APPROVED_STATUS"
  build_git
  _require_same_plan
  base=$(context .base) branch=$(context .branch) target=$(context .target) publish=$(context .publish)
  # The dependency step's result (an empty one when the plan had no
  # dependency changes), for the pull request and the report.
  [ -s "$RUNNER_TEMP/dependencies.json" ] || echo '{}' > "$RUNNER_TEMP/dependencies.json"
  # How the agent reached Claude (agent_access), for the cost line.
  [ -s "$RUNNER_TEMP/agent-access.json" ] || echo '{}' > "$RUNNER_TEMP/agent-access.json"
  # A fix that didn't finish verifying is dropped first (fix.sh).
  _settle_fix
  # Only the commit the checks passed on is pushed.
  [ "$(git rev-parse HEAD)" = "$(jq -r '.head' "$RUNNER_TEMP/verify.json" 2> /dev/null)" ] \
    || stage_fail "The build's commit isn't the one the checks passed on, so nothing was pushed."

  # The gates, on the commit. Refused files stop the push; decision items
  # go to the pull request for a person.
  # shellcheck source=stages/build/gates.sh
  source "$STAGE_DIR/gates.sh"
  # Nothing is pushed unless the gates produced a complete result.
  build_gates "$base" "$RUNNER_TEMP/contract.json" > "$RUNNER_TEMP/gates.json" 2> "$RUNNER_TEMP/gates-error" \
    && jq -e '(.files | type == "array") and (.refused | type == "array") and (.decisions | type == "array")
         and (.totals.files | type == "number") and (.files | length) == .totals.files' "$RUNNER_TEMP/gates.json" > /dev/null 2>&1 \
    || stage_fail "The build's changes couldn't be checked ($(head -n 1 "$RUNNER_TEMP/gates-error" 2> /dev/null || true)), so nothing was pushed."
  refused=$(jq '.refused | length' "$RUNNER_TEMP/gates.json")
  if [ "$refused" -gt 0 ]; then
    # The paths come from Claude's changes, so they go only on the ticket.
    stage_fail "The build changed $refused file$([ "$refused" = 1 ] || echo s) the hub never pushes ($(jq -r '[.refused[].reason] | unique | join("; ")' "$RUNNER_TEMP/gates.json")), so nothing was pushed. If the plan needs them, they're manual changes for a person." \
      "Files: $(jq -r '[.refused[].path] | join(", ")' "$RUNNER_TEMP/gates.json")."
  fi

  # The secret scan covers everything the push sends; then the push, never forced.
  # The branch was absent when the run started; one created meanwhile (even
  # at the same commit) isn't the hub's to push to.
  findings=$(gh_push "$branch" "$target" --new 2> "$RUNNER_TEMP/push-error") || rc=$?
  case "$rc" in
    0) ;;
    1) stage_fail "The secret scan found what look like secrets in the build's changes, so nothing was pushed. Check the files named here, then retry." \
         "Found: $(paste -sd ',' - <<< "$findings" | sed 's/,/, /g')." ;;
    2) stage_fail "The secret scan couldn't run ($(head -n 1 "$RUNNER_TEMP/push-error")), so nothing was pushed." ;;
    *) stage_fail "GitHub rejected the push to $branch (it was created meanwhile, or a rule blocks it), so nothing was pushed." ;;
  esac

  # The code review's result (review.sh). None — the step failed or hit its
  # time limit — or one for another commit is a review that didn't finish.
  # A kept fix sits on top of the commit the review saw.
  reviewed=$(git rev-parse HEAD)
  [ "$(jq -r '.status' "$FIX_RESULT")" != kept ] || reviewed=$(jq -r '.before' "$FIX_RESULT")
  if [ ! -s "$CODE_REVIEW" ] || [ "$(jq -r '.head' "$CODE_REVIEW" 2> /dev/null)" != "$reviewed" ]; then
    # shellcheck disable=SC1112 # curly apostrophe intended
    jq -n --arg head "$(git rev-parse HEAD)" \
      '{status: "incomplete", head: $head, reason: "it didn’t run to the end (an error, or its time limit)", findings: []}' > "$CODE_REVIEW"
  fi

  # The draft pull request: the hub's template, then the state block. Its
  # heads say what each commit is and which check verified exactly it
  # (docs/workflows/build-design.md, "Review coverage and provenance"): the build's
  # commit (verified before the review, which saw only a verified commit)
  # and a kept fix on top (verified by Verify fix: it's the commit the
  # checks passed on, above).
  jq -n --slurpfile context "$BUILD_CONTEXT" --slurpfile gates "$RUNNER_TEMP/gates.json" --slurpfile review "$CODE_REVIEW" \
      --slurpfile fix "$FIX_RESULT" \
      --slurpfile contract "$RUNNER_TEMP/contract.json" --arg ticket "$TICKET_KEY" \
      --arg version "$(cat "$HUB_DIR/VERSION")" --arg head "$(git rev-parse HEAD)" -L "$HUB_DIR/lib" -L "$STAGE_DIR" 'include "wording";
    $context[0] as $c | {schema: 1, ticket: $ticket, generation: 1, hub_version: $version,
      plan: ($c.plan | {attachment, uploaded, sha256, approved_at}), target: $c.target, base: $c.base,
      plan_base: $contract[0].base_commit,
      heads: ((now | todate) as $at | ($fix[0] | if .status == "kept" then .before else $head end) as $built
        | [{generation: 1, head: $built, hub_version: $version, by: "hub", kind: "build", verified: {head: $built, by: "verify"}, at: $at}]
          + (if $head != $built then [{generation: 1, head: $head, hub_version: $version, by: "hub", kind: "fix",
               verified: {head: $head, by: "verify-fix"}, at: $at}] else [] end)),
      risk: $contract[0].governance.risk.level,
      flags: [$contract[0].governance.includes | to_entries[] | select(.value) | .key],
      items: (review_items($gates[0]; $review[0]; $fix[0])
        + [$contract[0].governance.manual_changes | to_entries[] | {id: "C\(.key + 1)", path: .value.path, status: "open"}]),
      review: ($review[0] | {status, head, cost: (.cost // 0)}),
      fix: ($fix[0] | {status, before, after}),
      totals: $gates[0].totals}' > "$RUNNER_TEMP/state.json"
  url=""
  [ "$publish" != true ] || url=$TICKET_URL
  jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" -f "$STAGE_DIR/pr-body.jq" --slurpfile out "$BUILD_OUTPUT" --slurpfile context "$BUILD_CONTEXT" \
      --slurpfile gates "$RUNNER_TEMP/gates.json" --slurpfile contract "$RUNNER_TEMP/contract.json" \
      --slurpfile state "$RUNNER_TEMP/state.json" --slurpfile verify "$RUNNER_TEMP/verify.json" \
      --slurpfile deps "$RUNNER_TEMP/dependencies.json" --slurpfile access "$RUNNER_TEMP/agent-access.json" \
      --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --arg ticket "$TICKET_KEY" --arg url "$url" --arg run "$RUN_URL" \
    | state_render "$(cat "$RUNNER_TEMP/state.json")" > "$RUNNER_TEMP/pr-body.md"
  title=$(_pr_title "$publish")
  number=$(gh_pr_open_draft "$branch" "$target" "$title" < "$RUNNER_TEMP/pr-body.md") \
    || stage_fail "The branch $branch was pushed, but GitHub didn't open its pull request. Open a draft pull request from it by hand, or delete the branch and retry."
  gh_label "$number" "$BUILD_LABEL" \
    || stage_fail "Pull request #$number was opened, but its $BUILD_LABEL label couldn't be added. Add it by hand: the hub treats only labelled pull requests as its own."

  # The ticket gets the whole report — it's private, unlike a public
  # repository's pull request — and its Delivery sections the link and the
  # testing steps. Until the review, CI and hand-off steps exist, a person
  # takes it from here.
  url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$number"
  _ticket_report "$number" "$url"
  _ticket_delivery "$number" "$url" "$branch"
  build_save_review "the build's commit"
  echo "[$TICKET_KEY]($TICKET_URL): draft pull request #$number opened from $branch, with $(jq '[.items[] | select(.id | startswith("D"))] | length' "$RUNNER_TEMP/state.json") decision item(s) and $(jq '[.items[] | select(.id | startswith("R"))] | length' "$RUNNER_TEMP/state.json") review item(s)." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome written
}

# build_save_review <what was reviewed>: the latest full review and fix pass,
# kept in a private issue property on the ticket (agent-hub-review) — the
# findings' full text, which a public pull request can't hold — for /skip and
# /apply to re-render the pull request's items and act on them (commands.sh).
# Trimmed to fit Jira's 32 KB per property. A failure only warns: items can
# still be skipped, but the description's list isn't rewritten until the next
# review.
build_save_review() {
  local record limit
  for limit in 600 150 0; do
    record=$(jq -nc --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --slurpfile contract "$RUNNER_TEMP/contract.json" \
        --argjson publish "$(context .publish)" --arg what "$1" --argjson limit "$limit" '
      def cut: if type == "string" and length > $limit then .[0:$limit] + "…" else . end;
      def keep: {n, area, severity, kind, within_plan, file, line, title, policy,
                 evidence: (.evidence | cut), suggestion: (.suggestion | cut)};
      {review: ($review[0] | {status, head, summary, findings: [.findings[]? | keep][0:60]}),
       fix: ($fix[0] | {status, before, after, checks, new_concerns: [.new_concerns[]? | keep]}),
       manual_changes: $contract[0].governance.manual_changes, publish: $publish, what: $what}')
    [ "${#record}" -gt 30000 ] || break
  done
  tracker_set_property agent-hub-review <<< "$record" \
    || echo "::warning::Couldn't keep the review's findings on $TICKET_KEY, so /skip and /apply can't list them until the next review."
}

# _trust_build_git: the hub's git copy keeps only the settings git needs to
# read and push this repository — never one that could run a program or
# receive the token (hooks, credential helpers, filters, fsmonitor, aliases,
# an ssh command…), whatever a checkout carried in.
_trust_build_git() {
  local key value
  : > "$RUNNER_TEMP/build-git-config"
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case "$key" in
      core.repositoryformatversion | core.bare | core.logallrefupdates | core.sparsecheckout | core.sparsecheckoutcone \
        | core.ignorecase | core.precomposeunicode | core.filemode | core.symlinks | extensions.* \
        | remote.origin.url | remote.origin.fetch | remote.origin.promisor | remote.origin.partialclonefilter)
        git config -f "$RUNNER_TEMP/build-git-config" --add "$key" "$value" ;;
    esac
  done < <(git config -f "$BUILD_GIT/config" --list -z | tr '\n' '\0')
  mv "$RUNNER_TEMP/build-git-config" "$BUILD_GIT/config"
  rm -rf "$BUILD_GIT/hooks"
}

# _snapshot_guidance <commit>: the repository's guidance for every pass of
# this run — CLAUDE.md, AGENTS.md, .claude/ (its CLAUDE.md, agents and
# skills) and the hub extensions — as they are in <commit>, the target
# branch's head when the run starts (never a pull request's head), into
# $RUNNER_TEMP/guidance (repo/ and extensions/). The agent runner reads them
# from there (lib/runners/claude-code.sh, _guidance_root), so nothing an
# agent writes in the checkout becomes a later pass's instructions. Links
# are dropped: they could point anywhere.
_snapshot_guidance() {
  local dir="$RUNNER_TEMP/guidance" path
  rm -rf "$dir" && mkdir -p "$dir/repo" "$dir/extensions"
  for path in CLAUDE.md AGENTS.md .claude; do
    git cat-file -e "$1:$path" 2> /dev/null || continue
    git archive "$1" -- "$path" | tar -x -C "$dir/repo" \
      || stage_fail "Couldn't read the repository's guidance ($path) from $1, so nothing was built."
  done
  case "$EXTENSIONS_DIR" in
    # An extensions folder outside the repository (the tests') is used as it is.
    /*) [ ! -d "$EXTENSIONS_DIR" ] || cp -R "$EXTENSIONS_DIR/." "$dir/extensions/" ;;
    *) if git cat-file -e "$1:$EXTENSIONS_DIR" 2> /dev/null; then
         git archive --prefix=x/ "$1" -- "$EXTENSIONS_DIR" | tar -x -C "$dir" \
           && mv "$dir/x/$EXTENSIONS_DIR"/* "$dir/extensions/" 2> /dev/null; rm -rf "$dir/x"
       fi ;;
  esac
  find "$dir" -type l -delete
}

# _refuse_hard_links: stop if any file git would commit has more than one
# hard link (the paths go only on the ticket).
_refuse_hard_links() {
  local linked
  linked=$(build_hard_linked_files | paste -sd ',' - | sed 's/,/, /g')
  [ -z "$linked" ] \
    || stage_fail "The build left files that are hard links to other files on the runner, so nothing was committed or pushed." "Files: $linked."
}

# build_hard_linked_files: the changed files in the checkout (modified or
# new, not ignored) that are hard links — one per line. The one check Verify
# and Verify fix both use: paths come from git, NUL-separated, and reach
# stat only after `--`, so no file name is ever read as an option.
build_hard_linked_files() {
  local path links
  while IFS= read -r -d '' path; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    links=$(stat -c %h -- "$path" 2> /dev/null || stat -f %l -- "$path")
    [ "$links" -le 1 ] || printf '%s\n' "$path"
  done < <(git ls-files -z --modified --others --exclude-standard)
}

# _require_same_plan: stop, changing nothing, unless the approval the run
# started from still stands: the same approval of the same plan files, the
# work order unchanged since (_approval_problem).
_require_same_plan() {
  local now
  _automation_account
  now=$(_approval_snapshot) \
    || stage_fail "Couldn't check $TRACKER_NAME that the plan's approval still stands, so nothing was changed."
  if [ -n "$(_approval_problem "$now")" ] \
     || [ "$(_approval_key "$now")" != "$(jq -c '[.plan.approved_at, .plan.files]' "$BUILD_CONTEXT")" ]; then
    stage_fail "The plan's approval changed while the build was running (a plan file was added or removed, the work order was edited, or the ticket was approved again), so nothing was changed. Check the newest plan file and the work order, then approve again."
  fi
}

# _pr_title <publish>: the pull request's title. With ticket text allowed,
# the ticket's summary; otherwise what the hub itself knows — the files the
# build changed (gates.json): "<KEY>: change a.js and b.js", or "<KEY>:
# change 5 files in src/".
_pr_title() {
  if [ "$1" = true ]; then
    jq -r --arg key "$TICKET_KEY" '"\($key): \(.fields.summary | .[0:200])"' "$RUNNER_TEMP/ticket.json"
    return
  fi
  jq -r --arg key "$TICKET_KEY" '
    [.files[].path] as $paths
    | ([.files[].status] | unique) as $statuses
    | (if $statuses == ["A"] then "add" elif $statuses == ["D"] then "remove" else "change" end) as $verb
    # The folder every path is in: the folders their paths start with, up to
    # the first that differs ("" if none).
    | [$paths[] | split("/")[:-1]] as $folders
    | ([range(0; [$folders[] | length] | min) | select(. as $i | any($folders[]; .[$i] != $folders[0][$i]))]
       | first // ([$folders[] | length] | min)) as $common
    | ($folders[0][:$common] | join("/")) as $folder
    | if ($paths | length) == 1 then "\($key): \($verb) \($paths[0])"
      elif ($paths | length) == 2 and ($paths | join(" and ") | length) <= 160 then "\($key): \($verb) \($paths[0]) and \($paths[1])"
      elif $folder != "" then "\($key): \($verb) \($paths | length) files in \($folder)/"
      else "\($key): \($verb) \($paths | length) files" end' "$RUNNER_TEMP/gates.json"
}

# _ticket_report <number> <url>: the "🔨 Draft pull request opened" comment
# with the build's whole report — what changed, how each criterion is
# verified, the checks it ran and their results, how to review it, its
# decisions and what's left for a person. The ticket is private, so it gets
# all of it, whatever the repository's visibility.
_ticket_report() {
  # shellcheck disable=SC1112 # curly apostrophes intended
  jq -n -L "$HUB_DIR/lib" --arg number "$1" --arg url "$2" --arg run "$RUN_URL" \
      --slurpfile out "$BUILD_OUTPUT" --slurpfile gates "$RUNNER_TEMP/gates.json" \
      --slurpfile contract "$RUNNER_TEMP/contract.json" --slurpfile verify "$RUNNER_TEMP/verify.json" \
      --slurpfile deps "$RUNNER_TEMP/dependencies.json" --slurpfile access "$RUNNER_TEMP/agent-access.json" \
      --slurpfile review "$CODE_REVIEW" --slurpfile state "$RUNNER_TEMP/state.json" --slurpfile fix "$FIX_RESULT" \
      -L "$STAGE_DIR" 'include "adf"; include "wording";
    $out[0] as $o | $o.structured_output.build as $b | $gates[0] as $g | $contract[0] as $p | $deps[0] as $d
    | $review[0] as $r | $fix[0] as $x | ([$state[0].items[] | select(.source == "review")]) as $ritems
    | ([$state[0].items[] | select(.source == "fix-check")]) as $citems
    | def heading($t): para([strong($t)]);
    doc([para([strong("🔨 Draft pull request opened"), text(" — "), link("#\($number)"; $url),
          text(". It stays a draft until the hub hands it off: once no decision item is open and every required check has passed on its latest commit, it’s marked ready for review and this ticket moves to Ready for Review. Approvers act on its items here, with /skip or /apply; the steps to review it are in its description, under Testing Instructions. The build’s report:")]),
        heading("What changed"), para($b.summary),
        heading("Acceptance criteria — how each is verified"),
        bullets([$b.verification[] | [strong(.criterion), text(" — \(.method): \(.detail)")]]),
        heading("Checks the hub ran on the pushed commit"),
        (if ($verify[0].checks | length) > 0
         then bullets([$verify[0].checks[] | [code(.command), text(" — "), strong(.result)]])
         else para("None: the repository declares no checks (no test, lint, typecheck or build script).") end),
        (if ($d.changes // []) == [] then empty else
          heading("Dependency changes — applied by the hub before the agent ran"),
          para("Exactly as the plan lists them"
            + (if $d.min_release_age_days > 0 then "; only versions published at least \($d.min_release_age_days) days ago (before \($d.before))" else "; no minimum release age" end)
            + "."),
          bullets([($d.changes[] | [code(.folder), text(": \(.action) "),
                     code(if .action == "remove" then .package else "\(.package)@\(.version_range)" end)]
                     + (if .action == "remove" then [] else [text(" (\(.kind)) → \(.version // "?"), licence \(.license // "not stated")")] end)),
                   ($d.folders[] | [text("In "), code(.folder), text(": \(dependency_summary($d.before))")])])
         end),
        heading("Checks the build agent ran"),
        bullets([$b.tests_run[] | [code(.command), text(" — "), strong(.result), text(": \(.summary)")]]),
        heading("How to review — and what the build saw"),
        bullets([$b.review_steps[] | [code(.step), text(" — expect: \(.expected | sentence) ")]
                 + (if .checked then [strong("Seen by the build"), text(": \(.result)")]
                    else [strong("Not checked by the build"), text(": \(.result)")] end)]),
        heading("Decisions the build made"),
        bullets([$b.decision_log[] | [strong(.decision), text(" — \(.why)"
          + (if (.alternatives // []) != [] then " Alternatives: \(.alternatives | join("; "))." else "" end))]]),
        heading("Automated code review"),
        (if $r.status == "incomplete" then para("It didn’t finish (\($r.reason)), so the build is unreviewed: a person reviews it without one.")
         elif ($r.findings | length) == 0 then para("\($r.summary | sentence)")
         else para("\($r.summary | sentence) Each finding is a decision for a person, fix-eligible (fixed once by the fix pass, below) or a review item:"),
           bullets([$ritems[] | . as $i | ([$r.findings[] | select(.n == $i.finding)] | first) as $f
             | [strong("\(.id) — \($f.title | unstop)"),
                text(" (\(.severity) \(.kind | gsub("-"; " ")), \(.area | gsub("-"; " "))\(if (.id | startswith("D")) then "; a decision" elif .status == "fixed" then "; fixed" elif .fix_eligible then "; fix-eligible, not fixed" else "" end))")]
               + (if $f.file != "" then [text(" "), code(if $f.line then "\($f.file):\($f.line)" else $f.file end)] else [] end)
               + [text(". \($f.evidence | sentence)")]
               + (if ($f.suggestion // "") != "" then [text(" Suggested: \($f.suggestion | sentence)")] else [] end)])
         end)]
      + (if $x.status == "kept" or $x.status == "dropped" or $x.status == "failed" then
          [heading("Fix pass"),
           para(if $x.status == "kept" then "The fix-eligible findings were fixed once, in a commit after the reviewed one; the hub’s gates and the repository’s checks passed on it, so it was kept. A fresh read-only session checked each fix:"
                else "A fix pass ran, but its changes weren’t kept: \($x.reason). The findings stay open." end)]
          + (if ($x.fixes | length) > 0 then
              [bullets([$x.fixes[] | .finding as $n | ([$ritems[] | select(.finding == $n)] | first) as $item
                | ([$x.checks[] | select(.finding == $n)] | first) as $c
                | [strong("\($item.id // "Finding \($n)") — \(if .fixed then "fixed" else "left" end)"), text(": \(.what | sentence)")]
                  + (if $x.status == "kept" and $c then [text(" Check: "), strong($c.verdict), text(" — \($c.note | sentence)")] else [] end)])]
             else [] end)
          + (if ($citems | length) > 0 then
              [para("New concerns the fixes raised:"),
               bullets([$citems[] | . as $i | ([$x.new_concerns[] | select(.n == $i.concern)] | first) as $f
                 | [strong("\(.id) — \($f.title | unstop)"), text(" (\(.severity) \(.kind | gsub("-"; " "))\(if (.id | startswith("D")) then "; a decision" else "" end))")]
                   + (if $f.file != "" then [text(" "), code(if $f.line then "\($f.file):\($f.line)" else $f.file end)] else [] end)
                   + [text(". \($f.evidence | sentence)")]
                   + (if ($f.suggestion // "") != "" then [text(" Suggested: \($f.suggestion | sentence)")] else [] end)])]
             else [] end)
         else [] end)
      + (if ([$state[0].items[] | select(.id | startswith("D"))] | length) + ($p.governance.manual_changes | length) > 0 then
          [heading("For a person"),
           bullets([($g.decisions[] | [text("Decision: "), code(if .path == "" then "the whole change" else .path end), text(" — \(.reason)")]),
                    ($state[0].items[] | select(.id | startswith("D")) | select(.source == "hub") | [text("Decision: \(.reason | sentence)")]),
                    ($state[0].items[] | select(.id | startswith("D")) | select(.source == "review") | [text("Decision: review finding \(.id) above")]),
                    ($state[0].items[] | select(.id | startswith("D")) | select(.source == "fix-check") | [text("Decision: the fix check’s concern \(.id) above")]),
                    ($p.governance.manual_changes[] | [text("Manual change: "), code(.path), text(" — \(.change)")])])]
         else [] end)
      + [para([em("\(claude_cost($access[0]; ($o.total_cost_usd // 0) + ($r.cost // 0) + ($x.cost // 0))) · \(($o.duration_ms // 0) + ($r.duration_ms // 0) + ($x.duration_ms // 0) | duration) of Claude time. "),
               link("Run summary"; $run)])])' \
    | tracker_comment > /dev/null
}

# _ticket_delivery <number> <url> <branch>: the work order's Delivery
# sections — Pull Request (the link, what changed and the files) and Testing
# Instructions (the reviewer's steps with their expected results, and the
# checks the build ran) — in the description as it is now,
# with needs-human, in one update. A description without those sections, or
# one that would grow past the tracker's limit, keeps its text: only the
# label is added, and the report comment has it all. Never fails the run —
# the pull request is already open.
_ticket_delivery() {
  local updated size
  # shellcheck disable=SC1112 # curly apostrophe intended
  updated=$(tracker_issue description | jq -c -L "$HUB_DIR/lib" --arg number "$1" --arg url "$2" --arg branch "$3" \
      --slurpfile out "$BUILD_OUTPUT" --slurpfile gates "$RUNNER_TEMP/gates.json" \
      --slurpfile verify "$RUNNER_TEMP/verify.json" 'include "adf";
    $out[0].structured_output.build as $b
    | .fields.description
    | replace_section("Pull Request";
        [para([link("#\($number)"; $url), text(" — a draft on "), code($branch),
          text(", opened by the build from the approved plan. The 🔨 comment has the build’s full report.")]),
         para($b.summary),
         bullets([$gates[0].files[] | [code(.path), text(" — \({A: "added", M: "modified", D: "deleted"}[.status] // .status)"
           + (if .added == null then ", binary" else ", +\(.added) −\(.deleted)" end))]])])
    | replace_section("Testing Instructions";
        [para([text("Check out "), code($branch), text(" (or read the pull request’s Files changed), then:")])]
        + (if ($b.review_steps | length) > 0 then
            [{type: "taskList", attrs: {localId: "testing"}, content: [$b.review_steps | to_entries[] | {type: "taskItem",
              attrs: {localId: "testing-\(.key)", state: "TODO"},
              content: [text("\(.value.step) — expect: \(.value.expected | unstop)"
                + (if .value.checked then " (the build saw this)" else " (not checked by the build: \(.value.result))" end))]}]}]
           else [para("The build gave no steps: follow the plan’s Testing section.")] end)
        + [para("Checks the hub ran on this commit (the pull request is only pushed if they pass):"),
           (if ($verify[0].checks | length) > 0 then bullets([$verify[0].checks[] | [code(.command), text(" — \(.result)")]])
            else para("None: the repository declares no checks.") end)])' 2> /dev/null) \
    || { echo "::warning::The description has no Pull Request or Testing Instructions section, so only the report comment has them."; tracker_labels "+$NEEDS_HUMAN_LABEL"; return 0; }
  size=$(jq -r -L "$HUB_DIR/lib" 'include "adf"; to_markdown | length' <<< "$updated")
  if [ "$size" -gt "$DESCRIPTION_MAX_CHARS" ]; then
    echo "::warning::With the testing steps, the description would pass $TRACKER_NAME's limit, so only the report comment has them."
    tracker_labels "+$NEEDS_HUMAN_LABEL"
    return 0
  fi
  tracker_set_description "+$NEEDS_HUMAN_LABEL" <<< "$updated" \
    || { echo "::warning::$TRACKER_NAME didn't take the description's Delivery sections; the report comment has them."; tracker_labels "+$NEEDS_HUMAN_LABEL"; }
}

# step_return: Send the ticket back: the build can't go ahead as approved.
step_return() {
  stage_require_status "$PLAN_APPROVED_STATUS"
  _require_same_plan
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
  local transition plan_file="$RUNNER_TEMP/$PLAN_FILE_NAME"
  transition=$(stage_transition_id "$PLAN_STATUS")
  {
    stage_drop_md_section "$BUILD_QUESTIONS_SECTION" < "$RUNNER_TEMP/plan.md"
    printf '\n## %s\n\n' "$BUILD_QUESTIONS_SECTION"
    jq -r '.structured_output.questions[] | "- **\(.question)** Why it matters: \(.why)"' "$BUILD_OUTPUT"
  } > "$plan_file"
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
