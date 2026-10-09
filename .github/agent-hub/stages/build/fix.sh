# shellcheck shell=bash
# The build's fix pass (docs/workflows/build.md, "Fix and fix check"): after
# the code review, the fix-eligible findings (review/policy.json) are fixed
# once — a fresh session with the build profile — then a fix check, a fresh
# read-only session, judges each fix and reports anything it broke. No
# second loop: whatever isn't resolved stays a review item.
#
# Two steps:
#   step_fix         (agent) the fix pass; its changes committed on top of the
#                    reviewed commit (the candidate); the fix check, in a clean
#                    copy of exactly that commit
#   step_verify_fix  (no agent) keeps the candidate only if the gates and the
#                    repository's checks pass on it; otherwise the reviewed
#                    commit is pushed as it was
# Neither can cost the build: both continue on error, and Apply settles a fix
# that didn't finish (_settle_fix) before it pushes.
#
# Sourced by stage.sh. Writes fix.json:
#   {status: none | made | kept | dropped | failed, reason?, before, after?,
#    findings: [n], fixes: [{finding, fixed, what}],
#    checks: [{finding, verdict, note}], new_concerns: [finding + policy]}

FIX_RESULT="$RUNNER_TEMP/fix.json"

# _fix_record <status> <reason> [before]: a fix pass that changed nothing
# kept — the hub's own words for why.
_fix_record() {
  local cost
  # What the passes that did run cost.
  cost=$(cat "$RUNNER_TEMP/fix-output.json" "$RUNNER_TEMP/fix-check-output.json" 2> /dev/null \
    | jq -sc '{cost: ([.[].total_cost_usd // 0] | add // 0), ms: ([.[].duration_ms // 0] | add // 0)}' 2> /dev/null) || cost=""
  jq -n --arg status "$1" --arg reason "$2" --arg before "${3:-}" --argjson spent "${cost:-"{}"}" \
    '{status: $status, reason: $reason, before: $before, cost: ($spent.cost // 0), duration_ms: ($spent.ms // 0),
      findings: [], fixes: [], checks: [], new_concerns: []}' > "$FIX_RESULT"
  echo "**Fix pass:** $1 — $2." >> "$GITHUB_STEP_SUMMARY"
}

# _numbered_findings <findings JSON>: the findings, for a prompt.
_numbered_findings() {
  jq -r '.[] | "\(.n). [\(.severity) \(.kind)] \(.title)\(if .file != "" then " — \(.file)\(if .line then ":\(.line)" else "" end)" else "" end)\n   Evidence: \(.evidence)\n   Suggested fix: \(.suggestion)"
    + (if .what then "\n   The fix pass: \(if .fixed then "fixed" else "left it" end) — \(.what)" else "" end)' <<< "$1"
}

# _fix_instructions: the fix pass's instructions folder — ci-fix for a CI fix.
_fix_instructions() {
  if reconciling && ci_fixing; then echo ci-fix
  elif reconciling && applying; then echo apply
  else echo fix; fi
}

# _fix_commit_message: the fix commit's subject, by what it fixes. (No case
# statement inside a command substitution: Bash 3.2, macOS's, misparses one.)
_fix_commit_message() {
  local kind
  kind=$(_fix_instructions)
  if [ "$kind" = ci-fix ]; then echo "Fix the failing required checks"
  elif [ "$kind" = apply ]; then echo "Apply the items an approver asked for"
  else echo "Fix the automated review's findings"; fi
}

# _fix_diff <commit>: the checkout's changes since <commit> — new files too —
# from the trusted metadata, without touching its index.
_fix_diff() {
  (build_git && export GIT_INDEX_FILE="$RUNNER_TEMP/fix-index" && cp "$GIT_DIR/index" "$GIT_INDEX_FILE" \
    && git add -A && git diff --cached --no-color --no-ext-diff "$1")
}

step_fix() {
  local head after rc findings input output="$RUNNER_TEMP/fix-output.json" check="$RUNNER_TEMP/fix-check-output.json" diff
  case "$(jq -r '.status' "$CODE_REVIEW" 2> /dev/null)" in
    reviewed) ;;
    carried) _fix_record none "the earlier review was carried over"; return 0 ;;
    *) _fix_record none "the review didn't finish"; return 0 ;;
  esac
  findings=$(jq -c '[.findings[] | select(.policy == "fix")]' "$CODE_REVIEW")
  if [ "$findings" = "[]" ]; then
    _fix_record none "no fix-eligible findings"
    return 0
  fi
  head=$(build_git && git rev-parse HEAD)
  [ "$head" = "$(jq -r '.head' "$CODE_REVIEW")" ] || { _fix_record failed "the commit isn't the one the review saw"; return 0; }

  input=$(printf '<ticket>\n%s\n</ticket>\n\n<findings>\n%s\n</findings>\n' "$(cat "$RUNNER_TEMP/ticket.md")" "$(_numbered_findings "$findings")")
  # A CI fix is this same pass, with its own instructions (ci-fix/: the
  # findings are failed checks) and the same schema.
  agent_pass build "$BUILD_FIX_MODEL" "$BUILD_FIX_FALLBACK_MODEL" "$BUILD_FIX_MAX_BUDGET_USD" \
    "$STAGE_DIR/$(_fix_instructions)/prompt.md" "$STAGE_DIR/fix/schema.json" "$input" > "$output"
  if [ ! -s "$output" ] || ! jq -e --argjson f "$findings" '.is_error == false and (.structured_output.fixes | type == "array")
       and ([.structured_output.fixes[].finding] - [$f[].n] == [])' "$output" > /dev/null 2>&1; then
    _fix_record failed "Claude returned no usable result for the fix pass" "$head"
    jq -c '{is_error, subtype, errors}' "$output" 2> /dev/null || true
    return 0
  fi
  # What it says it did, beside each finding.
  findings=$(jq -c --slurpfile out "$output" 'map(. as $f | . + (first($out[0].structured_output.fixes[] | select(.finding == $f.n) | {fixed, what}) // {fixed: false, what: "not attempted"}))' <<< "$findings")
  _fix_diff "$head" > "$RUNNER_TEMP/fix.diff" || { _fix_record failed "the fix pass's changes couldn't be listed" "$head"; return 0; }
  if [ ! -s "$RUNNER_TEMP/fix.diff" ]; then
    _fix_record failed "the fix pass changed nothing" "$head"
    return 0
  fi

  # The candidate: committed now (this step holds no credentials), so the fix
  # check judges exactly the commit Verify fix will check and Apply may push.
  rc=0
  after=$(_commit_candidate "$head" 2> "$RUNNER_TEMP/fix-commit-error") || rc=$?
  if [ "$rc" != 0 ]; then
    [ "$rc" != 2 ] || _discard_fix_artifacts
    _fix_record "$([ "$rc" = 2 ] && echo dropped || echo failed)" "$(head -n 1 "$RUNNER_TEMP/fix-commit-error")" "$head"
    return 0
  fi
  # Recorded at once: if this step stops before the check finishes, Apply
  # drops the candidate (_settle_fix) and pushes the reviewed commit.
  jq -n --arg head "$head" --arg after "$after" \
    '{status: "made", before: $head, after: $after, findings: [], fixes: [], checks: [], new_concerns: []}' > "$FIX_RESULT"
  # The fix check: a fresh, read-only session on exactly what changed, in its
  # own clean copy of the candidate — not the checkout the fix pass worked in.
  diff=$(cat "$RUNNER_TEMP/fix.diff")
  input=$(printf '<ticket>\n%s\n</ticket>\n\n<findings>\n%s\n</findings>\n\n<diff>\n%s\n</diff>\n' \
    "$(cat "$RUNNER_TEMP/ticket.md")" "$(_numbered_findings "$findings")" "$diff")
  if ! build_clean_copy "$after" "$RUNNER_TEMP/fix-check-copy" 2> "$RUNNER_TEMP/fix-copy-error"; then
    _drop_candidate "$head"
    _fix_record failed "a clean copy of the fix couldn't be made for its check ($(head -n 1 "$RUNNER_TEMP/fix-copy-error"))" "$head"
    return 0
  fi
  (cd "$RUNNER_TEMP/fix-check-copy" && agent_pass review "$BUILD_FIX_MODEL" "$BUILD_FIX_FALLBACK_MODEL" "$BUILD_FIX_CHECK_MAX_BUDGET_USD" \
    "$STAGE_DIR/fix-check/prompt.md" "$STAGE_DIR/fix-check/schema.json" "$input") > "$check"
  # Unchecked fixes aren't kept.
  if [ ! -s "$check" ] || ! jq -e --argjson f "$findings" '.is_error == false and (.structured_output.checks | type == "array")
       and (.structured_output.new_concerns | type == "array")
       and ([.structured_output.checks[].finding] - [$f[].n] == [])
       and ([.structured_output.new_concerns[].file | select(. != "" and (startswith("/") or test("(^|/)\\.\\.(/|$)")))] == [])' \
       "$check" > /dev/null 2>&1; then
    _drop_candidate "$head"
    _fix_record failed "the fix check returned no usable result, so the fixes weren't kept" "$head"
    jq -c '{is_error, subtype, errors}' "$check" 2> /dev/null || true
    return 0
  fi
  jq -c '.structured_output.new_concerns' "$check" | review_policy > "$RUNNER_TEMP/fix-concerns.json"
  jq -n --arg head "$head" --arg after "$after" --argjson f "$findings" --slurpfile check "$check" --slurpfile concerns "$RUNNER_TEMP/fix-concerns.json" \
      --slurpfile out "$output" '
    {status: "made", before: $head, after: $after, findings: [$f[].n],
     cost: (($out[0].total_cost_usd // 0) + ($check[0].total_cost_usd // 0)),
     duration_ms: (($out[0].duration_ms // 0) + ($check[0].duration_ms // 0)),
     fixes: [$f[] | {finding: .n, fixed, what}],
     # A finding missing from the check is unresolved.
     checks: [$f[] | .n as $n | ($check[0].structured_output.checks | map(select(.finding == $n)) | first)
       // {finding: $n, verdict: "unresolved", note: "The fix check did not report on it."}],
     new_concerns: $concerns[0]}' > "$FIX_RESULT"
  # Counts only: notes and concerns quote the code.
  jq -r '"**Fix pass:** \(.findings | length) fix-eligible finding(s) worked on — \([.checks[] | select(.verdict == "resolved")] | length) resolved, \([.checks[] | select(.verdict != "resolved")] | length) unresolved, \(.new_concerns | length) new concern(s); verified next."' \
    "$FIX_RESULT" | tee -a "$GITHUB_STEP_SUMMARY"
}

# _discard_fix_artifacts: everything a candidate left — its gate results, its
# copies and the checks' output — so nothing of it can reach Apply.
_discard_fix_artifacts() {
  rm -rf "$RUNNER_TEMP/fix-gates.json" "$RUNNER_TEMP/fix-gates-before.json" "$RUNNER_TEMP/check-commit.json" \
    "$RUNNER_TEMP/verify" "$RUNNER_TEMP/checks" "$RUNNER_TEMP/fix-check-copy"
}

# _drop_fix <reason>: back to the reviewed commit, the fix recorded as
# dropped — fully: the candidate's gate results, its copy for the checks and
# their output are deleted too, so nothing of it can reach Apply.
_drop_fix() {
  local before
  before=$(jq -r '.before' "$FIX_RESULT")
  (build_git && git reset -q --hard "$before") || true
  _discard_fix_artifacts
  # The reviewed commit's own check results, if a kept fix replaced them.
  [ ! -f "$RUNNER_TEMP/verify-reviewed.json" ] || cp "$RUNNER_TEMP/verify-reviewed.json" "$RUNNER_TEMP/verify.json"
  jq --arg reason "$1" '.status = "dropped" | .reason = $reason' "$FIX_RESULT" > "$FIX_RESULT.new" && mv "$FIX_RESULT.new" "$FIX_RESULT"
  echo "::warning::The fix pass's changes weren't kept: $1. The reviewed commit is pushed as it was."
  echo "**Fix pass:** dropped — $1." >> "$GITHUB_STEP_SUMMARY"
}

# _commit_candidate <reviewed commit>: the fix pass's changes, committed on
# top of the reviewed commit as the machine user; prints the commit. Fails —
# the checkout back at the reviewed commit, the reason on standard error — if
# it isn't at that commit, left a hard-linked file, or changed nothing.
_commit_candidate() {
  build_git
  [ "$(git rev-parse HEAD)" = "$1" ] || { echo "the checkout isn't at the reviewed commit" >&2; return 1; }
  # No file with more than one link — the check Verify uses. (A rule the
  # candidate broke: exit 2, recorded as dropped.)
  [ -z "$(build_hard_linked_files)" ] || { echo "it left a hard-linked file" >&2; return 2; }
  git add -A
  if git diff --cached --quiet; then git reset -q; echo "it changed nothing" >&2; return 1; fi
  GIT_AUTHOR_NAME=$(context .committer.name) GIT_AUTHOR_EMAIL=$(context .committer.email) \
    GIT_COMMITTER_NAME=$(context .committer.name) GIT_COMMITTER_EMAIL=$(context .committer.email) \
    git commit -q -m "$(_fix_commit_message)" -m "Refs: $TICKET_KEY" \
    || { git reset -q --hard "$1"; echo "it couldn't be committed" >&2; return 1; }
  git rev-parse HEAD
}

# _drop_candidate <reviewed commit>: back to the reviewed commit, the candidate
# discarded (a fix check that didn't finish, or no copy for it).
_drop_candidate() { (build_git && git reset -q --hard "$1") || true; }

# _verify_candidate: the candidate the Fix step committed, checked as Verify
# checked the build's. Prints why not, and fails, if it can't be kept.
_verify_candidate() {
  local base before after refused added
  build_git
  base=$(context .base) before=$(jq -r '.before' "$FIX_RESULT") after=$(jq -r '.after' "$FIX_RESULT")
  [ "$(git rev-parse HEAD)" = "$after" ] && [ "$(git rev-parse HEAD^)" = "$before" ] \
    || { echo "the checkout isn't the fix committed on the reviewed commit"; return 1; }
  # shellcheck source=stages/build/gates.sh
  source "$STAGE_DIR/gates.sh"
  # The gates on the reviewed commit, to compare the fix's with.
  build_gates "$base" "$RUNNER_TEMP/contract.json" "$before" > "$RUNNER_TEMP/fix-gates-before.json" 2> /dev/null || { echo "the reviewed commit's changes couldn't be checked"; return 1; }
  # The gates on the whole change, as Apply will run them. A fix is kept only
  # if it adds nothing for a person: no file the hub never pushes, and no
  # decision item the reviewed commit didn't already have (outside the
  # plan's scope, a must-not-touch area, a dependency file, the size
  # limits…) — an automatic fix never puts a person's decision into a
  # pushable commit. Counts only: the paths are the agent's.
  build_gates "$base" "$RUNNER_TEMP/contract.json" > "$RUNNER_TEMP/fix-gates.json" 2> /dev/null || { echo "its changes couldn't be checked"; return 1; }
  # (Compared with the reviewed commit: a person's commit on an existing pull
  # request may already have one.)
  refused=$(jq -n --slurpfile before "$RUNNER_TEMP/fix-gates-before.json" --slurpfile after "$RUNNER_TEMP/fix-gates.json" \
    '[$after[0].refused[] | .path] - [$before[0].refused[] | .path] | length')
  [ "$refused" = 0 ] || { echo "it changed $refused file(s) the hub never pushes"; return 1; }
  added=$(jq -n --slurpfile before "$RUNNER_TEMP/fix-gates-before.json" --slurpfile after "$RUNNER_TEMP/fix-gates.json" \
    '[$after[0].decisions[] | {path, reason}] - [$before[0].decisions[] | {path, reason}] | length')
  [ "$added" = 0 ] || { echo "it would add $added decision item(s) for a person"; return 1; }
  _check_commit "$base" || { echo "the repository's checks couldn't run on it"; return 1; }
  if jq -e 'any(.checks[]; .result != "passed")' "$RUNNER_TEMP/check-commit.json" > /dev/null; then
    echo "the repository's checks failed on it: $(jq -r '[.checks[] | select(.result != "passed") | "\(.name) (\(.result))"] | join(", ")' "$RUNNER_TEMP/check-commit.json")"
    return 1
  fi
}

step_verify_fix() {
  local why
  [ "$(jq -r '.status' "$FIX_RESULT" 2> /dev/null)" = made ] || return 0
  cp "$RUNNER_TEMP/verify.json" "$RUNNER_TEMP/verify-reviewed.json"
  # In a subshell: nothing it does can end the step before the fix is settled.
  if why=$(_verify_candidate 2> "$RUNNER_TEMP/fix-verify.log"); then
    cp "$RUNNER_TEMP/check-commit.json" "$RUNNER_TEMP/verify.json"
    jq '.status = "kept"' "$FIX_RESULT" > "$FIX_RESULT.new" && mv "$FIX_RESULT.new" "$FIX_RESULT"
    echo "**Fix pass:** kept — the gates and the repository's checks passed on it." | tee -a "$GITHUB_STEP_SUMMARY"
  else
    _drop_fix "${why:-it could not be verified}"
  fi
}

# _settle_fix: in Apply, before anything is pushed — a fix that never
# finished verifying (Verify fix cut off, or never run) is dropped, so only
# a commit the checks passed on is pushed.
_settle_fix() {
  # No record: nothing to settle. (A candidate is recorded the moment it's
  # committed, so a checkout that isn't the commit the checks passed on is
  # refused by Apply's own check, never pushed.)
  [ -s "$FIX_RESULT" ] || { _fix_record none "it didn't run to the end"; return 0; }
  case "$(jq -r '.status' "$FIX_RESULT")" in
    made) _drop_fix "it didn't finish verifying" ;;
    kept) [ "$(git rev-parse HEAD)" = "$(jq -r '.after' "$FIX_RESULT")" ] || _drop_fix "the commit changed after it was verified" ;;
  esac
}
