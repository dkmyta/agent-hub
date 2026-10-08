# shellcheck shell=bash
# Replaces gh_request() from lib/github.sh — the one function every GitHub API
# call goes through — with a mock that keeps state, like GitHub would: pull
# requests (number, branch, base, title, draft, state, labels) and every
# version of their descriptions with who wrote it (GitHub's edit history).
# Each call is logged to $GH_CALLS as {method, path, body}. State lives in
# $RUNNER_TEMP/mock-github/.
#
#   MOCK_GH_LOGIN        the token's user (default: agent-hub-bot)
#   MOCK_GH_VISIBILITY   public or private (default: private)
#   MOCK_GH_EDITS_PAGE   edits per page of edit history (default: 100)
#   MOCK_GH_FAIL         "METHOD path" of a call that should fail
#   MOCK_GH_HISTORY      a recorded edit-history response to serve for the
#                        GraphQL query instead of the mock's own (from
#                        shared/fixtures/github-edit-history)
#   MOCK_GH_LOST         opening a pull request works, but the first reply is
#                        lost (a failure, as when a connection breaks after
#                        GitHub acted)
#   MOCK_GH_RACE_BEFORE  a description a person saves just before each of the
#                        hub's description updates (the write race)
#   MOCK_GH_RACE         one a person saves right after each of them
#   MOCK_GH_PRS_FIXTURE  pull requests that exist before the run (a JSON array
#                        in the state's shape, e.g. from an earlier build)
#   MOCK_GH_REQUIRED     the checks the target branch requires, a JSON array of
#                        names (default ["test"]); MOCK_GH_RULES its rulesets'
#                        rules (default [])
#   MOCK_GH_CHECKS       check runs on any commit, a JSON object name →
#                        conclusion (success, failure, …) or status (queued,
#                        in_progress); default none. MOCK_GH_CHECKS_APP: the
#                        app id they're posted by (default 15368)
#   MOCK_GH_STATUSES     commit statuses, a JSON object context → state
#   MOCK_GH_LOG          a failed Actions job's log (default: one line)
#   MOCK_GH_ON_CHECKS    a script run once, when the check runs are first read —
#                        e.g. a person pushing while the hub reads CI
#
# CI reads (gh_ci_get: the workflow's own token) are logged with ci: true;
# requests for the build (the CI sweep) go to dispatches.jsonl.
#
# Any request not listed here fails, so a test can't pass on a call it never
# meant to make. mock_gh_pr and mock_gh_edit set up state for a test.

_mock_gh_state() {
  mkdir -p "$RUNNER_TEMP/mock-github"
  local f="$RUNNER_TEMP/mock-github/prs.json"
  if [ ! -s "$f" ]; then
    if [ -n "${MOCK_GH_PRS_FIXTURE:-}" ]; then cp "$MOCK_GH_PRS_FIXTURE" "$f"; else echo '[]' > "$f"; fi
  fi
  echo "$f"
}

gh_request() {
  local method=GET url="" body="" path state
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method=$2; shift 2 ;;
      -H) shift 2 ;;
      -d) case "$2" in @-) body=$(cat) ;; *) body=$2 ;; esac; shift 2 ;;
      *) url=$1; shift ;;
    esac
  done
  path=${url#"$GH_API"}
  jq -nc --arg method "$method" --arg path "$path" --arg body "$body" --arg ci "${GH_READ_CI:-}" \
    '{method: $method, path: $path, body: (if $body == "" then null else ($body | fromjson) end)} + (if $ci == "1" then {ci: true} else {} end)' >> "$GH_CALLS"
  if [ "$method $path" = "${MOCK_GH_FAIL:-}" ]; then
    echo '{"message": "Mock GitHub failure"}'
    return 22
  fi
  state=$(_mock_gh_state)
  local repo="/repos/$GITHUB_REPOSITORY" login=${MOCK_GH_LOGIN:-agent-hub-bot}
  case "$method $path" in
    "GET /user") jq -nc --arg login "$login" '{login: $login, id: 4242}' ;;
    "GET $repo") jq -nc --arg v "${MOCK_GH_VISIBILITY:-private}" '{visibility: $v, private: ($v != "public"), default_branch: "main"}' ;;
    "GET $repo/pulls?state=all&head="*)
      local branch=${path#*head=*:}; branch=${branch%%&*}
      local sha
      sha=$(git --git-dir="${REMOTE:-/nonexistent}" rev-parse "refs/heads/$branch" 2> /dev/null || true)
      jq -c --arg b "$branch" --arg repo "$GITHUB_REPOSITORY" --arg sha "$sha" \
        '[.[] | select(.head.ref == $b) | . + {node_id: "PR_\(.number)", head: {ref: .head.ref, sha: $sha, repo: {full_name: $repo}}} | del(.versions)]' "$state" ;;
    "GET $repo/pulls?state=open&per_page=100")
      # Each head's commit from the test's remote, as GitHub reports it.
      local prs pr out="[]" sha
      prs=$(jq -c --arg repo "$GITHUB_REPOSITORY" '.[] | select(.state == "open") | . + {node_id: "PR_\(.number)", head: {ref: .head.ref, repo: {full_name: $repo}}} | del(.versions)' "$state")
      while IFS= read -r pr; do
        [ -n "$pr" ] || continue
        sha=$(git --git-dir="$REMOTE" rev-parse "refs/heads/$(jq -r '.head.ref' <<< "$pr")" 2> /dev/null || true)
        out=$(jq -c --argjson pr "$pr" --arg sha "$sha" '. + [$pr | .head.sha = $sha]' <<< "$out")
      done <<< "$prs"
      echo "$out" ;;
    "GET $repo/branches/"*)
      jq -nc --argjson names "${MOCK_GH_REQUIRED:-[\"test\"]}" \
        '{protected: true, protection: {required_status_checks: {contexts: $names, checks: [$names[] | {context: ., app_id: null}]}}}' ;;
    "GET $repo/rules/branches/"*) echo "${MOCK_GH_RULES:-[]}" ;;
    "GET $repo/commits/"*/check-runs*)
      if [ -n "${MOCK_GH_ON_CHECKS:-}" ] && [ ! -e "$RUNNER_TEMP/mock-github/on-checks" ]; then
        touch "$RUNNER_TEMP/mock-github/on-checks"
        # As a person elsewhere: none of the step's git settings (build_git).
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM \
          bash -e -c "$MOCK_GH_ON_CHECKS" > "$RUNNER_TEMP/mock-github/on-checks.log" 2>&1
      fi
      jq -nc --argjson checks "${MOCK_GH_CHECKS:-"{}"}" --argjson app "${MOCK_GH_CHECKS_APP:-15368}" '
        {check_runs: [$checks | to_entries | to_entries[] | .key as $i | .value | {id: (9000 + $i), name: .key, app: {id: $app, slug: "github-actions"}}
          + (if .value | IN("queued", "in_progress") then {status: .value, conclusion: null} else {status: "completed", conclusion: .value} end)]}' ;;
    "GET $repo/check-runs/"*)
      jq -nc --arg id "${path##*/}" '{id: ($id | tonumber), output: {title: "Tests failed", summary: "1 failing test (check run \($id))", text: null}}' ;;
    "GET $repo/actions/jobs/"*/logs)
      # The job's log: MOCK_GH_LOG, or a short one.
      printf '%s\n' "${MOCK_GH_LOG:-2026-10-08T10:00:00Z not ok 1 greets by name}" ;;
        "GET $repo/commits/"*/status*)
      jq -nc --argjson s "${MOCK_GH_STATUSES:-"{}"}" '{statuses: [$s | to_entries[] | {context: .key, state: .value}]}' ;;
    "POST $repo/actions/workflows/"*/dispatches)
      mkdir -p "$RUNNER_TEMP/mock-github"
      jq -c --arg wf "${path#"$repo/actions/workflows/"}" '. + {workflow: ($wf | rtrimstr("/dispatches"))}' <<< "$body" >> "$RUNNER_TEMP/mock-github/dispatches.jsonl"
      echo '{}' ;;
    "POST $repo/pulls")
      local number
      number=$(jq '([.[].number] | max // 100) + 1' "$state")
      jq --argjson n "$number" --argjson req "$body" --arg login "$login" \
        '. + [{number: $n, head: {ref: $req.head}, base: {ref: $req.base}, title: $req.title, body: $req.body,
               draft: $req.draft, state: "open", merged_at: null, labels: [],
               versions: [{editor: $login, body: $req.body}]}]' "$state" > "$state.new" && mv "$state.new" "$state"
      if [ -n "${MOCK_GH_LOST:-}" ] && [ ! -e "$RUNNER_TEMP/mock-github/lost" ]; then
        touch "$RUNNER_TEMP/mock-github/lost"
        echo '{"message": "Mock lost reply"}'
        return 22
      fi
      jq -nc --argjson n "$number" '{number: $n}' ;;
    "PATCH $repo/pulls/"*)
      # MOCK_GH_RACE_BEFORE: a person's description, saved just before the
      # hub's (which then replaces it).
      [ -z "${MOCK_GH_RACE_BEFORE:-}" ] || mock_gh_edit "${path##*/}" dana "$MOCK_GH_RACE_BEFORE"
      mock_gh_edit "${path##*/}" "$login" "$(jq -r '.body' <<< "$body")"
      # MOCK_GH_RACE: a person's description, saved straight after the hub's.
      [ -z "${MOCK_GH_RACE:-}" ] || mock_gh_edit "${path##*/}" dana "$MOCK_GH_RACE"
      echo '{}' ;;
    "POST $repo/issues/"*/comments)
      local n=${path#"$repo/issues/"}; n=${n%/comments}
      mkdir -p "$RUNNER_TEMP/mock-github"
      jq -nc --argjson n "$n" --argjson req "$body" '{number: $n, body: $req.body}' >> "$RUNNER_TEMP/mock-github/comments.jsonl"
      echo '{"id": 1}' ;;
    "POST $repo/issues/"*/labels)
      local n=${path#"$repo/issues/"}; n=${n%/labels}
      jq --argjson n "$n" --argjson req "$body" \
        'map(if .number == $n then .labels += [$req.labels[] | {name: .}] else . end)' "$state" > "$state.new" && mv "$state.new" "$state"
      echo '[]' ;;
    "POST /graphql")
      if jq -e '.query | test("markPullRequestReadyForReview")' <<< "$body" > /dev/null; then
        local n
        n=$(jq -r '.variables.id | ltrimstr("PR_")' <<< "$body")
        jq --argjson n "$n" 'map(if .number == $n then .draft = false else . end)' "$state" > "$state.new" && mv "$state.new" "$state"
        echo '{"data": {"markPullRequestReadyForReview": {"pullRequest": {"isDraft": false}}}}'
        return 0
      fi
      # The edit-history query: newest first, a page at a time. GitHub keeps
      # no edit record for a description that was never edited. (The shape
      # recorded from GitHub: shared/fixtures/github-edit-history.)
      if [ -n "${MOCK_GH_HISTORY:-}" ]; then cat "$MOCK_GH_HISTORY"; return 0; fi
      local n cursor size=${MOCK_GH_EDITS_PAGE:-100}
      n=$(jq -r '.variables.number' <<< "$body"); cursor=$(jq -r '.variables.cursor // 0' <<< "$body")
      jq -c --argjson n "$n" --argjson start "$cursor" --argjson size "$size" '
        (.[] | select(.number == $n)) as $pr
        | ($pr.versions | if length > 1 then length as $len | reverse | to_entries
             | map({editedAt: ("2026-10-01T\(100000 + $len - .key)"), editor: {login: .value.editor}, diff: .value.body})
           else [] end) as $edits
        | {data: {repository: {pullRequest: {body: $pr.body, author: {login: $pr.versions[0].editor},
            userContentEdits: {nodes: $edits[$start:$start + $size],
              pageInfo: {hasNextPage: (($start + $size) < ($edits | length)), endCursor: ($start + $size)}}}}}}' "$state" ;;
    *) echo "mock-github: unexpected request: $method $path" >&2; return 99 ;;
  esac
}

# mock_gh_pr <branch> <body> [labels JSON] [state] [merged]: a pull request
# the hub opened (its first description written by MOCK_GH_LOGIN).
mock_gh_pr() {
  local state
  state=$(_mock_gh_state)
  jq --arg b "$1" --arg body "$2" --argjson labels "${3:-[]}" --arg st "${4:-open}" --arg merged "${5:-}" \
      --arg login "${MOCK_GH_LOGIN:-agent-hub-bot}" '
    . + [{number: (([.[].number] | max // 100) + 1), head: {ref: $b}, base: {ref: "main"}, title: "t", body: $body,
          draft: true, state: $st, merged_at: (if $merged == "" then null else $merged end),
          labels: [$labels[] | {name: .}], versions: [{editor: $login, body: $body}]}]' "$state" > "$state.new" && mv "$state.new" "$state"
}

# mock_gh_edit <number> <editor> <body>: someone edits a description.
mock_gh_edit() {
  local state
  state=$(_mock_gh_state)
  jq --argjson n "$1" --arg editor "$2" --arg body "$3" \
    'map(if .number == $n then .body = $body | .versions += [{editor: $editor, body: $body}] else . end)' \
    "$state" > "$state.new" && mv "$state.new" "$state"
}
