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
  # The ticket: the whole report as a comment, and the Delivery sections —
  # the link and the testing steps — with needs-human, in one update.
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | [.. | objects | select(.type == "text") | .text] | join("")' "$CALLS"
  assert_output --partial "Draft pull request opened"
  assert_output --partial 'greet("Ada") returns "Hello, Ada!" — updated test'
  assert_output --partial "node --test — passed: 2 tests passed."
  assert_output --partial "An empty name greets without one"
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | .body' "$CALLS"
  assert_equal "$(jq -r '.update.labels | tostring' <<< "$output")" '[{"add":"needs-human"}]'
  assert_equal "$(jq -r -L "$HUB_LIB" 'include "adf"; .fields.description | section_blocks("Pull Request") | tostring | test("pull/101")' <<< "$output")" true
  assert_equal "$(jq -r -L "$HUB_LIB" 'include "adf"; [.fields.description | section_blocks("Testing Instructions")[] | .. | objects | select(.type == "taskItem") | .attrs.state] | join(" ")' <<< "$output")" DONE
}

@test "a description without the Delivery sections: the report comment has it all, and only the label is added" {
  jq 'del(.fields.description.content[] | select(.type == "heading" and (.content[0].text | IN("Testing Instructions", "Pull Request"))))' \
    "$FIXTURES/tickets/plan-approved.json" > "$BATS_TEST_TMPDIR/no-delivery.json"
  run_scenario ready TICKET_FIXTURE="$BATS_TEST_TMPDIR/no-delivery.json"
  run trace
  assert_line "Apply: success"
  run writes
  refute_line --regexp '^PUT \?notifyUsers'
  assert_line "PUT "
  run grep -c "no Pull Request or Testing Instructions section" "$RUNNER_TEMP/log.txt"
  assert_output 1
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
  # Claude's command strings could carry ticket text too (a canary here).
  run_scenario ready MOCK_GH_VISIBILITY=public \
    'CLAUDE_FIXTURE_EDIT=.structured_output.build.tests_run[0].command = "node check.js --customer PRIVATE-CANARY"'
  run jq -r 'select(.path | endswith("/pulls")) | .body | .title, .body' "$GH_CALLS"
  # The title says what the hub itself knows: the files changed.
  assert_line --index 0 "PROJ-99: change src/greet.js and test/greet.test.js"
  assert_output --partial "are on the ticket, not here"
  assert_output --partial "1. Criterion 1 (on the ticket) — verified by **updated test**"
  assert_output --partial '- `src/greet.js` — modified, +2 −2 — expected'
  refute_output --partial "Greet people by name"
  refute_output --partial "Hello, Ada"
  refute_output --partial "example.atlassian.net"
  refute_output --partial "PRIVATE-CANARY"
  assert_output --partial "- Check 1 — **passed**"
  assert_output --partial "for **PROJ-99**. This repository is public"
  run git --git-dir="$REMOTE" log -1 --format=%s agent-hub/PROJ-99
  assert_output "Build PROJ-99 from its approved implementation plan"
  fresh_repo
  run_scenario ready MOCK_GH_VISIBILITY=public 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_PUBLISH_TICKET_CONTENT": "true"}' \
    'CLAUDE_FIXTURE_EDIT=.structured_output.build.commit_message = "feat: greet\n\nCo-authored-by: Someone <s@example.com>\nSigned-off-by: X <x@example.com>"'
  run jq -r 'select(.path | endswith("/pulls")) | .body.title' "$GH_CALLS"
  assert_output "PROJ-99: Greet people by name"
  # Claude's message, without trailers that would attribute the commit.
  run git --git-dir="$REMOTE" log -1 --format=%B agent-hub/PROJ-99
  assert_line --index 0 "feat: greet"
  refute_output --partial "Co-authored-by"
  refute_output --partial "Signed-off-by"
  assert_line "Refs: PROJ-99"
}

@test "a change outside the plan: pushed, with a decision item for a person" {
  run_scenario decision-item --full
}

@test "a file the hub never pushes (.github/): nothing pushed" {
  run_scenario ready CLAUDE_EDITS=edits/workflow.sh
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial ".github/workflows/ci.yml"
  # The path came from the agent's changes: on the ticket, never in the log.
  run grep -c "ci.yml" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "a secret in the changes: nothing pushed, the file named only on the ticket" {
  run_scenario ready CLAUDE_EDITS=edits/secret.sh
  run trace
  assert_line "Apply: failure"
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

@test "a plan file uploaded during the run: while the plan downloads, back to be approved again; later, nothing pushed" {
  run_scenario ready ATTACHMENTS_LATER_FIXTURE=attachments-newer.json ATTACHMENTS_LATER_FROM=2
  run trace
  assert_line "Agent: skipped"
  run writes
  assert_line 'POST /transitions'
  run_scenario ready ATTACHMENTS_LATER_FIXTURE=attachments-newer.json ATTACHMENTS_LATER_FROM=3
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "approval changed while the build was running"
}

# The history and the attachments are separate reads: a plan uploaded between
# them is in the attachments but not (yet) in the history.
@test "approval check: a plan newer than the approval, the work order edited since, or an older plan removed during the run" {
  run_scenario ready ATTACHMENTS_FIXTURE=attachments-newer.json
  run trace
  assert_line "Agent: skipped"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
  jq '.total = 3 | .values += [{"created": "2026-10-01T10:30:00.000+0000", "author": {"accountId": "dana-lead"},
    "items": [{"field": "description", "fromString": "a", "toString": "b"}]}]' "$FIXTURES/changelog-approved.json" \
    > "$BATS_TEST_TMPDIR/edited.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/edited.json"
  run trace
  assert_line "Agent: skipped"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
  jq '[{"id": "10000", "filename": "PROJ-99-implementation-plan.md", "created": "2026-10-01T08:00:00.000+0000"}] + .' \
    "$FIXTURES/attachments.json" > "$BATS_TEST_TMPDIR/two-plans.json"
  run_scenario ready ATTACHMENTS_FIXTURE="$BATS_TEST_TMPDIR/two-plans.json" \
    ATTACHMENTS_LATER_FIXTURE="$FIXTURES/attachments.json" ATTACHMENTS_LATER_FROM=3
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
}

# A time that can't be read can't show the plan predates the approval.
@test "approval check: a plan file's time that can't be read counts as stale" {
  jq '.[0].created = "yesterday"' "$FIXTURES/attachments.json" > "$BATS_TEST_TMPDIR/odd-time.json"
  run_scenario ready ATTACHMENTS_FIXTURE="$BATS_TEST_TMPDIR/odd-time.json"
  run trace
  assert_line "Agent: skipped"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
}

@test "approval check: the automation account can't be identified → nothing built" {
  run_scenario ready 'MOCK_FAIL=GET /myself'
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "Couldn't identify Jira's automation account"
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

# The build's sandbox rests on the Claude Code version, so it runs only with
# an exact pinned version that the runner has — checked before any Claude use.
@test "Claude Code version: unpinned, 'latest' or a mismatch stops the build before Claude, GitHub or the plan" {
  local vars
  for vars in '{"AGENT_HUB_BUILD_PREVIEW": "true"}' \
      '{"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "latest"}'; do
    run_scenario ready VARS="$vars"
    run trace
    assert_line "Agent: skipped"
    [ ! -s "$GH_CALLS" ] || fail "GitHub was called"
    run cat "$RUNNER_TEMP/failure-reason"
    assert_output --partial "needs an exact Claude Code version"
  done
  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "2.1.280"}'
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "The runner has Claude Code 9.9.9, but AGENT_HUB_CLAUDE_CODE_VERSION pins 2.1.280"
  run writes
  refute_line "GET /attachment/content/10001"
}

# Absent when the run started, the branch is created by someone else while the
# agent works — at the run's own base, so a plain push would fast-forward it.
@test "the branch created during the run (even at the same commit): nothing pushed to it" {
  cat > "$BATS_TEST_TMPDIR/race.sh" <<SH
git push -q origin HEAD:refs/heads/agent-hub/PROJ-99
bash -e "$FIXTURES/edits/greet.sh"
SH
  run_scenario ready CLAUDE_EDITS="$BATS_TEST_TMPDIR/race.sh"
  run trace
  assert_line "Apply: failure"
  assert_equal "$(git --git-dir="$REMOTE" rev-parse agent-hub/PROJ-99)" "$(git --git-dir="$REMOTE" rev-parse main)"
  run failure_notice
  assert_output --partial "GitHub rejected the push"
}

# A hard link could carry a file from elsewhere on the runner into the commit.
@test "a hard link in the changes: nothing committed or pushed, the file named only on the ticket" {
  cat > "$BATS_TEST_TMPDIR/link.sh" <<SH
bash -e "$FIXTURES/edits/greet.sh"
ln src/greet.js src/linked.js
SH
  run_scenario ready CLAUDE_EDITS="$BATS_TEST_TMPDIR/link.sh"
  run trace
  assert_line "Apply: failure"
  assert_equal "$(remote_branches)" "main"
  run failure_notice
  assert_output --partial "hard links"
  assert_output --partial "src/linked.js"
  run grep -c "linked.js" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "a size limit that isn't a whole number stops the build before Claude, GitHub or the plan" {
  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_MAX_FILES": "many"}'
  run trace
  assert_line "Agent: skipped"
  [ ! -s "$GH_CALLS" ] || fail "GitHub was called"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "AGENT_HUB_BUILD_MAX_FILES must be a whole number"
}

@test "not in Implementation Plan Approved: nothing happens" {
  run_scenario ready MOCK_STATUS="Implementation Plan"
  run trace
  assert_line "Agent: skipped"
  run writes
  assert_output ""
  [ ! -s "$GH_CALLS" ] || fail "GitHub was called"
}
