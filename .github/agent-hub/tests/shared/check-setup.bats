#!/usr/bin/env bats
# scripts/check-setup.sh: the setup checker reads GitHub (through gh) and
# Jira (through curl) and says, for each part of the setup, verified,
# unverified or blocked — never verified without having checked, and never
# writing anything. gh and curl are stand-ins answering from files.

setup() {
  load ../lib/helpers
  BIN="$BATS_TEST_TMPDIR/bin" GH_FIX="$BATS_TEST_TMPDIR/gh" JIRA_FIX="$BATS_TEST_TMPDIR/jira"
  mkdir -p "$BIN" "$GH_FIX" "$JIRA_FIX"
  export GH_FIX JIRA_FIX CALLS_LOG="$BATS_TEST_TMPDIR/calls"
  # gh api -X GET <path>: <path>'s file, or "HTTP <code>" from its .status file.
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS_LOG"
path=${4:-}; key=$(printf '%s' "$path" | tr -c 'A-Za-z0-9\n' '_')
if [ -f "$GH_FIX/$key.status" ]; then echo "gh: HTTP $(cat "$GH_FIX/$key.status")" >&2; exit 1; fi
[ -f "$GH_FIX/$key.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$GH_FIX/$key.json"
EOF
  # curl … <url>: the file for the path after /rest/api/3/, then its status.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_LOG"
# Held, to be stopped mid-way: says so, then takes a while.
if [ -n "${JIRA_HOLD:-}" ]; then touch "$JIRA_HOLD"; sleep 2; fi
url=${*: -1}; key=$(printf '%s' "${url#*/rest/api/3/}" | tr -c 'A-Za-z0-9\n' '_')
if [ -f "$JIRA_FIX/$key.json" ]; then cat "$JIRA_FIX/$key.json"; printf '\n%s' "$(cat "$JIRA_FIX/$key.status" 2> /dev/null || echo 200)"
else printf '{}\n%s' "$(cat "$JIRA_FIX/$key.status" 2> /dev/null || echo 404)"; fi
EOF
  printf '#!/usr/bin/env bash\necho "${CLAUDE_HERE:-2.1.285} (Claude Code)"\n' > "$BIN/claude"
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH" AGENT_HUB_JIRA_DOMAIN=example.atlassian.net AGENT_HUB_JIRA_EMAIL=bot@example.com AGENT_HUB_JIRA_API_TOKEN=secret-token-123
  CHECK="$HUB_DIR/scripts/check-setup.sh"
  good_setup
}

gh_answer() { printf '%s\n' "$2" > "$GH_FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').json"; rm -f "$GH_FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').status"; }
gh_fails() { printf '%s' "$2" > "$GH_FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').status"; }
jira_answer() { printf '%s' "$2" > "$JIRA_FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').json"; [ -z "${3:-}" ] || printf '%s' "$3" > "$JIRA_FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_').status"; }

# good_setup: the answers of a repository set up as the docs say.
good_setup() {
  local r=repos/o/r
  gh_answer $r '{"default_branch": "main", "visibility": "public"}'
  gh_answer "$r/actions/permissions/fork-pr-contributor-approval" '{"approval_policy": "all_external_contributors"}'
  gh_answer "$r/actions/variables?per_page=100" '{"variables": [{"name": "AGENT_HUB_BUILD_ENABLED", "value": "true"}, {"name": "AGENT_HUB_CLAUDE_CODE_VERSION", "value": "2.1.285"}, {"name": "AGENT_HUB_APPROVERS_GROUP", "value": "agent-hub-approvers"}]}'
  gh_answer "$r/environments/agent-hub" '{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
  gh_answer "$r/environments/agent-hub/deployment-branch-policies" '{"branch_policies": [{"name": "main", "type": "branch"}]}'
  gh_answer "$r/environments/agent-hub/secrets?per_page=100" '{"secrets": [{"name": "AGENT_HUB_JIRA_DOMAIN"}, {"name": "AGENT_HUB_JIRA_EMAIL"}, {"name": "AGENT_HUB_JIRA_API_TOKEN"}, {"name": "AGENT_HUB_GITHUB_TOKEN"}]}'
  gh_answer "$r/actions/secrets?per_page=100" '{"secrets": []}'
  gh_answer "$r/branches/main/protection/required_status_checks" '{"checks": [{"context": "Agent hub: Test", "app_id": 15368}]}'
  gh_answer "$r/rules/branches/main" '[]'
  gh_answer "$r/actions/permissions/workflow" '{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}'
  gh_answer "$r/actions/runners?per_page=100" '{"runners": [{"name": "mac", "status": "online", "labels": [{"name": "self-hosted"}, {"name": "claude"}]}]}'
  gh_answer "$r/labels/agent-hub" '{"name": "agent-hub"}'
  gh_answer "$r/labels/agent-hub-paused" '{"name": "agent-hub-paused"}'
  jira_answer myself '{"displayName": "Agent Hub Bot"}'
  jira_answer project/PROJ/statuses '[{"name": "Task", "statuses": [{"name": "Intake"}, {"name": "Work Order"}, {"name": "Work Order Approved"}, {"name": "Implementation Plan"}, {"name": "Implementation Plan Approved"}, {"name": "Ready for Review"}, {"name": "Approved"}, {"name": "Done"}]}]'
  jira_answer "group/member?groupname=agent-hub-approvers&maxResults=1" '{"total": 2}'
}

check() { run "$CHECK" --repo o/r --jira-project PROJ "$@" < /dev/null; }

@test "check-setup: a setup as the docs say — verified throughout, nothing written, the Jira token never on a command line" {
  check
  assert_success
  assert_line "verified    agent-hub environment — limited to the branch main"
  assert_line "verified    secrets — 4 required, in the environment"
  assert_line "verified    required checks — Agent hub: Test"
  assert_line "verified    runner — online: mac"
  assert_line "verified    pull request labels — agent-hub, agent-hub-paused"
  assert_line "verified    fork pull requests — every outside contributor's workflow runs wait for approval"
  assert_line "verified    Jira credentials — they sign in as Agent Hub Bot — the service account, not you?"
  assert_line "verified    Jira statuses — PROJ's Task has all 8 of the hub's statuses"
  assert_line "verified    approvers group — agent-hub-approvers, 2 member(s)"
  # What it can't check is said, never passed: the hub's own repository has
  # no install record, and the automation rules aren't read.
  assert_line --partial "unverified  hub files — no install record"
  assert_line --partial "unverified  Jira automation rules — not checked here"
  assert_line "15 verified, 2 unverified, 0 blocked."
  # Reads only, and the token goes to curl in a file, not its arguments.
  run grep -vE '^(gh api -X GET |curl -sS -K )' "$CALLS_LOG"
  assert_output ""
  run grep -c secret-token-123 "$CALLS_LOG"
  assert_output 0
}

@test "check-setup: the environment — missing, readable from any branch or another branch, or every protected branch; not readable" {
  rm "$GH_FIX/repos_o_r_environments_agent_hub.json"
  check
  assert_failure
  assert_line --partial "blocked     agent-hub environment — missing: create it, limited to main"
  gh_answer repos/o/r/environments/agent-hub '{"deployment_branch_policy": null}'
  check
  assert_line --partial "blocked     agent-hub environment — any branch's run can read its secrets"
  gh_answer repos/o/r/environments/agent-hub '{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
  gh_answer repos/o/r/environments/agent-hub/deployment-branch-policies '{"branch_policies": [{"name": "main", "type": "branch"}, {"name": "dev", "type": "branch"}]}'
  check
  assert_line --partial "blocked     agent-hub environment — readable from main (branch), dev (branch): limit it to the branch main only"
  # A tag named like the default branch isn't the branch (2.28.1).
  gh_answer repos/o/r/environments/agent-hub/deployment-branch-policies '{"branch_policies": [{"name": "main", "type": "tag"}]}'
  check
  assert_failure
  assert_line --partial "blocked     agent-hub environment — readable from main (tag): limit it to the branch main only"
  refute_line --partial "verified    agent-hub environment"
  gh_answer repos/o/r/environments/agent-hub/deployment-branch-policies '{"branch_policies": [{"name": "main"}]}'
  check
  assert_line --partial "unverified  agent-hub environment — limited to main, but GitHub didn't say whether that's the branch or a tag"
  gh_answer repos/o/r/environments/agent-hub '{"deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}}'
  check
  assert_line --partial "unverified  agent-hub environment — every protected branch can read its secrets"
  gh_fails repos/o/r/environments/agent-hub 403
  check
  assert_line --partial "unverified  agent-hub environment — couldn't be read (HTTP 403; needs admin access)"
}

@test "check-setup: secrets — one missing; the build token only needed with the build on; any of the hub's at the repository level" {
  gh_answer "repos/o/r/environments/agent-hub/secrets?per_page=100" '{"secrets": [{"name": "AGENT_HUB_JIRA_DOMAIN"}, {"name": "AGENT_HUB_JIRA_EMAIL"}, {"name": "AGENT_HUB_JIRA_API_TOKEN"}]}'
  gh_answer "repos/o/r/actions/secrets?per_page=100" '{"secrets": [{"name": "AGENT_HUB_JIRA_API_TOKEN"}, {"name": "OTHER"}]}'
  check
  assert_failure
  assert_line --partial "blocked     secrets — missing from the environment: AGENT_HUB_GITHUB_TOKEN"
  assert_line --partial "blocked     repository-level secrets — AGENT_HUB_JIRA_API_TOKEN: any branch's run can read them"
  gh_answer "repos/o/r/actions/variables?per_page=100" '{"variables": []}'
  check
  assert_line "verified    secrets — 3 required, in the environment"
}

@test "check-setup: variables — a name the hub doesn't read, an inexact Claude Code pin with the build on, runner labels that aren't a list" {
  gh_answer "repos/o/r/actions/variables?per_page=100" '{"variables": [{"name": "AGENT_HUB_BUILD_ENABLED", "value": "true"}, {"name": "AGENT_HUB_CLAUDE_CODE_VERSION", "value": "latest"}, {"name": "AGENT_HUB_BUID_TARGET_BRANCH", "value": "main"}, {"name": "AGENT_HUB_WORK_ORDER_MODEL", "value": "x"}, {"name": "AGENT_HUB_RUNS_ON", "value": "self-hosted"}]}'
  check
  assert_failure
  assert_line --partial "unverified  variable names — AGENT_HUB_BUID_TARGET_BRANCH: not settings the hub reads — a typo?"
  assert_line --partial "blocked     Claude Code pin — the build needs an exact version in AGENT_HUB_CLAUDE_CODE_VERSION, not 'latest'"
  assert_line --partial "blocked     runner labels — AGENT_HUB_RUNS_ON must be a JSON list of labels"
}

@test "check-setup: required checks — none, or one any source can satisfy, or from a ruleset; workflow permissions that aren't read-only" {
  gh_fails repos/o/r/branches/main/protection/required_status_checks 404
  check
  assert_failure
  assert_line --partial "blocked     required checks — main requires none, so the build never hands a pull request off"
  gh_answer repos/o/r/rules/branches/main '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "ci", "integration_id": 15368}, {"context": "lint"}]}}]'
  check
  assert_line "verified    required checks — ci, lint"
  assert_line --partial "blocked     required checks' sources — lint: any source can satisfy them"
  gh_answer repos/o/r/actions/permissions/workflow '{"default_workflow_permissions": "write", "can_approve_pull_request_reviews": false}'
  check
  assert_line --partial "blocked     workflow permissions — set them read-only"
}

# 2.28.1 (Codex M3): either source unread leaves the list incomplete, so
# nothing about it is verified — in both directions.
@test "check-setup: required checks — branch protection or rulesets unreadable: unverified, never verified from part of the list" {
  gh_fails repos/o/r/rules/branches/main 403
  check
  assert_line --partial "unverified  required checks — main's rulesets (HTTP 403) couldn't be read (needs admin access), so the list may be incomplete; known so far: Agent hub: Test"
  assert_line --partial "unverified  required checks' sources — not all of main's required checks could be read"
  refute_line --partial "verified    required checks"
  good_setup
  gh_fails repos/o/r/branches/main/protection/required_status_checks 403
  gh_answer repos/o/r/rules/branches/main '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "ci", "integration_id": 15368}, {"context": "lint"}]}}]'
  check
  assert_failure
  assert_line --partial "unverified  required checks — main's branch protection (HTTP 403) couldn't be read (needs admin access), so the list may be incomplete; known so far: ci, lint"
  # One already known to have no source is wrong, whatever else is unread.
  assert_line --partial "blocked     required checks' sources — lint: any source can satisfy them"
  gh_fails repos/o/r/rules/branches/main 500
  check
  assert_line --partial "unverified  required checks — main's branch protection (HTTP 403) and rulesets (HTTP 500) couldn't be read"
}

@test "check-setup: the runner — none with the labels, offline, not listable, or GitHub-hosted; Claude Code on this machine against the pin" {
  gh_answer "repos/o/r/actions/runners?per_page=100" '{"runners": [{"name": "mac", "status": "online", "labels": [{"name": "self-hosted"}]}]}'
  check
  assert_failure
  assert_line --partial "blocked     runner — no runner has the labels self-hosted, claude"
  gh_answer "repos/o/r/actions/runners?per_page=100" '{"runners": [{"name": "mac", "status": "offline", "labels": [{"name": "self-hosted"}, {"name": "claude"}]}]}'
  check
  assert_line --partial "unverified  runner — mac registered but offline now"
  gh_fails "repos/o/r/actions/runners?per_page=100" 403
  check
  assert_line --partial "unverified  runner — runners couldn't be listed (HTTP 403; needs admin access)"
  gh_answer "repos/o/r/actions/variables?per_page=100" '{"variables": [{"name": "AGENT_HUB_RUNS_ON", "value": "[\"ubuntu-latest\"]"}, {"name": "AGENT_HUB_CLAUDE_CODE_VERSION", "value": "2.1.285"}]}'
  check
  assert_line "verified    runner — GitHub-hosted (ubuntu-latest)"
  CLAUDE_HERE=2.1.299 check
  assert_line --partial "blocked     Claude Code on this machine — 2.1.299, but the pin is 2.1.285"
}

@test "check-setup: fork pull requests — approval for first-time contributors only, unreadable; not checked for a private repository or GitHub-hosted runners" {
  gh_answer "repos/o/r/actions/permissions/fork-pr-contributor-approval" '{"approval_policy": "first_time_contributors"}'
  check
  assert_failure
  assert_line --partial "blocked     fork pull requests — approval is 'first_time_contributors'"
  gh_fails "repos/o/r/actions/permissions/fork-pr-contributor-approval" 403
  check
  assert_line --partial "unverified  fork pull requests — the approval setting couldn't be read (HTTP 403"
  gh_answer repos/o/r '{"default_branch": "main", "visibility": "private"}'
  check
  refute_output --partial "fork pull requests"
  gh_answer repos/o/r '{"default_branch": "main", "visibility": "public"}'
  gh_answer "repos/o/r/actions/variables?per_page=100" '{"variables": [{"name": "AGENT_HUB_BUILD_PREVIEW", "value": "true"}, {"name": "AGENT_HUB_CLAUDE_CODE_VERSION", "value": "2.1.285"}, {"name": "AGENT_HUB_RUNS_ON", "value": "[\"ubuntu-latest\"]"}]}'
  check
  refute_output --partial "fork pull requests"
}

@test "check-setup: Jira — no credentials, rejected ones, statuses missing, a group missing or unreadable; skipped with --no-jira" {
  AGENT_HUB_JIRA_API_TOKEN="" check
  assert_line --partial "unverified  Jira — no credentials given"
  jira_answer myself '{}' 401
  check
  assert_failure
  assert_line --partial "blocked     Jira credentials — rejected: the token and email aren't the same account"
  jira_answer myself '{"displayName": "Agent Hub Bot"}' 200
  jira_answer project/PROJ/statuses '[{"name": "Task", "statuses": [{"name": "Intake"}, {"name": "Work Order"}, {"name": "Done"}]}]'
  jira_answer "group/member?groupname=agent-hub-approvers&maxResults=1" '{}' 404
  check
  assert_line --partial "blocked     Jira statuses — PROJ's Task lacks: Work Order Approved, Implementation Plan, Implementation Plan Approved, Ready for Review, Approved"
  assert_line --partial "blocked     approvers group — no group 'agent-hub-approvers' in Jira"
  jira_answer "group/member?groupname=agent-hub-approvers&maxResults=1" '{}' 403
  check
  assert_line --partial "unverified  approvers group — couldn't be read (HTTP 403; the service account needs Browse users and groups)"
  check --no-jira
  refute_output --partial "Jira"
}

# 2.28.1: the file curl reads the Jira credentials from is removed however the
# script ends (not after a kill -9, which nothing can catch).
@test "check-setup: the Jira credential file is removed when it finishes, fails, or is interrupted or terminated" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  left() { grep -rl secret-token-123 "$TMPDIR" 2> /dev/null || true; }
  check
  assert_equal "$(left)" ""
  jira_answer myself '{}' 401
  check
  assert_failure
  assert_equal "$(left)" ""
  jira_answer myself '{"displayName": "Agent Hub Bot"}' 200
  local case sig pid rc
  for case in TERM:143 INT:130 HUP:129; do
    sig=${case%:*}
    rm -f "$BATS_TEST_TMPDIR/held"
    # A background job starts with INT ignored (and bash can't trap a signal
    # ignored at its start): perl puts it back as a terminal's Ctrl-C finds it.
    JIRA_HOLD="$BATS_TEST_TMPDIR/held" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
      "$CHECK" --repo o/r --jira-project PROJ < /dev/null > /dev/null 2>&1 &
    pid=$!
    # Up to 30 seconds (the whole suite in parallel can slow it well past
    # 5), stopping early if the checker ended before reaching Jira; on any
    # failure here the checker is stopped, so nothing is left running.
    for _ in $(seq 300); do
      [ -e "$BATS_TEST_TMPDIR/held" ] && break
      kill -0 "$pid" 2> /dev/null || break
      sleep 0.1
    done
    if ! [ -e "$BATS_TEST_TMPDIR/held" ]; then
      kill -0 "$pid" 2> /dev/null && { kill -KILL "$pid"; wait "$pid" 2> /dev/null; fail "the checker didn't reach Jira within 30 seconds"; }
      wait "$pid"; fail "the checker ended (status $?) before reaching Jira"
    fi
    # The file is there while it's checking.
    [ -n "$(left)" ] || { kill -KILL "$pid"; wait "$pid" 2> /dev/null; fail "no credential file while checking Jira"; }
    kill -s "$sig" "$pid"
    rc=0
    wait "$pid" || rc=$?
    # Ended by the signal, as the script handles it — not finishing on its own.
    assert_equal "$sig $rc" "$sig ${case#*:}"
    assert_equal "$(left)" ""
  done
}

@test "check-setup: hub files — an installed hub unchanged, then edited" {
  local repo="$BATS_TEST_TMPDIR/installed"
  git init -q -b main "$repo" && cd "$repo" || return 1
  git config user.email t@example.com && git config user.name t
  echo app > app.txt && git add . && git commit -qm app
  "$HUB_DIR/scripts/update.sh" "$REPO_DIR" > /dev/null 2>&1 || {
    mkdir -p "$BATS_TEST_TMPDIR/copy" && rsync -a --exclude node_modules "$REPO_DIR/.github" "$BATS_TEST_TMPDIR/copy/"
    "$HUB_DIR/scripts/update.sh" "$BATS_TEST_TMPDIR/copy" > /dev/null; }
  git add -A && git commit -qm hub
  run .github/agent-hub/scripts/check-setup.sh --repo o/r --no-jira < /dev/null
  assert_line --partial "verified    hub files — The hub's files are unchanged since installation"
  echo "# edited" >> .github/agent-hub/lib/settings.sh
  run .github/agent-hub/scripts/check-setup.sh --repo o/r --no-jira < /dev/null
  assert_failure
  assert_line --partial "blocked     hub files — changed since installation:"
}

@test "check-setup: the pull request labels — the pause label missing; the names set in variables; not readable (2.28.2)" {
  rm "$GH_FIX/repos_o_r_labels_agent_hub_paused.json"
  check
  assert_failure
  assert_line "blocked     pull request labels — agent-hub-paused: not in the repository — create them (gh label create <name>; docs/setup.md)"
  gh_answer "repos/o/r/actions/variables?per_page=100" '{"variables": [{"name": "AGENT_HUB_BUILD_LABEL", "value": "hub"}, {"name": "AGENT_HUB_BUILD_PAUSED_LABEL", "value": "hub paused"}]}'
  gh_answer repos/o/r/labels/hub '{"name": "hub"}'
  gh_answer repos/o/r/labels/hub%20paused '{"name": "hub paused"}'
  check
  assert_line "verified    pull request labels — hub, hub paused"
  gh_fails repos/o/r/labels/hub 403
  check
  assert_line "unverified  pull request labels — couldn't be read (HTTP 403)"
}
