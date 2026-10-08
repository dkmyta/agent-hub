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
#   nobody pushed since the hub's last push,
#   and the target branch hasn't moved     → the CI gate, then the hand-off
#                                            (handoff.sh)
#   the target branch moved                → merged in (never a rebase or a force-
#                                            push); a conflict stops for a person
#                                            (blocked). Mechanical drift — the
#                                            target changed nothing the pull request
#                                            or its plan touches, and no drift-
#                                            sensitive path — keeps the earlier
#                                            review: the merge is verified, with no
#                                            Claude. Anything else is semantic drift:
#                                            reviewed again, as below
#   people pushed commits (or semantic
#   drift)                                 → the head is verified, reviewed and,
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
#
# A run the CI sweep requested (AGENT_HUB_WAKE=ci) does only the CI gate:
# anything else it finds — a record it can't trust, a newer plan, a person's
# commits — is for a run a person starts, so it ends quietly, saying why in
# the log only, and never repeats a comment every sweep.
_reconcile_start() {
  local number=$1 branch pr state head last base people target_head
  branch=$(context .branch) target_head=$(context .base)
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
    _sweep_leaves "the hub's record in pull request #$number can't be trusted"
    stage_retry "a person checks pull request #$number's description (its hidden agent-hub:state block), then approves the plan again."
    stage_fail "The hub's record in pull request #$number can't be trusted ($(head -n 1 "$RUNNER_TEMP/state-error")), so nothing was changed."
  fi
  printf '%s\n' "$state" > "$RECONCILE_STATE"
  # Built from another plan: a person decides.
  if [ "$(jq -r '.plan.sha256' <<< "$state")" != "$(context .plan.sha256)" ]; then
    _sweep_leaves "pull request #$number was built from an earlier plan"
    _reconcile_superseded "$number"
  fi
  # The branch, as GitHub has it, must build on the head the hub last pushed.
  head=$(gh_branch_head "$branch") || stage_fail "Couldn't read $branch from GitHub, so nothing was changed."
  last=$(jq -r '.heads[-1].head' <<< "$state")
  gh_git fetch -q "$GH_REMOTE" "+refs/heads/$branch:refs/remotes/$GH_REMOTE/$branch" 2> "$RUNNER_TEMP/fetch-error" \
    || stage_fail "Couldn't fetch $branch, so nothing was changed." "Git said: $(tail -n 1 "$RUNNER_TEMP/fetch-error")"
  [ "$head" = "$last" ] || _sweep_leaves "pull request #$number has commits the hub hasn't checked (a run a person starts re-checks them)"
  if ! gh_descends "$last" "$head"; then
    stage_retry "a person checks $branch: its history no longer contains the hub's last push. Restore it, or close the pull request and approve the plan again."
    stage_fail "$branch was rewritten since the hub's last push (it no longer builds on it), so its earlier review and checks don't apply and nothing was changed."
  fi
  # Where the pull request last met the target branch — the target's head
  # (the checkout) when it hasn't moved since.
  base=$(git merge-base "$target_head" "$head") || stage_fail "Couldn't find where $branch started from the target branch, so nothing was changed."
  # Exactly as the hub left it, and up to date with the target: the CI gate
  # and, once every required check passed on this head, the hand-off
  # (handoff.sh). It ends the run. (For the sweep, the target moving isn't a
  # reason to wait: syncing is a run a person starts, and GitHub's own rules
  # decide whether a merge needs the branch up to date.)
  if [ "$head" = "$last" ] && { [ "$base" = "$target_head" ] || [ "${AGENT_HUB_WAKE:-}" = ci ]; }; then
    jq --argjson number "$number" '. + {mode: "reconcile", pr: $number}' "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" \
      && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
    _reconcile_ci "$number" "$head"
  fi
  # People's commits, a moved target, or both: check the pull request's head
  # out; _reconcile_sync merges the target in, once the committer is known.
  people=$(git rev-list --count "$last..$head")
  git checkout -q --detach "$head" || stage_fail "Couldn't check out pull request #$number's head, so nothing was changed."
  jq --argjson number "$number" --arg head "$head" --arg last "$last" --arg base "$base" --arg target_head "$target_head" --argjson people "$people" \
    '. + {mode: "reconcile", pr: $number, start_head: $head, previous_head: $last, base: $base, target_head: $target_head, people_commits: $people, sync: null}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
  echo "Pull request #$number: $people commit(s) by people since the hub's last push; reconciling."
}

# reconcile_why: why this run re-checks the pull request, in hub facts only
# (wording.jq).
reconcile_why() { jq -r -L "$HUB_DIR/lib" -L "$STAGE_DIR" 'include "wording"; reconcile_cause(.)' "$BUILD_CONTEXT"; }

# reconcile_reviews: whether this reconcile run reviews the head again —
# people pushed, or the target's changes were semantic drift. (Mechanical
# drift alone keeps the earlier review.)
reconcile_reviews() { jq -e '.people_commits > 0 or .sync.drift == "semantic"' "$BUILD_CONTEXT" > /dev/null; }

# _reconcile_sync: in the fetch step, once the committer is known — when the
# target branch has moved past where the pull request last met it, it's
# merged into the checked-out head as the machine user (a merge commit:
# never a rebase or a force-push; Apply pushes it like any hub commit). The
# drift is classified first, from paths alone. A conflict is left to a
# person (_reconcile_conflict). The base becomes the target's head, so the
# gates and the review see the pull request's own changes only.
_reconcile_sync() {
  local from target target_head branch commits changed theirs overlap sensitive drift conflicts
  from=$(context .base) target=$(context .target) target_head=$(context .target_head) branch=$(context .branch)
  [ "$from" != "$target_head" ] || return 0
  # shellcheck source=stages/build/gates.sh
  source "$STAGE_DIR/gates.sh"
  commits=$(git rev-list --count "$from..$target_head")
  # Paths, both sides of a rename: what the target changed, and what the pull
  # request (as it is now) and its plan touch.
  changed=$(git diff --name-only --no-renames -z "$from" "$target_head" | jq -Rsc 'split("\u0000") | map(select(length > 0))') \
    && theirs=$(git diff --name-only --no-renames -z "$from" HEAD | jq -Rsc --slurpfile contract "$RUNNER_TEMP/contract.json" \
      'split("\u0000") | map(select(length > 0)) + [$contract[0].changes[].path] | unique') \
    || stage_fail "Couldn't compare $target's new commits with pull request #$(context .pr), so nothing was changed."
  overlap=$(jq -rn --argjson a "$changed" --argjson b "$theirs" '[$a[] | select(IN($b[]))] | length')
  sensitive=$(jq -r '.[]' <<< "$changed" | grep -cE "$BUILD_DRIFT_SENSITIVE" || true)
  if [ "$overlap" = 0 ] && [ "$sensitive" = 0 ]; then drift=mechanical; else drift=semantic; fi

  printf 'Merge %s into %s\n\nSynced by the agent hub.\n\nRefs: %s\n' "$target" "$branch" "$TICKET_KEY" > "$RUNNER_TEMP/merge-message"
  if ! GIT_AUTHOR_NAME=$(context .committer.name) GIT_AUTHOR_EMAIL=$(context .committer.email) \
      GIT_COMMITTER_NAME=$(context .committer.name) GIT_COMMITTER_EMAIL=$(context .committer.email) \
      git merge -q --no-ff -F "$RUNNER_TEMP/merge-message" "$target_head" > "$RUNNER_TEMP/merge.log" 2>&1; then
    conflicts=$(git diff --name-only --diff-filter=U)
    git merge --abort 2> /dev/null || true
    [ -n "$conflicts" ] || stage_fail "Couldn't merge $target into $branch, so nothing was changed." \
      "Git said: $(grep -E '^(fatal|error):' "$RUNNER_TEMP/merge.log" | tail -n 3 | cut -c1-300 | paste -sd ' ' - || true)"
    _reconcile_conflict "$commits" "$conflicts"
  fi
  jq --arg base "$target_head" --arg from "$from" --arg head "$(git rev-parse HEAD)" --arg drift "$drift" \
    --argjson commits "$commits" --argjson overlap "$overlap" --argjson sensitive "$sensitive" \
    '. + {base: $base, sync: {from: $from, target_head: $base, head: $head, commits: $commits, drift: $drift, overlap: $overlap, sensitive: $sensitive}}' \
    "$BUILD_CONTEXT" > "$BUILD_CONTEXT.new" && mv "$BUILD_CONTEXT.new" "$BUILD_CONTEXT"
  echo "Merged $target ($commits new commit(s)) into $branch: $drift drift ($overlap path(s) the pull request or its plan touches, $sensitive drift-sensitive)."
}

# _reconcile_conflict <commits> <paths>: merging the target conflicts. The hub
# doesn't resolve conflicts (a later item): a person merges the target into
# the branch, and the next run re-checks what they pushed. The paths (the
# repository's own) go on the pull request and the ticket; the log gets the
# count. Ends the run.
_reconcile_conflict() {
  local number target branch count
  number=$(context .pr) target=$(context .target) branch=$(context .branch)
  count=$(grep -c . <<< "$2")
  printf '%s moved by %s since this pull request last met it, and merging it in conflicts in %s, so the hub has stopped updating this pull request. A person merges %s into %s and resolves the conflicts, then re-runs the build: it re-checks what was pushed.\n\nConflicting files:\n%s\n' \
      "$target" "$(_plural "$1" commit)" "$(_plural "$count" file)" "$target" "$branch" "$(sed 's/^/- `/; s/$/`/' <<< "$2")" \
    | gh_pr_comment "$number" || echo "::warning::Couldn't comment on pull request #$number."
  jq -n -L "$HUB_DIR/lib" --arg number "$number" --arg target "$target" --arg branch "$branch" --arg paths "$2" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong("⚠️ Merge conflict"), text(" — \($target) moved since pull request #\($number) last met it, and merging it in conflicts, so the hub has stopped updating the pull request. A person merges \($target) into \($branch) and resolves the conflicts, then re-runs the build. "),
        link("Run details"; $run)]),
      para("Conflicting files:"), bullets([$paths | split("\n")[] | select(length > 0) | [code(.)]])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL" > /dev/null
  echo "::notice::Merging $target into pull request #$number conflicts in $count file(s): a person resolves them."
  echo "[$TICKET_KEY]($TICKET_URL): merging $target into pull request #$number conflicts; a person resolves it." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome blocked
  exit 0
}

# _plural <n> <word>: "1 commit", "2 commits".
_plural() { if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 ${2}s"; fi; }

# _sweep_leaves <why>: a run the CI sweep requested ends here, quietly (see
# _reconcile_start); any other run carries on.
_sweep_leaves() {
  [ "${AGENT_HUB_WAKE:-}" = ci ] || return 0
  echo "The CI sweep's run leaves this for a person's run: $1."
  echo "[$TICKET_KEY]($TICKET_URL): left for a run a person starts — $1." >> "$GITHUB_STEP_SUMMARY"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "no change needed"
  exit 0
}

# _reconcile_superseded <number>: the plan approved now isn't the one the pull
# request was built from. Nothing is rebuilt automatically: a person closes
# the pull request (and deletes its branch) to build the new plan, or keeps
# the old one. Ends the run.
_reconcile_superseded() {
  # Marked in the record, so the CI sweep leaves the pull request alone.
  jq -c --arg plan "$(context .plan.sha256)" '.superseded = {plan: $plan, at: (now | todate)}' "$RECONCILE_STATE" > "$RUNNER_TEMP/state.json" \
    && gh_state_write "$1" "$(cat "$RUNNER_TEMP/state.json")" 2> /dev/null \
    || echo "::warning::Couldn't mark pull request #$1's record as superseded."
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
# head — or the merge with its target, when synced — exactly as Verify runs
# them on a build's commit.
reconcile_verify() {
  build_git
  [ "$(git rev-parse HEAD)" = "$(context '.sync.head // .start_head')" ] \
    || stage_fail "The checkout isn't pull request #$(context .pr)'s head, so nothing was changed."
  _check_commit "$(context .base)" || stage_fail "$(cat "$RUNNER_TEMP/check-commit-error")"
  cp "$RUNNER_TEMP/check-commit.json" "$RUNNER_TEMP/verify.json"
  if jq -e 'any(.checks[]; .result != "passed")' "$RUNNER_TEMP/verify.json" > /dev/null; then
    stage_retry "people fix the checks on $(context .branch), then approve the plan again or re-run the build."
    stage_fail "The repository's checks fail on pull request #$(context .pr)'s current head, after $(jq -r -L "$HUB_DIR/lib" -L "$STAGE_DIR" 'include "wording"; reconcile_after(.)' "$BUILD_CONTEXT"): $(jq -r '[.checks[] | select(.result != "passed") | "\(.name) (\(.result))"] | join(", ")' "$RUNNER_TEMP/verify.json"). Nothing was changed; the output is in the next comment."
  fi
}

# reconcile_apply: what changed goes to the pull request — the sync's merge
# and the fix commit, if any, pushed without force (rejected if anyone pushed
# meanwhile);
# the state block and the hub-managed status section rewritten and verified;
# a comment saying what was re-checked — and the full report to the ticket.
reconcile_apply() {
  local base branch target number start reviewed rc=0 findings status_file="" publish
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

  # The sync's merge and the fix commit, if any: scanned and pushed, never
  # forced.
  if [ "$(git rev-parse HEAD)" != "$start" ]; then
    findings=$(gh_push "$branch" "$target" 2> "$RUNNER_TEMP/push-error") || rc=$?
    case "$rc" in
      0) ;;
      1) stage_fail "The secret scan found what look like secrets in the commits to push, so nothing was pushed." "Found: $(paste -sd ',' - <<< "$findings" | sed 's/,/, /g')." ;;
      2) stage_fail "The secret scan couldn't run ($(head -n 1 "$RUNNER_TEMP/push-error")), so nothing was pushed." ;;
      *) if grep -qi 'workflow' "$RUNNER_TEMP/push-error" 2> /dev/null; then
           stage_retry "a person merges $target into $branch, then re-runs the build."
           stage_fail "GitHub rejected the push to $branch: the merge of $target brings in changes to its workflows, which the build token can't push (it has no Workflows permission, by design). Nothing was pushed."
         fi
         stage_retry "re-run the build: it starts from the new commits."
         stage_fail "GitHub rejected the push to $branch — someone pushed to it during this run — so nothing was pushed." ;;
    esac
  fi

  # The new state: the next generation, the heads with who made them, the
  # review and fix, and the items carried, closed or added.
  # A carried review (mechanical drift only) keeps the earlier review and
  # items: the pull request's own changes are exactly as they were. The sync's
  # merge is recorded as the hub's, with its drift — a commit after the last
  # full review that hand-off accepts only for mechanical drift — and as
  # verified: reconcile_verify ran the checks on exactly it (and a fix on
  # top was made on that verified commit). A kept fix is verified by Verify
  # fix: it's the commit the checks passed on (above).
  jq -n -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile prev "$RECONCILE_STATE" --slurpfile gates "$RUNNER_TEMP/gates.json" \
      --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --arg version "$(cat "$HUB_DIR/VERSION")" \
      --slurpfile ctx "$BUILD_CONTEXT" --arg head "$(git rev-parse HEAD)" 'include "wording";
    $prev[0] as $p | ($p.generation + 1) as $g | $ctx[0] as $c | ($c.sync.head // $c.start_head) as $checked
    | (now | todate) as $at
    | $p + {generation: $g, hub_version: $version, superseded: null,
        heads: ($p.heads
          + (if $c.people_commits > 0 then [{generation: $g, head: $c.start_head, by: "people", kind: "people", at: $at}] else [] end)
          + (if $c.sync then [{generation: $g, head: $c.sync.head, hub_version: $version, by: "hub", kind: "sync",
               sync: {target: $c.target, target_head: $c.sync.target_head, drift: $c.sync.drift},
               verified: {head: $c.sync.head, by: "verify"}, at: $at}] else [] end)
          + (if $head != $checked then [{generation: $g, head: $head, hub_version: $version, by: "hub", kind: "fix",
               verified: {head: $head, by: "verify-fix"}, at: $at}] else [] end)),
        review: (if $review[0].status == "carried" then $p.review else $review[0] | {status, head, cost: (.cost // 0)} end),
        fix: ($fix[0] | {status, before, after}),
        items: (if $review[0].status == "carried" then $p.items else reconcile_items($p.items; review_items($gates[0]; $review[0]; $fix[0])) end),
        totals: $gates[0].totals}' > "$RUNNER_TEMP/state.json"
  # The description's status section: rewritten for a new review; a carried
  # one leaves it as it was.
  if [ "$(jq -r '.status' "$CODE_REVIEW")" != carried ]; then
    status_file="$RUNNER_TEMP/status.md"
    jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile state "$RUNNER_TEMP/state.json" --slurpfile review "$CODE_REVIEW" \
        --slurpfile fix "$FIX_RESULT" --slurpfile contract "$RUNNER_TEMP/contract.json" --argjson publish "$publish" --slurpfile ctx "$BUILD_CONTEXT" \
        'include "wording"; status_lines($state[0]; $review[0]; $fix[0]; $contract[0]; $publish; "the pull request'"'"'s current head (after \(reconcile_after($ctx[0])))")' \
      | sed '1{/^$/d;}' > "$status_file"
  fi
  gh_state_write "$number" "$(cat "$RUNNER_TEMP/state.json")" ${status_file:+"$status_file"} 2> "$RUNNER_TEMP/state-error" \
    || stage_fail "Pull request #$number's description couldn't be updated ($(head -n 1 "$RUNNER_TEMP/state-error"))$( [ "$(git rev-parse HEAD)" = "$start" ] || echo ", though its commits were pushed"). A person checks it."
  _reconcile_comment "$number"
  _reconcile_report "$number"
  echo "[$TICKET_KEY]($TICKET_URL): pull request #$number re-checked after $(jq -r -L "$HUB_DIR/lib" -L "$STAGE_DIR" 'include "wording"; reconcile_after(.)' "$BUILD_CONTEXT") — generation $(jq -r '.generation' "$RUNNER_TEMP/state.json")." >> "$GITHUB_STEP_SUMMARY"
  stage_outcome revised
}

# _reconcile_comment <number>: what this run did, on the pull request —
# counts and hub facts only (the publication policy).
_reconcile_comment() {
  jq -nr -L "$HUB_DIR/lib" -L "$STAGE_DIR" --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --slurpfile state "$RUNNER_TEMP/state.json" \
      --slurpfile ctx "$BUILD_CONTEXT" --arg head "$(git rev-parse HEAD)" 'include "adf"; include "wording";
    $review[0] as $r | $fix[0] as $x
    | "🔁 Re-checked by the agent hub: \(reconcile_cause($ctx[0])). The head passed the repository'"'"'s checks and "
      + (if $r.status == "carried" then "the earlier review still applies, so Claude wasn'"'"'t used."
         elif $r.status == "incomplete" then "couldn'"'"'t be reviewed (\($r.reason)), which is a decision item now."
         else "was reviewed with the whole change: \(plural($r.findings | length; "finding"))." end)
      + (if $x.status == "kept" then " The fix-eligible ones were fixed once, in \($head[0:7]), and checked."
         elif $x.status == "dropped" or $x.status == "failed" then " A fix pass ran but wasn'"'"'t kept: \($x.reason)."
         else "" end)
      + (if $r.status == "carried" then " The hub'"'"'s record is updated (generation \($state[0].generation))."
         else " The description'"'"'s Automated review and Items are updated (generation \($state[0].generation))." end)' \
    | gh_pr_comment "$1" || echo "::warning::Couldn't comment on pull request #$1."
}

# _reconcile_report <number>: the ticket gets the review's findings in full
# (it's private), and what the fix pass did.
_reconcile_report() {
  # shellcheck disable=SC1112 # curly apostrophes intended
  jq -n -L "$HUB_DIR/lib" -L "$STAGE_DIR" --arg number "$1" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$1" --arg run "$RUN_URL" \
      --slurpfile review "$CODE_REVIEW" --slurpfile fix "$FIX_RESULT" --slurpfile state "$RUNNER_TEMP/state.json" \
      --slurpfile access "$RUNNER_TEMP/agent-access.json" --slurpfile ctx "$BUILD_CONTEXT" 'include "adf"; include "wording";
    $review[0] as $r | $fix[0] as $x
    | ([$state[0].items[] | select(.source == "review" and .status != "closed")]) as $ritems
    | if $r.status == "carried" then
        doc([para([strong("🔁 Pull request synced"), text(" — "), link("#\($number)"; $url),
          text(": \(reconcile_cause($ctx[0]) | sub("'"'"'"; "’"; "g")). The merged head passed the repository’s checks, and the earlier review still applies: Claude wasn’t used. "),
          link("Run summary"; $run)])])
      else
      doc([para([strong("🔁 Pull request re-checked"), text(" — "), link("#\($number)"; $url),
          text(": \(reconcile_cause($ctx[0]) | sub("'"'"'"; "’"; "g")). The head passed the repository’s checks, and the whole change was reviewed again.")])]
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
               link("Run summary"; $run)])])
      end' \
    | tracker_comment > /dev/null
}
