#!/usr/bin/env bats
# The GitHub library (lib/github.sh) with GitHub's API mocked and a local git
# repository as the remote.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export GITHUB_REPOSITORY=example/repo AGENT_HUB_GITHUB_TOKEN=test-token-123 GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.jsonl"
  export MOCK_GH_LOGIN=agent-hub-bot MOCK_GH_VISIBILITY=private MOCK_GH_FAIL="" MOCK_GH_EDITS_PAGE=100
  : > "$GH_CALLS"
}

# with_github <script>: script runs with the library and the mock loaded.
with_github() {
  bash -c "source '$HUB_DIR/lib/github.sh'; source '$TESTS_DIR/lib/mock-github.bash'; $1" 2>&1
}

# A remote repository with one commit on main, and a clone of it to work in.
git_remote() {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git clone -q "$BATS_TEST_TMPDIR/remote.git" "$BATS_TEST_TMPDIR/work" 2> /dev/null
  cd "$BATS_TEST_TMPDIR/work" || return
  git config user.email t@example.com && git config user.name t
  echo one > file.txt && git add file.txt && git commit -qm one && git push -q origin HEAD:refs/heads/main
}

@test "credentials never on a command line: curl reads a config file, git an askpass helper" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/curl-args.txt"\necho "{}"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  run bash -c "PATH='$BATS_TEST_TMPDIR/bin':\$PATH; source '$HUB_DIR/lib/github.sh'
    gh_api GET /user > /dev/null
    stat -c '%a' \"\$GH_CURL_CONFIG\" 2> /dev/null || stat -f '%Lp' \"\$GH_CURL_CONFIG\"
    grep -c 'Authorization: Bearer test-token-123' \"\$GH_CURL_CONFIG\"
    \"\$GH_ASKPASS\" 'Username for https://github.com'; echo
    \"\$GH_ASKPASS\" 'Password for https://x-access-token@github.com'; echo"
  assert_success
  assert_line --index 0 600
  assert_line --index 1 1
  assert_line --index 2 x-access-token
  assert_line --index 3 test-token-123
  run cat "$BATS_TEST_TMPDIR/curl-args.txt"
  refute_output --partial test-token-123
  assert_line --partial -- "--config"
}

@test "without a token, nothing reaches GitHub" {
  run bash -c "AGENT_HUB_GITHUB_TOKEN= ; source '$HUB_DIR/lib/github.sh'; gh_api GET /user"
  assert_failure
  assert_output --partial "AGENT_HUB_GITHUB_TOKEN isn't set"
}

@test "pull requests: find, open as a draft, update the description, label" {
  run with_github '
    [ -z "$(gh_pr_find agent-hub/PROJ-1)" ] && echo none
    printf "Body one" | gh_pr_open_draft agent-hub/PROJ-1 main "PROJ-1: a title"
    printf "Body two" | gh_pr_update_body 101
    gh_label 101 agent-hub
    gh_pr_find agent-hub/PROJ-1 | jq -c "{number, draft, body, labels: [.labels[].name], base: .base.ref}"
    gh_pr_find agent-hub/OTHER-1 | wc -c | tr -d " "'
  assert_success
  assert_line --index 0 none
  assert_line --index 1 101
  assert_line --index 2 '{"number":101,"draft":true,"body":"Body two","labels":["agent-hub"],"base":"main"}'
  assert_line --index 3 0
}

@test "visibility: public, or private (internal counts as private)" {
  MOCK_GH_VISIBILITY=public run with_github 'gh_repo_visibility'
  assert_output public
  MOCK_GH_VISIBILITY=private run with_github 'gh_repo_visibility'
  assert_output private
  MOCK_GH_VISIBILITY=internal run with_github 'gh_repo_visibility'
  assert_output private
}

@test "description versions: oldest first, ending with the current one, across every page of history" {
  run with_github 'mock_gh_pr agent-hub/PROJ-1 v1; gh_pr_body_versions 101 | jq -c "map(.body)"'
  assert_output '["v1"]'
  : > "$GH_CALLS"
  rm -rf "$RUNNER_TEMP/mock-github"
  # Five versions, two per page: all of them, in order.
  MOCK_GH_EDITS_PAGE=2 run with_github '
    mock_gh_pr agent-hub/PROJ-1 v1; mock_gh_edit 101 agent-hub-bot v2; mock_gh_edit 101 dana v3
    mock_gh_edit 101 agent-hub-bot v4; mock_gh_edit 101 sam v5
    gh_pr_body_versions 101 | jq -c "map(\"\(.editor):\(.body)\")"'
  assert_output '["agent-hub-bot:v1","agent-hub-bot:v2","dana:v3","agent-hub-bot:v4","sam:v5"]'
  run jq -r 'select(.path == "/graphql") | .path' "$GH_CALLS"
  assert_equal "${#lines[@]}" 3
}

@test "branch lifecycle: absent, orphan, open, foreign, merged, closed, deleted" {
  git_remote
  run with_github 'gh_branch_status agent-hub/PROJ-1 agent-hub'
  assert_output absent
  git push -q origin HEAD:refs/heads/agent-hub/PROJ-1
  run with_github 'gh_branch_status agent-hub/PROJ-1 agent-hub'
  assert_output orphan
  run with_github 'mock_gh_pr agent-hub/PROJ-1 b "[\"agent-hub\"]"; gh_branch_status agent-hub/PROJ-1 agent-hub'
  assert_output "open 101"
  run with_github 'mock_gh_pr agent-hub/PROJ-2 b "[]"; git push -q origin HEAD:refs/heads/agent-hub/PROJ-2; gh_branch_status agent-hub/PROJ-2 agent-hub'
  assert_output "foreign 102"
  run with_github 'mock_gh_pr agent-hub/PROJ-3 b "[\"agent-hub\"]" closed 2026-10-01; gh_branch_status agent-hub/PROJ-3 agent-hub'
  assert_output "merged 103"
  run with_github 'mock_gh_pr agent-hub/PROJ-4 b "[\"agent-hub\"]" closed; gh_branch_status agent-hub/PROJ-4 agent-hub'
  assert_output "closed 104"
  run with_github 'mock_gh_pr agent-hub/PROJ-5 b "[\"agent-hub\"]"; gh_branch_status agent-hub/PROJ-5 agent-hub'
  assert_output "deleted 105"
}

@test "pushes never force: a branch someone else moved on is left as it is" {
  git_remote
  git checkout -q -b agent-hub/PROJ-1
  echo two > file.txt && git commit -qam two
  run with_github 'gh_push agent-hub/PROJ-1 && gh_branch_head agent-hub/PROJ-1'
  assert_success
  assert_output "$(git rev-parse HEAD)"
  # Someone else pushes a commit; the run's own next commit doesn't build on it.
  local theirs
  git clone -q "$BATS_TEST_TMPDIR/remote.git" "$BATS_TEST_TMPDIR/other" 2> /dev/null
  (cd "$BATS_TEST_TMPDIR/other" && git config user.email o@example.com && git config user.name o \
    && git checkout -q agent-hub/PROJ-1 && echo theirs > file.txt && git commit -qam theirs && git push -q origin agent-hub/PROJ-1)
  theirs=$(git -C "$BATS_TEST_TMPDIR/other" rev-parse HEAD)
  echo ours > file.txt && git commit -qam ours
  run with_github 'gh_push agent-hub/PROJ-1'
  assert_failure
  run with_github 'gh_branch_head agent-hub/PROJ-1'
  assert_output "$theirs"
}

@test "rewritten history is detected: a newer head must build on an older one" {
  git_remote
  local first second
  first=$(git rev-parse HEAD)
  echo two > file.txt && git commit -qam two
  second=$(git rev-parse HEAD)
  run with_github "gh_descends $first $second"
  assert_success
  git reset -q --hard "$first" && echo other > file.txt && git commit -qam other
  run with_github "gh_descends $second $(git rev-parse HEAD)"
  assert_failure
}

@test "publication: ticket text goes into a private repository; a public one only by setting" {
  run with_github 'gh_publish_ticket_text private false && echo yes'
  assert_output yes
  run with_github 'gh_publish_ticket_text public false || echo no'
  assert_output no
  run with_github 'gh_publish_ticket_text public true && echo yes'
  assert_output yes
}

@test "every GitHub API call goes through gh_request, and unexpected ones fail" {
  run with_github 'gh_api GET /repos/example/repo/branches'
  assert_failure
  assert_output --partial "mock-github: unexpected request: GET /repos/example/repo/branches"
}

@test "pushes are scanned: exactly the commits the push would send; a finding or a scan that can't run blocks it" {
  git_remote
  git checkout -q -b agent-hub/PROJ-1
  echo two > file.txt && git commit -qam two
  local main_head
  main_head=$(git ls-remote origin refs/heads/main | cut -f1)
  # First push: everything not on the target branch.
  run with_github 'secret_scan() { printf "%s\n" "$@" > "$RUNNER_TEMP/scanned.txt"; }; gh_push agent-hub/PROJ-1 main'
  assert_success
  assert_equal "$(cat "$RUNNER_TEMP/scanned.txt")" "$main_head"
  # Later pushes: everything not already on the branch (or the target).
  local branch_head
  branch_head=$(git rev-parse HEAD)
  echo three > file.txt && git commit -qam three
  run with_github 'secret_scan() { printf "%s\n" "$@" > "$RUNNER_TEMP/scanned.txt"; }; gh_push agent-hub/PROJ-1 main'
  assert_success
  assert_equal "$(cat "$RUNNER_TEMP/scanned.txt")" "$branch_head"$'\n'"$main_head"
  # A finding, or a scan that can't run: nothing is pushed.
  echo four > file.txt && git commit -qam four
  run with_github 'secret_scan() { echo "github-pat in file.txt"; return 1; }; gh_push agent-hub/PROJ-1 main'
  assert_failure 1
  assert_output "github-pat in file.txt"
  run with_github 'secret_scan() { return 2; }; gh_push agent-hub/PROJ-1 main'
  assert_failure 2
  run with_github 'gh_branch_head agent-hub/PROJ-1'
  assert_output "$(git rev-parse HEAD~1)"
}
