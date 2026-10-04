#!/usr/bin/env bats
# End-to-end paths through the build stage (the shared stage workflow with this
# stage's files, as a code stage): the real step scripts with Jira and GitHub
# mocked, a local git remote, and Claude stubbed — its changes to the
# checkout made by an edits/ script. Each scenario is scenarios/<name>/scenario.env
# plus snapshots in expected/.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
  fresh_repo
}

@test "ready: the plan built, committed as the machine user, pushed and opened as a labelled draft pull request" {
  run_scenario ready --full
  assert_equal "$(remote_branches)" "agent-hub/PROJ-99
main"
  run remote_file agent-hub/PROJ-99 src/greet.js
  assert_output --partial 'Hello, ${name}!'
  run git --git-dir="$REMOTE" log -1 --format='%an <%ae>%n%B' agent-hub/PROJ-99
  assert_line --index 0 "agent-hub-bot <4242+agent-hub-bot@users.noreply.github.com>"
  assert_line --index 1 "feat: greet people by name"
  assert_line "Refs: PROJ-99"
  # The state block: what was approved and the bookkeeping, nothing from the ticket.
  run bash -c "source '$HUB_LIB/state.sh'; jq -r 'select(.path | endswith(\"/pulls\")) | .body.body' '$GH_CALLS' | state_read"
  assert_success
  assert_equal "$(jq -r '[.ticket, .generation, .plan.attachment, .target, .risk, (.items | length)] | join(" ")' <<< "$output")" "PROJ-99 1 10001 main low 0"
}

@test "the agent can't make a later step run its code: the checkout's git hooks and config are ignored" {
  run_scenario ready CLAUDE_EDITS=edits/tamper.sh
  run trace
  assert_line "Apply: success"
  [ ! -e "$RUNNER_TEMP/tampered-hook" ] || fail "the checkout's pre-commit hook ran"
  [ ! -e "$RUNNER_TEMP/tampered-fsmonitor" ] || fail "the checkout's fsmonitor ran"
  # The agent's own commit isn't pushed: the hub's candidate commit, made on
  # the target's head from the agent's working-tree changes, is — and it's the
  # commit the gates checked.
  run git --git-dir="$REMOTE" log --format=%s main..agent-hub/PROJ-99
  assert_output "feat: greet people by name"
  assert_equal "$(git --git-dir="$REMOTE" rev-parse agent-hub/PROJ-99^)" "$(git --git-dir="$REMOTE" rev-parse main)"
  assert_equal "$(git --git-dir="$REMOTE" log -1 --format=%an agent-hub/PROJ-99)" agent-hub-bot
  run jq -r '.files[] | "\(.path) \(.class)"' "$RUNNER_TEMP/gates.json"
  assert_output "src/greet.js expected
test/greet.test.js expected"
  run remote_file agent-hub/PROJ-99 src/greet.js
  assert_output --partial 'Hello, ${name}!'
}

@test "a public repository: no ticket text in the pull request or commit, unless publishing is on" {
  run_scenario ready MOCK_GH_VISIBILITY=public
  run jq -r 'select(.path | endswith("/pulls")) | .body | .title, .body' "$GH_CALLS"
  assert_line --index 0 "PROJ-99: build from the approved plan"
  refute_output --partial "Greet people by name"
  refute_output --partial "Hello, Ada"
  refute_output --partial "example.atlassian.net"
  assert_output --partial "Ticket: PROJ-99 ·"
  run git --git-dir="$REMOTE" log -1 --format=%s agent-hub/PROJ-99
  assert_output "Build PROJ-99 from its approved implementation plan"
  fresh_repo
  run_scenario ready MOCK_GH_VISIBILITY=public 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_PUBLISH_TICKET_CONTENT": "true"}'
  run jq -r 'select(.path | endswith("/pulls")) | .body.title' "$GH_CALLS"
  assert_output "PROJ-99: Greet people by name"
}

@test "a change outside the plan: pushed, with a decision item for a person" {
  run_scenario decision-item --full
}

@test "a file the hub never pushes (.github/): nothing pushed" {
  run_scenario refused
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial ".github/workflows/ci.yml"
  # The path came from the agent's changes: on the ticket, never in the log.
  run grep -c "ci.yml" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "a secret in the changes: nothing pushed, the file named only on the ticket" {
  run_scenario secret
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "github-pat in src/config.js"
  run grep -c "config.js" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "the agent changed nothing: nothing pushed" {
  run_scenario ready CLAUDE_EDITS=""
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "changed no files"
}

@test "a plan file uploaded during the run: the approval is stale, nothing pushed" {
  run_scenario ready ATTACHMENTS_LATER_FIXTURE=attachments-newer.json
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "plan files changed while the build was running"
}

@test "the build doesn't say how a criterion is verified: nothing pushed" {
  run_scenario ready 'CLAUDE_FIXTURE_EDIT=.structured_output.build.verification |= .[:1]'
  run trace
  assert_line "Agent: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "acceptance criteria 2 (by position"
}

@test "needs clarification: the questions added to a new plan version, back to Implementation Plan" {
  run_scenario needs-clarification --full
}

@test "no change needed: explained on the ticket, flagged, no branch" {
  run_scenario no-change-needed
  assert_equal "$(remote_branches)" "main"
}

@test "blocked: the failure notice carries Claude's reason, the log doesn't" {
  run_scenario blocked
  run failure_notice
  assert_output --partial "the sandbox has no network"
  run grep -c "the sandbox has no network" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "a plan file changed after the approval: back to Implementation Plan before Claude runs" {
  run_scenario approval-stale
}

@test "no approval to build from: never approved, or moved there by the automation account" {
  run_scenario ready CHANGELOG_FIXTURE=changelog-never-approved.json
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "no move to Implementation Plan Approved"
  run_scenario ready CHANGELOG_FIXTURE=changelog-approved-by-automation.json
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "made by the automation account"
}

@test "a plan written before Scope & Governance: not built, revise it first" {
  run_scenario ready ATTACHMENT_CONTENT_FIXTURE=plan-before-governance.md
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "no Scope & Governance section"
}

@test "only manual changes: listed on the ticket, flagged, no Claude run" {
  run_scenario manual-only
}

@test "the branch already exists: nothing built, a person decides" {
  fresh_repo agent-hub/PROJ-99
  run_scenario ready MOCK_STATUS="Implementation Plan Approved"
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "exists with no pull request"
}

# Closing a pull request and deleting its branch say what state it's in, not
# that a person wants a new build: that takes an approval after the close.
@test "an earlier pull request: open, or closed with its branch, stops the build; closed, branch deleted and the plan approved since, it builds again" {
  # The fixture's approval is at 10:00.
  jq -n '[{number: 100, head: {ref: "agent-hub/PROJ-99"}, base: {ref: "main"}, title: "t", body: "b", draft: true,
    state: "closed", merged_at: null, closed_at: "2026-10-01T11:00:00Z", labels: [{name: "agent-hub"}],
    versions: [{editor: "agent-hub-bot", body: "b"}]}]' > "$BATS_TEST_TMPDIR/closed.json"
  jq '.[0].state = "open" | .[0].closed_at = null' "$BATS_TEST_TMPDIR/closed.json" > "$BATS_TEST_TMPDIR/open.json"
  jq '.[0].closed_at = "2026-10-01T09:30:00Z"' "$BATS_TEST_TMPDIR/closed.json" > "$BATS_TEST_TMPDIR/closed-before.json"
  fresh_repo agent-hub/PROJ-99
  run_scenario ready MOCK_GH_PRS_FIXTURE="$BATS_TEST_TMPDIR/open.json"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "already has the hub's pull request #100"
  run_scenario ready MOCK_GH_PRS_FIXTURE="$BATS_TEST_TMPDIR/closed.json"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "closed unmerged and its branch is still there"
  # Branch deleted, but closed after the latest approval: no new approval, no build.
  fresh_repo
  run_scenario ready MOCK_GH_PRS_FIXTURE="$BATS_TEST_TMPDIR/closed.json"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "closed unmerged after the plan's latest approval"
  assert_equal "$(remote_branches)" "main"
  # Branch deleted and the plan approved since the close: built again.
  run_scenario ready MOCK_GH_PRS_FIXTURE="$BATS_TEST_TMPDIR/closed-before.json"
  run trace
  assert_line "Apply: success"
  assert_equal "$(remote_branches)" "agent-hub/PROJ-99
main"
}

# Until the install step (3c), builds run only where a repository opts in.
@test "not enabled (AGENT_HUB_BUILD_PREVIEW unset): fails before Claude, GitHub or the plan, saying why" {
  run_scenario ready VARS=
  run trace
  assert_line "Fetch ticket: failure"
  assert_line "Agent: skipped"
  [ ! -s "$GH_CALLS" ] || fail "GitHub was called"
  run writes
  refute_line "GET /attachment/content/10001"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "isn't enabled for real tickets yet"
}

@test "not in Implementation Plan Approved: nothing happens" {
  run_scenario not-in-plan-approved
}
