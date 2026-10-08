# shellcheck shell=bash
# Reconciling a build that already has the hub's pull request (4c;
# docs/workflows/build.md, "Contracts"): instead of stopping, the run works
# out what the open pull request needs and does only that.
#
#   paused (agent-hub-paused label)        → nothing (outcome paused)
#   its record can't be trusted, or its
#   branch was rewritten                   → stop for a person (failed)
#   the approved plan isn't the one it was
#   built from                             → superseded: a person decides (blocked)
#   nobody pushed since the hub's last push → nothing to do (no change needed)
#   people pushed commits                  → their head is verified, reviewed and,
#                                            if the review allows, fixed once —
#                                            the same steps and rules as a build,
#                                            without the build pass
#
# Sourced by stage.sh; each step hands over to these when the build context's
# mode is "reconcile". The pull request's state comes from its state block,
# trusted only if its edit history shows every change to it was the hub's
# (lib/state.sh).

RECONCILE_STATE="$RUNNER_TEMP/reconcile-state.json"

# reconciling: whether this run reconciles an existing pull request.
reconciling() { [ "$(jq -r '.mode // "build"' "$BUILD_CONTEXT" 2> /dev/null)" = reconcile ]; }

# _reconcile_start <number>: in the fetch step, after _branch found the hub's
# open pull request <number>. Ends the run (exit 0) when there's nothing to
# do or a person must decide; otherwise checks out the pull request's head
# and records the mode for the later steps.
_reconcile_start() {
  local number=$1 branch pr state head last base people
  branch=$(context .branch)
  pr=$(gh_pr_find "$branch") || stage_fail "Couldn't read pull request #$number from GitHub, so nothing was changed."
  if jq -e --arg label "$BUILD_PAUSED_LABEL" 'any(.labels[]?; .name == $label)' <<< "$pr" > /dev/null; then
    echo "::notice::Pull request #$number has the $BUILD_PAUSED_LABEL label, so the hub leaves it alone."
    echo "[$TICKET_KEY]($TICKET_URL): pull request #$number is paused ($BUILD_PAUSED_LABEL); nothing was done." >> "$GITHUB_STEP_SUMMARY"
    echo "proceed=false" >> "$GITHUB_OUTPUT"
    stage_outcome paused
    exit 0
  fi
  # The hub's record, only if every edit to it was the hub's own.
  if ! state=$(gh_state_read "$number" 2> "$RUNNER_TEMP/state-error"); then
    stage_retry "a person checks pull request #$number's description (its hidden agent-hub:state block), then approves the plan again."
    stage_fail "The hub's record in pull request #$number can't be trusted ($(head -n 1 "$RUNNER_TEMP/state-error")), so nothing was changed."
  fi
  printf '%s\n' "$state" > "$RECONCILE_STATE"
  # Built from another plan: a person decides.
  if [ "$(jq -r '.plan.sha256' <<< "$state")" != "$(context .plan.sha256)" ]; then
    _reconcile_superseded "$number"
  fi
  # The branch, as GitHub has it, must build on the head the hub last pushed.
  head=$(gh_branch_head "$branch") || stage_fail "Couldn't read $branch from GitHub, so nothing was changed."
  last=$(jq -r '.heads[-1].head' <<< "$state")
  gh_git fetch -q "$GH_REMOTE" "+refs/heads/$branch:refs/remotes/$GH_REMOTE/$branch" 2> "$RUNNER_TEMP/fetch-error" \
    || stage_fail "Couldn't fetch $branch, so nothing was changed." "Git said: $(tail -n 1 "$RUNNER_TEMP/fetch-error")"
  if ! gh_descends "$last" "$head"; then
    stage_retry "a person checks $branch: its history no longer contains the hub's last push. Restore it, or close the pull request and approve the plan again."
    stage_fail "$branch was rewritten since the hub's last push (it no longer builds on it), so its earlier review and checks don't apply and nothing was changed."
  fi
  if [ "$head" = "$last" ]; then
    echo "Pull request #$number is at the head the hub last pushed and checked: nothing to do."
    echo "[$TICKET_KEY]($TICKET_URL): pull request #$number is up to date with the hub's last push; nothing to do." >> "$GITHUB_STEP_SUMMARY"
    echo "proceed=false" >> "$GITHUB_OUTPUT"
    stage_outcome "no change needed"
    exit 0
  fi
  # People's commits since: check the pull request's head out, and compare
  # with the plan's base as the build did (the common ancestor with the
  # target branch — syncing with a moved target is 4c-2).
  people=$(git rev-list --count "$last..$head")
  git checkout -q --detach "$head" || stage_fail "Couldn't check out pull request #$number's head, so nothing was changed."
  base=$(git merge-base "$(context .base)" "$head") || stage_fail "Couldn't find where $branch started from the target branch, so nothing was changed."
  jq --argjson number "$number" --arg head "$head" --arg last "$last" --arg base "$base" --argjson people "$people" \
    '. + {mode: "reconcile", pr: $number, start_head: $head, previous_head: $last, base: $base, people_commits: $people}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
  echo "Pull request #$number: $people commit(s) by people since the hub's last push; reconciling."
}

# _reconcile_superseded <number>: the plan approved now isn't the one the pull
# request was built from. Nothing is rebuilt automatically: a person closes
# the pull request (and deletes its branch) to build the new plan, or keeps
# the old one. Ends the run.
_reconcile_superseded() {
  printf 'The plan approved on %s is a newer version than the one this pull request was built from, so the hub has stopped updating it. To build the new plan, close this pull request and delete its branch, then approve the plan again; to keep this one, approve the plan it was built from.\n' "$TICKET_KEY" \
    | gh_pr_comment "$1" || echo "::warning::Couldn't comment on pull request #$1."
  jq -n -L "$HUB_DIR/lib" --arg number "$1" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong("⚠️ Build superseded"), text(" — the approved plan is newer than the one pull request #\($number) was built from, so the hub has stopped updating it. To build the new plan, close #\($number) and delete its branch, then approve the plan again. "),
      link("Run details"; $run)])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL" > /dev/null
  echo "::notice::Pull request #$1 was built from an earlier plan: superseded, a person decides."
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$1 superseded by a newer plan; a person decides." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome blocked
  exit 0
}

# reconcile_agent: the agent step — no build pass: the code is the pull
# request's, and the review and fix steps do the rest.
reconcile_agent() {
  jq -n '{type: "result", subtype: "success", is_error: false, total_cost_usd: 0, duration_ms: 0, structured_output: {status: "ready"}}' > "$BUILD_OUTPUT"
  echo "status=ready" >> "$GITHUB_OUTPUT"
  echo "Reconciling pull request #$(context .pr): no build pass." >> "$GITHUB_STEP_SUMMARY"
}

# reconcile_verify: the repository's checks on the pull request's current
# head, exactly as Verify runs them on a build's commit.
reconcile_verify() {
  build_git
  [ "$(git rev-parse HEAD)" = "$(context .start_head)" ] \
    || stage_fail "The checkout isn't pull request #$(context .pr)'s head, so nothing was changed."
  _check_commit "$(context .base)" || stage_fail "$(cat "$RUNNER_TEMP/check-commit-error")"
  cp "$RUNNER_TEMP/check-commit.json" "$RUNNER_TEMP/verify.json"
  if jq -e 'any(.checks[]; .result != "passed")' "$RUNNER_TEMP/verify.json" > /dev/null; then
    stage_retry "people fix the checks on $(context .branch), then approve the plan again or re-run the build."
    stage_fail "The repository's checks fail on pull request #$(context .pr)'s current head, after people's commits: $(jq -r '[.checks[] | select(.result != "passed") | "\(.name) (\(.result))"] | join(", ")' "$RUNNER_TEMP/verify.json"). Nothing was changed; the output is in the next comment."
  fi
}

# reconcile_apply: what changed goes to the pull request — the fix commit, if
# one was kept, pushed without force (rejected if anyone pushed meanwhile);
# the state block and the hub-managed status section rewritten and verified;
# a comment saying what was re-checked — and the full report to the ticket.
reconcile_apply() {
  local base branch target number start reviewed rc=0 findings status_file publish
  stage_require_status "$PLAN_APPROVED_STATUS"
  build_git
  _require_same_plan
  base=$(context .base) branch=$(context .branch) target=$(context .target) number=$(context .pr)
  start=$(context .start_head) publish=$(context .publish)
  [ -s "$RUNNER_TEMP/agent-access.json" ] || echo '{}' > "$RUNNER_TEMP/agent-access.json"
  _settle_fix
  [ "$(git rev-parse HEAD)" = "$(jq -r '.head' "$RUNNER_TEMP/verify.json" 2> /dev/null)" ] \
    || stage_fail "Pull request #$number's commit isn't the one the checks passed on, so nothing was changed."
  reviewed=$(git rev-parse HEAD)
  [ "$(jq -r '.status' "$FIX_RESULT")" != kept ] || reviewed=$(jq -r '.before' "$FIX_RESULT")
  if [ ! -s "$CODE_REVIEW" ] || [ "$(jq -r '.head' "$CODE_REVIEW" 2> /dev/null)" != "$reviewed" ]; then
    # shellcheck disable=SC1112 # curly apostrophe intended
    jq -n --arg head "$reviewed" \
      '{status: "incomplete", head: $head, reason: "it didn’t run to the end (an error, or its time limit)", findings: []}' > "$CODE_REVIEW"
  fi
  # The gates, on the whole pull request as it is now: its decisions are the
  # items. Files the hub never pushes, from people's commits, are theirs —
  # decision items too, since only the fix commit is the hub's to push (and
  # Verify fix kept no fix that added one).
  # shellcheck source=stages/build/gates.sh
  source "$STAGE_DIR/gates.sh"
  build_gates "$base" "$RUNNER_TEMP/contract.json" > "$RUNNER_TEMP/gates.json" 2> "$RUNNER_TEMP/gates-error" \
    && jq -e '(.decisions | type == "array") and (.refused | type == "array")' "$RUNNER_TEMP/gates.json" > /dev/null 2>&1 \
    || stage_fail "Pull request #$number's changes couldn't be checked ($(head -n 1 "$RUNNER_TEMP/gates-error" 2> /dev/null || true)), so nothing was changed."
  jq '.decisions += [.refused[] | {path, reason: "changed by a person in a path the hub never pushes (\(.reason))"}]' \
    "$RUNNER_TEMP/gates.json" > "$RUNNER_TEMP/gates.json.new" && mv "$RUNNER_TEMP/gates.json.new" "$RUNNER_TEMP/gates.json"

  # The fix commit, if one was kept: scanned and pushed, never forced.
  if [ "$(git rev-parse HEAD)" != "$start" ]; then
    findings=$(gh_push "$branch" "$target" 2> "$RUNNER_TEMP/push-error") || rc=$?
    case "$rc" in
      0) ;;
      1) stage_fail "The secret scan found what look like secrets in the fix, so nothing was pushed." "Found: $(paste -sd ',' - <<< "$findings" | sed 's/,/, /g')." ;;
      2) stage_fail "The secret scan couldn't run ($(head -n 1 "$RUNNER_TEMP/push-error")), so nothing was pushed." ;;
      *) stage_retry "re-run the build: it starts from the new commits."
         stage_fail "GitHub rejected the push to $branch — someone pushed to it during this run — so the fix wasn't pushed." ;;
    esac
  fi

  # The new state: the next generation, the heads with who made them, the
  # review and fix, and the items carried, closed or added.
  jq -n -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile prev "$RECONCILE_STATE" --slurpfile gates "$RUNNER_TEMP/gates.json" \
      --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --arg version "$(cat "$HUB_DIR/VERSION")" \
      --arg start "$start" --arg head "$(git rev-parse HEAD)" 'include "wording";
    $prev[0] as $p | ($p.generation + 1) as $g
    | $p + {generation: $g, hub_version: $version,
        heads: ($p.heads + [{generation: $g, head: $start, by: "people"}]
          + (if $head != $start then [{generation: $g, head: $head, hub_version: $version, by: "hub"}] else [] end)),
        review: ($review[0] | {status, head, cost: (.cost // 0)}),
        fix: ($fix[0] | {status, before, after}),
        items: reconcile_items($p.items; review_items($gates[0]; $review[0]; $fix[0])),
        totals: $gates[0].totals}' > "$RUNNER_TEMP/state.json"
  status_file="$RUNNER_TEMP/status.md"
  jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile state "$RUNNER_TEMP/state.json" --slurpfile review "$CODE_REVIEW" \
      --slurpfile fix "$FIX_RESULT" --slurpfile contract "$RUNNER_TEMP/contract.json" --argjson publish "$publish" \
      'include "wording"; status_lines($state[0]; $review[0]; $fix[0]; $contract[0]; $publish; "the pull request'"'"'s current head (after people'"'"'s commits)")' \
    | sed '1{/^$/d;}' > "$status_file"
  gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" "$status_file" 2> "$RUNNER_TEMP/state-error" \
    || stage_fail "Pull request #$number's description couldn't be updated ($(head -n 1 "$RUNNER_TEMP/state-error"))$( [ "$(git rev-parse HEAD)" = "$start" ] || echo ", though the fix was pushed"). A person checks it."
  _reconcile_comment "$number"
  _reconcile_report "$number"
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$number re-checked after $(context .people_commits) commit(s) by people — generation $(jq -r '.generation' "$RUNNER_TEMP/state.json")." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome revised
}

# _reconcile_comment <number>: what this run did, on the pull request —
# counts and hub facts only (the publication policy).
_reconcile_comment() {
  jq -nr -L "$HUB_DIR/lib" --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --slurpfile state "$RUNNER_TEMP/state.json" \
      --arg start "$(context .start_head)" --arg head "$(git rev-parse HEAD)" --argjson people "$(context .people_commits)" 'include "adf";
    $review[0] as $r | $fix[0] as $x
    | "🔁 Re-checked by the agent hub: \(plural($people; "commit")) pushed since its last push, at \($start[0:7]), passed the repository'"'"'s checks and "
      + (if $r.status == "incomplete" then "couldn'"'"'t be reviewed (\($r.reason)), which is a decision item now."
         else "were reviewed with the whole change: \(plural($r.findings | length; "finding"))." end)
      + (if $x.status == "kept" then " The fix-eligible ones were fixed once, in \($head[0:7]), and checked."
         elif $x.status == "dropped" or $x.status == "failed" then " A fix pass ran but wasn'"'"'t kept: \($x.reason)."
         else "" end)
      + " The description'"'"'s Automated review and Items are updated (generation \($state[0].generation))."' \
    | gh_pr_comment "$1" || echo "::warning::Couldn't comment on pull request #$1."
}

# _reconcile_report <number>: the ticket gets the review's findings in full
# (it's private), and what the fix pass did.
_reconcile_report() {
  # shellcheck disable=SC1112 # curly apostrophes intended
  jq -n -L "$HUB_DIR/lib" -L "$STAGE_DIR" --arg number "$1" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$1" --arg run "$RUN_URL" \
      --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --slurpfile state "$RUNNER_TEMP/state.json" \
      --slurpfile access "$RUNNER_TEMP/agent-access.json" --argjson people "$(context .people_commits)" 'include "adf"; include "wording";
    $review[0] as $r | $fix[0] as $x
    | ([$state[0].items[] | select(.source == "review" and .status != "closed")]) as $ritems
    | doc([para([strong("🔁 Pull request re-checked"), text(" — "), link("#\($number)"; $url),
          text(": \(plural($people; "commit")) by people since the hub’s last push passed the repository’s checks, and the whole change was reviewed again.")])]
      + (if $r.status == "incomplete" then [para("The review didn’t finish (\($r.reason)): a decision item for a person.")]
         elif ($r.findings | length) == 0 then [para($r.summary | sentence)]
         else [para("\($r.summary | sentence) The findings:"),
           bullets([$ritems[] | . as $i | ([$r.findings[] | select(.n == $i.finding)] | first) as $f
             | [strong("\(.id) — \($f.title | unstop)"), text(" (\(.severity) \(.kind | gsub("-"; " "))\(if (.id | startswith("D")) then "; a decision" elif .status == "fixed" then "; fixed" elif .fix_eligible then "; fix-eligible, not fixed" else "" end))")]
               + (if $f.file != "" then [text(" "), code(if $f.line then "\($f.file):\($f.line)" else $f.file end)] else [] end)
               + [text(". \($f.evidence | sentence)")]
               + (if ($f.suggestion // "") != "" then [text(" Suggested: \($f.suggestion | sentence)")] else [] end)])]
         end)
      + (if $x.status == "kept" then [para("The fix-eligible findings were fixed once and checked; the fix passed the gates and the checks, so it was pushed.")]
         elif $x.status == "dropped" or $x.status == "failed" then [para("A fix pass ran, but its changes weren’t kept: \($x.reason).")]
         else [] end)
      + [para([em("\(claude_cost($access[0]; ($r.cost // 0) + ($x.cost // 0))) · \((($r.duration_ms // 0) + ($x.duration_ms // 0)) | duration) of Claude time. "),
               link("Run summary"; $run)])])' \
    | tracker_comment > /dev/null
}
