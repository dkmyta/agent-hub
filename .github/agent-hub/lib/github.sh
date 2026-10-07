# shellcheck shell=bash
# GitHub for the stages that change code: the pull request, its branch and its
# description, through GitHub's REST and GraphQL APIs and git.
#
# Requires: GITHUB_REPOSITORY (owner/name), AGENT_HUB_GITHUB_TOKEN (the
# machine user's fine-grained token: this repository, Contents and Pull
# requests read/write). Optional: GITHUB_API_URL, GITHUB_SERVER_URL (GitHub
# Enterprise), GH_REMOTE (the remote to push to; default origin).
#
# Loaded only by steps that write to GitHub — never by an agent step, so the
# agents never have the token.

set -o pipefail

# shellcheck source=lib/http.sh
source "$(dirname "${BASH_SOURCE[0]}")/http.sh"
# shellcheck source=lib/secret-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/secret-scan.sh"

GH_API=${GITHUB_API_URL:-https://api.github.com}
GH_REMOTE=${GH_REMOTE:-origin}

# Credentials go to curl through a file only this user can read, and to git
# through an askpass helper that reads another — never on a command line,
# where other users of the runner machine could see them.
GH_CURL_CONFIG=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/github-curl.XXXXXX")
GH_TOKEN_FILE=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/github-token.XXXXXX")
GH_ASKPASS=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/github-askpass.XXXXXX")
# Removed when the step ends, with the tracker's (the same trap: see
# trackers/jira/tracker.sh).
HUB_SECRET_FILES+=("$GH_CURL_CONFIG" "$GH_TOKEN_FILE" "$GH_ASKPASS")
trap 'rm -f "${HUB_SECRET_FILES[@]}"' EXIT
printf '%s' "${AGENT_HUB_GITHUB_TOKEN:-}" > "$GH_TOKEN_FILE"
printf 'header = "Authorization: Bearer %s"\n' "$(printf '%s' "${AGENT_HUB_GITHUB_TOKEN:-}" | sed 's/[\\"]/\\&/g')" > "$GH_CURL_CONFIG"
printf '#!/bin/sh\ncase "$1" in Username*) echo x-access-token ;; *) cat "%s" ;; esac\n' "$GH_TOKEN_FILE" > "$GH_ASKPASS"
chmod 700 "$GH_ASKPASS"

# Every GitHub API call goes through gh_request (the tests replace just this),
# with time limits and retries (lib/http.sh).
gh_request() {
  [ -n "${AGENT_HUB_GITHUB_TOKEN:-}" ] || { echo "::error::AGENT_HUB_GITHUB_TOKEN isn't set." >&2; return 1; }
  http_request GitHub --config "$GH_CURL_CONFIG" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# gh_api <METHOD> <path> [JSON body on stdin]: a REST call on this repository's API.
gh_api() {
  if [ "$1" = GET ] || [ "$1" = DELETE ]; then gh_request -X "$1" "$GH_API$2"
  else gh_request -X "$1" -H "Content-Type: application/json" "$GH_API$2" -d @-; fi
}

# gh_graphql <query> [variables JSON]: a GraphQL query (only reads, so safe to
# repeat); prints .data, fails on any error.
gh_graphql() {
  local response
  response=$(jq -nc --arg query "$1" --argjson variables "${2:-"{}"}" '{query: $query, variables: $variables}' \
    | HTTP_IDEMPOTENT=1 gh_request -X POST -H "Content-Type: application/json" "$GH_API/graphql" -d @-) || return 1
  if jq -e '(.errors // []) | length > 0' <<< "$response" > /dev/null; then
    echo "::error::GitHub GraphQL error: $(jq -c '[.errors[].type // .errors[].message]' <<< "$response")" >&2
    return 1
  fi
  jq -c '.data' <<< "$response"
}

GH_OWNER=${GITHUB_REPOSITORY%%/*}
GH_NAME=${GITHUB_REPOSITORY#*/}

# The machine user's login (the token's owner): what its own edits and
# comments are recognised by.
gh_login() { gh_api GET /user | jq -r '.login'; }

# gh_repo_visibility [repository JSON]: public or private (internal counts as
# private: it isn't public) — from the repository JSON given (as from
# `gh_api GET /repos/$GITHUB_REPOSITORY`), or fetched.
gh_repo_visibility() {
  { if [ -n "${1:-}" ]; then printf '%s' "$1"; else gh_api GET "/repos/$GITHUB_REPOSITORY"; fi; } \
    | jq -r 'if .visibility == "public" or (.visibility == null and .private == false) then "public" else "private" end'
}

# gh_pr_find <branch>: the pull request (open, closed or merged) from this
# repository's <branch>, as JSON, or nothing if there's none.
gh_pr_find() {
  gh_api GET "/repos/$GITHUB_REPOSITORY/pulls?state=all&head=$GH_OWNER:$1&per_page=10" \
    | jq -c --arg repo "$GITHUB_REPOSITORY" '[.[] | select(.head.repo.full_name == $repo)] | first // empty'
}

# gh_pr_open_draft <branch> <base> <title> < body: open a draft pull request;
# prints its number. Not repeated blindly — a lost reply may hide a pull
# request that was opened — so after a failure it looks for an open one from
# <branch> into <base> first, and only if there's none tries once more
# (GitHub refuses a second open pull request for the same branches, so it
# can't open two).
gh_pr_open_draft() {
  local request response pr
  request=$(jq -Rsc --arg head "$1" --arg base "$2" --arg title "$3" '{head: $head, base: $base, title: $title, body: ., draft: true}')
  for _ in 1 2; do
    if response=$(gh_api POST "/repos/$GITHUB_REPOSITORY/pulls" <<< "$request") \
        && jq -e '.number | numbers' <<< "$response" > /dev/null 2>&1; then
      jq -r '.number' <<< "$response"
      return 0
    fi
    pr=$(gh_pr_find "$1") || return 1
    if [ -n "$pr" ] && jq -e --arg base "$2" '.state == "open" and .base.ref == $base' <<< "$pr" > /dev/null; then
      echo "::notice::GitHub's reply to opening the pull request was lost, but it's open." >&2
      jq -r '.number' <<< "$pr"
      return 0
    fi
  done
  return 1
}

# gh_pr_update_body <number> < body: replaces the whole description, so
# repeating it changes nothing more.
gh_pr_update_body() {
  jq -Rsc '{body: .}' | HTTP_IDEMPOTENT=1 gh_api PATCH "/repos/$GITHUB_REPOSITORY/pulls/$1" > /dev/null
}

# gh_label <number> <label>: add a label to a pull request (adding one it
# already has changes nothing, so it's safe to repeat).
gh_label() {
  jq -nc --arg label "$2" '{labels: [$label]}' | HTTP_IDEMPOTENT=1 gh_api POST "/repos/$GITHUB_REPOSITORY/issues/$1/labels" > /dev/null
}

# gh_pr_body_versions <number>: every version of the pull request's
# description, oldest first, as [{editor, body, deleted, deleted_by}] — from
# GitHub's edit history, a page of 100 at a time, ending with the current
# one. As recorded from GitHub (tests/shared/fixtures/github-edit-history):
# once edited, the original is the oldest entry, by the author; each entry's
# `diff` is the whole description after that edit; a revision someone
# deleted keeps its entry (deleted: true, body unknown). A description never
# edited has just one version, by the pull request's author. Fails if the
# newest version isn't the description GitHub returns now.
gh_pr_body_versions() {
  local cursor=null page edits='[]' data
  # shellcheck disable=SC2016 # GraphQL variables, not shell
  local query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) {
      body author { login }
      userContentEdits(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor } nodes { editedAt deletedAt deletedBy { login } editor { login } diff } } } } }'
  while :; do
    data=$(gh_graphql "$query" "$(jq -nc --arg owner "$GH_OWNER" --arg name "$GH_NAME" --argjson number "$1" \
      --argjson cursor "$cursor" '{owner: $owner, name: $name, number: $number, cursor: $cursor}')") || return 1
    page=$(jq -c '.repository.pullRequest' <<< "$data")
    edits=$(jq -c --argjson page "$page" '. + $page.userContentEdits.nodes' <<< "$edits")
    [ "$(jq -r '.userContentEdits.pageInfo.hasNextPage' <<< "$page")" = true ] || break
    cursor=$(jq -c '.userContentEdits.pageInfo.endCursor' <<< "$page")
  done
  # Edits come newest first; the current description is the last version.
  edits=$(jq -c --argjson page "$page" '
    if length == 0 then [{editor: ($page.author.login // ""), body: ($page.body // ""), deleted: false, deleted_by: null}]
    else sort_by(.editedAt) | map({editor: (.editor.login // ""), deleted: (.deletedAt != null),
      body: (if .deletedAt != null then null else (.diff // "") end), deleted_by: .deletedBy.login}) end' <<< "$edits")
  if ! jq -e --argjson page "$page" 'last | .deleted or .body == ($page.body // "")' <<< "$edits" > /dev/null; then
    echo "::error::GitHub's edit history for pull request #$1 doesn't end with its current description." >&2
    return 1
  fi
  printf '%s\n' "$edits"
}

# Git, for the branch the stage owns. Pushes authenticate through the askpass
# helper; a push never forces, so a branch someone else moved on is rejected.
gh_git() { GIT_ASKPASS="$GH_ASKPASS" GIT_TERMINAL_PROMPT=0 git "$@"; }

# gh_branch_head <branch>: the branch's head commit on the remote, or nothing.
gh_branch_head() { gh_git ls-remote --heads "$GH_REMOTE" "refs/heads/$1" | cut -f1; }

# gh_push <branch> <target branch> [--new]: push HEAD to <branch>, after
# scanning every commit the push would send — those not already on the
# remote <branch> (or, on a first push, on <target branch>) — for secrets.
# Any finding, or a scan that can't run, blocks the push (lib/secret-scan.sh):
# 1 secrets found (rules and files printed), 2 couldn't scan, 3 rejected by
# the remote. Never forced: if the branch moved on since this run fetched it,
# the push is rejected and nothing changes. With --new, the branch must not
# exist at all — one created meanwhile, even at the same commit, rejects the
# push (git checks it on the remote, atomically).
gh_push() {
  local exclude=() head lease=()
  [ "${3:-}" != --new ] || lease=("--force-with-lease=refs/heads/$1:")
  for head in "$(gh_branch_head "$1")" "$(gh_branch_head "$2")"; do
    [ -n "$head" ] && exclude+=("$head")
  done
  secret_scan "${exclude[@]}" || return $?
  gh_git push --quiet "${lease[@]}" "$GH_REMOTE" "HEAD:refs/heads/$1" || return 3
}

# gh_branch_status <branch> [label]: what the stage's branch is, for the
# branch-lifecycle rules (docs/workflows/build.md, "Branch lifecycle"):
#   absent          no branch and no pull request — a build may start one
#   open <n>        an open pull request from it, carrying <label> (the hub's)
#   foreign <n>     an open pull request from it without <label> — not the hub's
#   merged <n>      its pull request was merged
#   closed <n>      its pull request was closed unmerged
#   orphan          the branch exists with no pull request (e.g. a failed
#                   earlier build) — a person decides
#   deleted <n>     its pull request is open but the branch is gone
gh_branch_status() {
  local pr head number
  pr=$(gh_pr_find "$1") || return 1
  head=$(gh_branch_head "$1") || return 1
  if [ -z "$pr" ]; then
    if [ -n "$head" ]; then echo orphan; else echo absent; fi
    return 0
  fi
  number=$(jq -r '.number' <<< "$pr")
  if [ "$(jq -r '.merged_at != null' <<< "$pr")" = true ]; then echo "merged $number"
  elif [ "$(jq -r '.state' <<< "$pr")" = closed ]; then echo "closed $number"
  elif [ -z "$head" ]; then echo "deleted $number"
  elif [ -n "${2:-}" ] && ! jq -e --arg label "$2" 'any(.labels[]?; .name == $label)' <<< "$pr" > /dev/null; then
    echo "foreign $number"
  else echo "open $number"; fi
}

# gh_descends <older> <newer>: whether <newer> builds on <older> (the branch
# wasn't rewritten). A force-push or rewritten history makes everything
# recorded about earlier commits — generations, review coverage — invalid.
gh_descends() { git merge-base --is-ancestor "$1" "$2" 2> /dev/null; }

# gh_publish_ticket_text <visibility> <setting>: whether ticket-derived text
# may go into pull requests, commits, comments and logs. A private
# repository: yes. A public one: only if the setting
# (AGENT_HUB_PUBLISH_TICKET_CONTENT) is true — otherwise only the ticket key
# and what's derived from the code itself (docs/workflows/build.md,
# "Publication policy").
gh_publish_ticket_text() {
  [ "$1" = private ] || [ "$2" = true ]
}
