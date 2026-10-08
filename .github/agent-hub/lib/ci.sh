# shellcheck shell=bash
# CI results for one commit, as GitHub's merge rules see them
# (docs/workflows/build.md, "CI gate"): the checks the target branch requires
# — from its branch protection and its rulesets, so a required check that
# never reported still counts — and each one's latest result on exactly that
# commit. A green result for any other commit is never evidence for this one.
#
# Reads only, with the workflow's own token (gh_ci_get in lib/github.sh).
# Used by the build's CI gate (stages/build/handoff.sh) and the CI sweep
# (stages/build/sweep.sh).

# ci_required <branch>: the checks GitHub requires before merging into
# <branch>, as JSON [{name, app_id}] — app_id is the app that must post it,
# or null for any. Fails if either source can't be read.
ci_required() {
  local branch protection rules
  branch=$(jq -rn --arg b "$1" '$b | @uri')
  protection=$(gh_ci_get "/repos/$GITHUB_REPOSITORY/branches/$branch") || return 1
  rules=$(gh_ci_get "/repos/$GITHUB_REPOSITORY/rules/branches/$branch?per_page=100") || return 1
  jq -nc --argjson p "$protection" --argjson r "$rules" '
    def app: if (. // -1) < 0 then null else . end;
    [($p.protection.required_status_checks // {}) | (.checks // [])[] | {name: .context, app_id: (.app_id | app)}]
    + [($p.protection.required_status_checks // {}) | (.contexts // [])[] | {name: ., app_id: null}]
    + [$r[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?
       | {name: .context, app_id: (.integration_id | app)}]
    | group_by(.name) | map({name: .[0].name, app_id: ([.[].app_id | select(. != null)] | first)})'
}

# ci_status <commit> <required JSON>: the required checks' results on exactly
# <commit>, as {head, state, checks: [{name, result, conclusions, runs}]}. Each
# result is passed, failed, pending or missing, with GitHub's own conclusions
# (or statuses' states) behind it — a CI fix tells a failure from a timeout
# by them. The state is green (all passed), failed (any failed), pending (any
# pending or missing) or unconfigured (nothing required). A check run counts
# only if it's from the app the rule names, when it names one; the latest
# run of each check is the one that counts. Fails if the results can't be
# read in full.
ci_status() {
  local runs="[]" page=1 batch statuses
  while :; do
    batch=$(gh_ci_get "/repos/$GITHUB_REPOSITORY/commits/$1/check-runs?filter=latest&per_page=100&page=$page") || return 1
    runs=$(jq -c --argjson b "$batch" '. + ($b.check_runs // [])' <<< "$runs")
    [ "$(jq '.check_runs | length' <<< "$batch")" = 100 ] && [ "$page" -lt 10 ] || break
    page=$((page + 1))
  done
  statuses=$(gh_ci_get "/repos/$GITHUB_REPOSITORY/commits/$1/status?per_page=100") || return 1
  jq -nc --arg head "$1" --argjson required "$2" --argjson runs "$runs" --argjson s "$statuses" '
    def run_result: if .status != "completed" then "pending"
      elif (.conclusion | IN("success", "neutral", "skipped")) then "passed" else "failed" end;
    def status_result: {success: "passed", pending: "pending"}[.state] // "failed";
    [$required[] | . as $r
      | [$runs[] | select(.name == $r.name and ($r.app_id == null or .app.id == $r.app_id))] as $matched
      | (if $r.app_id == null then [$s.statuses[]? | select(.context == $r.name)] else [] end) as $posted
      | ([$matched[] | run_result] + [$posted[] | status_result]) as $results
      | {name: $r.name, conclusions: ([$matched[] | .conclusion // .status] + [$posted[] | .state]),
         runs: [$matched[] | {id, app: (.app.slug // ""), conclusion: (.conclusion // .status)}],
         result: (if ($results | length) == 0 then "missing"
          elif any($results[]; . == "failed") then "failed"
          elif any($results[]; . == "pending") then "pending" else "passed" end)}] as $checks
    | {head: $head, checks: $checks,
       state: (if ($checks | length) == 0 then "unconfigured"
         elif any($checks[]; .result == "failed") then "failed"
         elif any($checks[]; .result == "pending" or .result == "missing") then "pending" else "green" end)}'
}

# ci_failure_details <ci JSON>: what the failed required checks said, for the
# CI-fix pass, as JSON [{name, conclusions, evidence}] — each check run's own
# summary, and for a GitHub Actions job the end of its log. Repository output:
# it goes to the agent only, as information, never to the run log. A part
# that can't be read is left out (the check's name and result still go).
CI_LOG_LINES=150
CI_EVIDENCE_BYTES=12000
ci_failure_details() {
  local check run id app summary log evidence out="[]"
  while IFS= read -r check; do
    evidence=""
    while IFS= read -r run; do
      id=$(jq -r '.id' <<< "$run") app=$(jq -r '.app' <<< "$run")
      [[ "$id" =~ ^[0-9]+$ ]] || continue
      summary=$(gh_ci_get "/repos/$GITHUB_REPOSITORY/check-runs/$id" 2> /dev/null \
        | jq -r '.output | [.title, .summary, .text] | map(select(. != null and . != "")) | join("\n")' 2> /dev/null) || summary=""
      log=""
      if [ "$app" = github-actions ]; then
        # The job's log (the check run's id is the job's); GitHub redirects to
        # a short-lived download, where the token isn't sent.
        log=$(GH_READ_CI=1 gh_request -L -X GET "$GH_API/repos/$GITHUB_REPOSITORY/actions/jobs/$id/logs" 2> /dev/null \
          | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tail -n "$CI_LOG_LINES") || log=""
      fi
      [ -z "$summary" ] || evidence+=$(printf '%s\n' "$summary")$'\n'
      [ -z "$log" ] || evidence+=$(printf "The end of the job's log:\n%s\n" "$log")$'\n'
    done < <(jq -c '.runs[]?' <<< "$check")
    # The end of it, if it's long.
    [ "${#evidence}" -le "$CI_EVIDENCE_BYTES" ] || evidence=${evidence: -$CI_EVIDENCE_BYTES}
    out=$(jq -c --argjson c "$check" --arg e "$evidence" \
      '. + [{name: $c.name, conclusions: $c.conclusions, evidence: $e}]' <<< "$out")
  done < <(jq -c '.checks[] | select(.result == "failed")' <<< "$1")
  echo "$out"
}
