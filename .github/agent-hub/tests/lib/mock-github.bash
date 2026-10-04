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
#   MOCK_GH_RACE_BEFORE  a description a person saves just before each of the
#                        hub's description updates (the write race)
#   MOCK_GH_RACE         one a person saves right after each of them
#
# Any request not listed here fails, so a test can't pass on a call it never
# meant to make. mock_gh_pr and mock_gh_edit set up state for a test.

_mock_gh_state() { mkdir -p "$RUNNER_TEMP/mock-github"; local f="$RUNNER_TEMP/mock-github/prs.json"; [ -s "$f" ] || echo '[]' > "$f"; echo "$f"; }

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
  jq -nc --arg method "$method" --arg path "$path" --arg body "$body" \
    '{method: $method, path: $path, body: (if $body == "" then null else ($body | fromjson) end)}' >> "$GH_CALLS"
  if [ "$method $path" = "${MOCK_GH_FAIL:-}" ]; then
    echo '{"message": "Mock GitHub failure"}'
    return 22
  fi
  state=$(_mock_gh_state)
  local repo="/repos/$GITHUB_REPOSITORY" login=${MOCK_GH_LOGIN:-agent-hub-bot}
  case "$method $path" in
    "GET /user") jq -nc --arg login "$login" '{login: $login}' ;;
    "GET $repo") jq -nc --arg v "${MOCK_GH_VISIBILITY:-private}" '{visibility: $v, private: ($v != "public")}' ;;
    "GET $repo/pulls?state=all&head="*)
      local branch=${path#*head=*:}; branch=${branch%%&*}
      jq -c --arg b "$branch" --arg repo "$GITHUB_REPOSITORY" \
        '[.[] | select(.head.ref == $b) | . + {head: {ref: .head.ref, repo: {full_name: $repo}}} | del(.versions)]' "$state" ;;
    "POST $repo/pulls")
      local number
      number=$(jq '([.[].number] | max // 100) + 1' "$state")
      jq --argjson n "$number" --argjson req "$body" --arg login "$login" \
        '. + [{number: $n, head: {ref: $req.head}, base: {ref: $req.base}, title: $req.title, body: $req.body,
               draft: $req.draft, state: "open", merged_at: null, labels: [],
               versions: [{editor: $login, body: $req.body}]}]' "$state" > "$state.new" && mv "$state.new" "$state"
      jq -nc --argjson n "$number" '{number: $n}' ;;
    "PATCH $repo/pulls/"*)
      # MOCK_GH_RACE_BEFORE: a person's description, saved just before the
      # hub's (which then replaces it).
      [ -z "${MOCK_GH_RACE_BEFORE:-}" ] || mock_gh_edit "${path##*/}" dana "$MOCK_GH_RACE_BEFORE"
      mock_gh_edit "${path##*/}" "$login" "$(jq -r '.body' <<< "$body")"
      # MOCK_GH_RACE: a person's description, saved straight after the hub's.
      [ -z "${MOCK_GH_RACE:-}" ] || mock_gh_edit "${path##*/}" dana "$MOCK_GH_RACE"
      echo '{}' ;;
    "POST $repo/issues/"*/labels)
      local n=${path#"$repo/issues/"}; n=${n%/labels}
      jq --argjson n "$n" --argjson req "$body" \
        'map(if .number == $n then .labels += [$req.labels[] | {name: .}] else . end)' "$state" > "$state.new" && mv "$state.new" "$state"
      echo '[]' ;;
    "POST /graphql")
      # The edit-history query: newest first, a page at a time. GitHub keeps
      # no edit record for a description that was never edited.
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
