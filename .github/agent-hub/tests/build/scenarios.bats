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
  assert_output --partial "Not checked by the build: Needs a browser"
  assert_output --partial "stays in Implementation Plan Approved until then"
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | .body' "$CALLS"
  assert_equal "$(jq -r '.update.labels | tostring' <<< "$output")" '[{"add":"needs-human"}]'
  assert_equal "$(jq -r -L "$HUB_LIB" 'include "adf"; .fields.description | section_blocks("Pull Request") | tostring | test("pull/101")' <<< "$output")" true
  # Testing Instructions: the reviewer's own checklist (every box open), each
  # step with what to expect, and which ones the build already saw pass.
  run jq -r -L "$HUB_LIB" 'include "adf"; .fields.description | section_blocks("Testing Instructions")[]
    | select(.type == "taskList") | .content[] | "\(.attrs.state) \(plain_text)"' <<< "$output"
  assert_line --index 0 --partial "TODO node -e 'import(\"./src/greet.js\")"
  assert_line --index 0 --partial "— expect: Prints Hello, Ada! (the build saw this)"
  assert_line --index 1 "TODO Open the greeter in the browser demo and enter Ada — expect: The page shows Hello, Ada! (not checked by the build: Needs a browser, which the sandbox doesn't have.)"
  run jq -r 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | .body' "$CALLS"
  # Pull Request: the link, what changed and each file.
  assert_equal "$(jq -r -L "$HUB_LIB" 'include "adf"; [.fields.description | section_blocks("Pull Request")[] | plain_text] | join("\n")' <<< "$output")" \
    "#101 — a draft on agent-hub/PROJ-99, opened by the build from the approved plan. The 🔨 comment has the build’s full report.
$(jq -r '.structured_output.build.summary' "$FIXTURES/claude/ready.json")
src/greet.js — modified, +2 −2test/greet.test.js — modified, +4 −0"
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
  assert_output --partial "1. Criterion 1 (on the ticket) — verified by **an updated test**"
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
  assert_line "Verify: failure"
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
  # The comment says what a person does first — not "approve again or
  # re-run", which would stop here again. (It failed before the progress
  # comment, so the notice is a comment of its own.)
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "To try again, close pull request #100 and delete agent-hub/PROJ-99"
  refute_output --partial "re-run"
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
  assert_line "Verify: failure"
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
  # A time limit of 0 would be no limit at all.
  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_CHECK_MINUTES": "0"}'
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "AGENT_HUB_BUILD_CHECK_MINUTES must be a whole number of minutes, at least 1"
}

@test "not in Implementation Plan Approved: nothing happens" {
  run_scenario ready MOCK_STATUS="Implementation Plan"
  run trace
  assert_line "Agent: skipped"
  run writes
  assert_output ""
  [ ! -s "$GH_CALLS" ] || fail "GitHub was called"
}

# srt_calls: the sandbox runtime's calls (the stand-in's record, lib/bin/srt).
srt_calls() { cat "$RUNNER_TEMP/sandbox/srt-calls.jsonl" 2> /dev/null || true; }

@test "the hub's checks: run on the build's commit in the sandbox with no network, shown as the hub's on the pull request and ticket" {
  run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Verify: success"
  assert_line "Apply: success"
  # Before the agent, the rehearsal (the toolchain starting in the sandbox)
  # and the baseline (the check on the base commit); then the check on the
  # build's commit (the fixture's test script) — sandboxed: no network but
  # localhost, the home folder unreadable, writes only to its copy and temp.
  run srt_calls
  assert_equal "$(jq -sr 'map(.command) | join(" | ")' <<< "$output")" \
    "if command -v node > /dev/null; then node --version; fi | npm run test | npm run test"
  output=$(jq -sc '.[-1]' <<< "$output")
  assert_equal "$(jq -c '.settings.network' <<< "$output")" '{"allowedDomains":[],"deniedDomains":[],"allowLocalBinding":true}'
  assert_equal "$(jq -r '.settings.filesystem.denyRead[0]' <<< "$output")" "$HOME"
  assert_equal "$(jq -r '.cwd' <<< "$output")" "$(cd "$RUNNER_TEMP/verify" && pwd -P)"
  assert_equal "$(jq -r '.settings.filesystem.allowWrite | length' <<< "$output")" 2
  # The copy is sparse like the checkout: the hub's test data left out.
  [ -f "$RUNNER_TEMP/verify/src/greet.js" ]
  [ ! -e "$RUNNER_TEMP/verify/.github/agent-hub/tests/demo" ]
  # The run log names the check and its result, nothing it printed.
  run grep -c "^Check test: passed" "$RUNNER_TEMP/log.txt"
  assert_output 1
  run grep -c "^Baseline check test: passed" "$RUNNER_TEMP/log.txt"
  assert_output 1
  run grep -c "greets by name" "$RUNNER_TEMP/log.txt"
  assert_output 0
  # The pull request and the ticket show the hub's result.
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_output --partial "Checks run by the hub"
  assert_output --partial "npm run test"
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | [.. | objects | select(.type == "text") | .text] | join("")' "$CALLS"
  assert_output --partial "npm run test"
}

@test "a check fails on the build's commit: nothing pushed, its output on the ticket only" {
  run_scenario ready CLAUDE_EDITS=edits/failing-test.sh
  run trace
  assert_line "Verify: failure"
  assert_line "Apply: skipped"
  assert_equal "$(remote_branches)" "main"
  [ ! -s "$GH_CALLS" ] || [ "$(jq -s 'map(select(.method != "GET")) | length' "$GH_CALLS")" = 0 ] || fail "GitHub was written to"
  run failure_notice
  assert_output --partial "test (failed)"
  assert_output --partial "Nothing was pushed"
  # The next comment: the command and the end of its output.
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "🧪 Checks that failed"
  assert_output --partial "npm run test"
  assert_output --partial "Bonjour, Ada!"
  # Never in the run log.
  run grep -c "Bonjour" "$RUNNER_TEMP/log.txt"
  assert_output 0
  assert_valid_adf "$CALLS"
}

@test "a Node project that doesn't declare its Node version: nothing built, before Claude" {
  rm "$STEP_CWD/.nvmrc" && change_main "No .nvmrc"
  run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Fetch ticket: failure"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "doesn't declare its Node version"
  assert_output --partial "Add an .nvmrc"
}

@test "dependencies without a lockfile: nothing built, before Claude" {
  jq '.dependencies = {"left-pad": "1.3.0"}' "$STEP_CWD/package.json" > "$BATS_TEST_TMPDIR/package.json"
  cp "$BATS_TEST_TMPDIR/package.json" "$STEP_CWD/package.json"
  change_main "A dependency"
  run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "no lockfile"
}

@test "the install: npm ci from the lockfile, sandboxed with the registries only; one that changes the repository stops the build" {
  # A stand-in npm that records its arguments; with DIRTY set, it also
  # leaves a file the repository doesn't ignore.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/npm" <<SH
#!/usr/bin/env bash
case "\$1" in ci) echo "\$*" >> "$BATS_TEST_TMPDIR/npm-calls"; [ ! -f "$BATS_TEST_TMPDIR/dirty" ] || touch installed.txt ;;
  *) exec "$(command -v npm)" "\$@" ;; esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/npm"
  echo '{"lockfileVersion": 3, "packages": {}}' > "$STEP_CWD/package-lock.json"
  change_main "A lockfile"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: success"
  assert_line "Verify: success"
  # Installed three times: in the checkout for the agent, in the verify
  # step's rehearsal before the agent, and in the verify copy.
  run cat "$BATS_TEST_TMPDIR/npm-calls"
  assert_equal "$output" "ci --no-audit --no-fund
ci --no-audit --no-fund
ci --no-audit --no-fund"
  run srt_calls
  assert_equal "$(jq -sc 'map(select(.command | startswith("npm ci"))) | .[0].settings.network' <<< "$output")" \
    '{"allowedDomains":["registry.npmjs.org","registry.yarnpkg.com","repo.yarnpkg.com"],"deniedDomains":[],"allowLocalBinding":false}'

  fresh_repo
  echo '{"lockfileVersion": 3, "packages": {}}' > "$STEP_CWD/package-lock.json"
  change_main "A lockfile"
  touch "$BATS_TEST_TMPDIR/dirty"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "changed files in the repository"
}

@test "only the commit the checks passed on is pushed" {
  run_scenario ready CANCEL_AFTER=verify
  run trace
  assert_line "Verify: success"
  assert_line "Apply: skipped"
  # Apply, with the verify result naming another commit.
  jq '.head = "0000000000000000000000000000000000000000"' "$RUNNER_TEMP/verify.json" > "$BATS_TEST_TMPDIR/verify.json"
  cp "$BATS_TEST_TMPDIR/verify.json" "$RUNNER_TEMP/verify.json"
  run run_step "$STEPS" apply
  assert_failure
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "isn't the one the checks passed on"
  assert_equal "$(remote_branches)" "main"
}

@test "the verify step rehearsed before Claude: an environment that can't run the checks stops the build before the agent" {
  # The sandbox runtime can't be installed (npm fails): found by the install
  # step's rehearsal, not after Claude has run.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "npm ERR! network" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/npm"
  chmod +x "$BATS_TEST_TMPDIR/bin/npm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_scenario ready MOCK_SRT=0 CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  assert_line "Verify: skipped"
  assert_equal "$(remote_branches)" "main"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "The sandbox runtime the checks run in couldn't be installed"
  assert_output --partial "nothing was built"
}

@test "the verify step rehearsed before Claude: a toolchain the sandbox can't start stops the build before the agent" {
  # Node aborting in the sandbox, as on a runner where it couldn't read its
  # own output file (2.6.1): the rehearsal runs it once before the agent.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/node" <<SH
#!/usr/bin/env bash
[ "\$1" != --version ] || { echo "Process killed by signal: SIGABRT" >&2; exit 134; }
exec "$(command -v node)" "\$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/node"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "The sandbox the checks run in can't run commands on this runner (exit 134)"
  assert_output --partial "SIGABRT"
  # The output reaches the ticket only, never the run log.
  run grep -c "SIGABRT" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

# A fixture project whose test already fails on main (before the agent).
break_main() {
  printf 'import test from "node:test";\ntest("already broken", () => { throw new Error("Broken before the build"); });\n' \
    > "$STEP_CWD/test/broken.test.js"
  change_main "A failing test"
}

@test "baseline: a check already failing on the target stops the build before Claude, its output on the ticket" {
  break_main
  run_scenario ready CLAUDE_EDITS=edits/greet.sh
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  assert_equal "$(remote_branches)" "main"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "already fail on main, before the agent: test (failed)"
  assert_output --partial "Claude wasn't used"
  assert_output --partial "AGENT_HUB_BUILD_BASELINE to warn"
  # Run twice (a flaky test gets a second chance), then the output on the
  # ticket only.
  run grep -c "^Baseline check test: failed" "$RUNNER_TEMP/log.txt"
  assert_output 1
  assert_equal "$(srt_calls | jq -s 'map(select(.command == "npm run test")) | length')" 2
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "🧪 Checks that failed"
  assert_output --partial "already fail (each run twice), so nothing was built"
  assert_output --partial "Broken before the build"
  run grep -c "Broken before the build" "$RUNNER_TEMP/log.txt"
  assert_output 0
  assert_valid_adf "$CALLS"
}

@test "baseline: warn builds anyway (a plan that fixes the check); off skips it; anything else is refused" {
  break_main
  # The agent fixes it: removes the failing test along with the plan's change.
  printf 'bash -e "%s"\nrm test/broken.test.js\n' "$FIXTURES/edits/greet.sh" > "$BATS_TEST_TMPDIR/fix.sh"
  run_scenario ready CLAUDE_EDITS="$BATS_TEST_TMPDIR/fix.sh" \
    'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_BASELINE": "warn"}'
  run trace
  assert_line "Install dependencies: success"
  assert_line "Verify: success"
  assert_line "Apply: success"
  run grep -c "already fail on main before the agent runs: test (failed)" "$RUNNER_TEMP/log.txt"
  assert_output 1

  fresh_repo
  break_main
  run_scenario ready CLAUDE_EDITS="$BATS_TEST_TMPDIR/fix.sh" \
    'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_BASELINE": "off"}'
  run trace
  assert_line "Apply: success"
  run grep -c "^Baseline check" "$RUNNER_TEMP/log.txt"
  assert_output 0

  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_BASELINE": "sometimes"}'
  run trace
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "AGENT_HUB_BUILD_BASELINE must be stop, warn or off"
}

@test "baseline: a check failing after the build that also failed before it says so" {
  break_main
  run_scenario ready CLAUDE_EDITS=edits/greet.sh \
    'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_BASELINE": "warn"}'
  run trace
  assert_line "Verify: failure"
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "it also failed before the agent ran"
}

@test "wording: an expected result ending in a full stop gets one, criteria read 'verified manually' or 'by a …', counts are plural only when they should be" {
  run_scenario ready MOCK_GH_VISIBILITY=public CLAUDE_EDITS=edits/greet.sh \
    'CLAUDE_FIXTURE_EDIT=.structured_output.build.review_steps[0].expected = "Prints Hello, Ada." | .structured_output.build.verification[1].method = "manual"'
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_line "1. Criterion 1 (on the ticket) — verified by **an updated test**"
  assert_line "2. Criterion 2 (on the ticket) — verified **manually**"
  assert_line "2 steps with their expected results, 1 already seen to pass by the build: they're on the ticket, under Testing Instructions."
  run jq -r 'select(.method != "GET") | .body | tostring' "$CALLS"
  assert_output --partial "expect: Prints Hello, Ada (the build saw this)"
  assert_output --partial "expect: Prints Hello, Ada. "
  refute_output --partial "Ada.."
}

# --- Dependency changes (dependencies.sh) ------------------------------------

# deps_plan [sed expression]: the plan with a dependency change (left-pad
# ^1.3.0, runtime, at the root), edited by the expression.
# Each in a file of its own.
deps_plan() {
  local plan
  plan=$(mktemp "$BATS_TEST_TMPDIR/plan-deps.XXXXXX") && sed "${1:-}" "$FIXTURES/plan-dependencies.md" > "$plan" && echo "$plan"
}

# deps_run [VAR=value...]: the ready scenario with that plan (DEPS_PLAN, or
# deps_plan's), the stand-in npm and the plan's change (greet.sh).
deps_run() { PATH="$NPM_STUB:$PATH" run_scenario ready ATTACHMENT_CONTENT_FIXTURE="${DEPS_PLAN:-$(deps_plan)}" CLAUDE_EDITS=edits/greet.sh "$@"; }

failure() { cat "$RUNNER_TEMP/failure-reason"; }

@test "dependency changes: applied before the agent (exact range, minimum release age, no install scripts), checked, installed, pushed byte for byte, on the pull request and ticket" {
  stub_npm
  npm_project
  touch "$NPM_STUB/attested"
  # The agent starts with the change applied and installed.
  printf 'jq -e %q package.json > /dev/null && [ -d node_modules/left-pad ] && touch %q\nbash -e %q\n' \
    '.dependencies["left-pad"] == "^1.3.0"' "$BATS_TEST_TMPDIR/agent-saw-it" "$FIXTURES/edits/greet.sh" > "$BATS_TEST_TMPDIR/edits.sh"
  deps_run CLAUDE_EDITS="$BATS_TEST_TMPDIR/edits.sh"
  run trace
  assert_line "Install dependencies: success"
  assert_line "Verify: success"
  assert_line "Apply: success"
  [ -f "$BATS_TEST_TMPDIR/agent-saw-it" ] || fail "the agent didn't start with the dependency change installed"
  # Resolved without install scripts, only from versions on or before the
  # cut-off (now − 3 × 24 h); each new version's time read from the registry.
  run grep -- "--package-lock-only" "$NPM_STUB/calls"
  assert_output --partial "--ignore-scripts"
  assert_output --partial "--before=$(perl -MPOSIX -e 'print strftime("%Y-%m-%d", gmtime(time - 86400 * 3))')T"
  run grep -c " view left-pad time --json" "$NPM_STUB/calls"
  assert_output 1
  run grep -c "audit signatures" "$NPM_STUB/calls"
  assert_output 1
  # Pushed exactly as the hub produced it; the gates pass both files.
  assert_equal "$(remote_file agent-hub/PROJ-99 package.json | jq -r '.dependencies["left-pad"]')" "^1.3.0"
  assert_equal "$(remote_file agent-hub/PROJ-99 package-lock.json | jq -r '.packages["node_modules/left-pad"].version')" "1.3.0"
  assert_equal "$(jq -c '[.files[] | select(.path | test("package")) | .class] , (.decisions | length)' "$RUNNER_TEMP/gates.json" | paste -sd ' ' -)" '["expected","expected"] 0'
  # On the pull request and the ticket.
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_output --partial "## Dependency changes"
  assert_output --partial "only versions published at least 3 days ago"
  assert_output --partial '- `.`: add `left-pad@^1.3.0` (runtime) → 1.3.0, licence MIT'
  assert_output --partial "1 package added, 0 changed, 0 removed; every new version published on or before"
  assert_output --partial "registry signatures verified for 1 package (1 with provenance); known advisories: 0 before, 0 after, none new; every new package’s licence on the allowed list"
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "Dependency changes — applied by the hub before the agent ran"
  assert_valid_adf "$CALLS"
}

@test "dependency changes in a subfolder: applied and installed there only, for the build and its checks" {
  stub_npm
  npm_project web
  DEPS_PLAN=$(deps_plan 's/`\.`: add/`web`: add/') deps_run
  run trace
  assert_line "Apply: success"
  # Installed in web/ for the agent, the rehearsal's copy and the verify copy.
  assert_equal "$(grep -cE '^web (.* )?ci( |$)' "$NPM_STUB/calls")" 3
  assert_equal "$(remote_file agent-hub/PROJ-99 web/package.json | jq -r '.dependencies["left-pad"]')" "^1.3.0"
  [ "$(remote_file agent-hub/PROJ-99 package.json | jq -r '.dependencies["left-pad"] // "none"')" = none ]
}

@test "dependency changes: no minimum release age means no cut-off; licences outside the allowed list (direct or transitive), new moderate advisories and a lockfile format change are decision items" {
  stub_npm
  npm_project
  echo GPL-3.0-only > "$NPM_STUB/license-left-pad"
  touch "$NPM_STUB/extra-tiny-dep" && echo "(MIT AND SSPL-1.0)" > "$NPM_STUB/license-tiny-dep"
  echo moderate > "$NPM_STUB/advisory-left-pad"
  touch "$NPM_STUB/lockfile-v2"
  deps_run 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS": "0"}'
  run trace
  assert_line "Apply: success"
  run grep -c -e "--before" -e " view " "$NPM_STUB/calls"
  assert_output 0
  run jq -r '.decisions[] | "\(.path): \(.reason)"' "$RUNNER_TEMP/gates.json"
  assert_line "package.json: the plan adds left-pad (licence GPL-3.0-only), outside the allowed licences — a person decides"
  assert_line "package-lock.json: the plan’s dependency changes bring in 1 package whose licence is outside the allowed list (tiny-dep@1.3.0: (MIT AND SSPL-1.0)) — a person decides; the plan’s dependency changes add 1 known vulnerability rated moderate or lower (left-pad: moderate) — a person decides; npm changed the lockfile format (version 3 to 2), rewriting every entry — a person decides"
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_output --partial "(no minimum release age)"
}

@test "dependency changes: the repository's allowed licences replace the default; an expression passes if it allows one; an invalid list is refused" {
  stub_npm
  npm_project
  echo "(GPL-3.0-only OR MIT)" > "$NPM_STUB/license-left-pad"
  touch "$NPM_STUB/extra-tiny-dep" && echo "GPL-3.0-only" > "$NPM_STUB/license-tiny-dep"
  deps_run 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_ALLOWED_LICENSES": "MIT,GPL-3.0-only"}'
  run jq '.decisions | length' "$RUNNER_TEMP/gates.json"
  assert_output 0
  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_ALLOWED_LICENSES": "MIT;GPL-3.0"}'
  run failure
  assert_output --partial "AGENT_HUB_BUILD_ALLOWED_LICENSES must be SPDX licence ids separated by commas"
}

# stops <flag file> <flag content> <expected reason part> [ticket detail] [VAR=value...]:
# a fresh repository and stand-in npm with that flag, a build that stops at
# the install step, before the agent.
stops() {
  fresh_repo && npm_project && stub_npm
  [ -z "$1" ] || printf '%s' "$2" > "$NPM_STUB/$1"
  deps_run "${@:5}"
  run trace
  assert_line "Install dependencies: failure"
  assert_line "Agent: skipped"
  run failure
  assert_output --partial "$3"
  [ -z "${4:-}" ] || assert_output --partial "$4"
}

@test "dependency changes that can't be applied, or shown safe, stop the build before Claude" {
  # No version old enough: npm's message on the ticket only.
  stops etarget "" "npm couldn't resolve the plan's dependency changes in . (exit 1)" "npm said: npm error code ETARGET"
  assert_output --partial "(3 days ago, AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS)"
  run grep -c ETARGET "$RUNNER_TEMP/log.txt"
  assert_output 0
  # A version the registry says is newer than the cut-off, whatever npm
  # chose: checked independently of npm, for every new version.
  stops too-new-left-pad "" "would bring in package versions published after" "left-pad@1.3.0"
  stops too-new-tiny-dep "" "tiny-dep@1.3.0" "" && true
  # A package from git: its age and signature can't be checked.
  stops git-left-pad "" "aren't from the npm registry (left-pad@1.3.0)"
  # The install changing the lockfile it was given.
  stops ci-rewrites-lock "" "Installing the dependencies changed .'s package.json or package-lock.json after the plan's dependency changes were resolved"
  # A signature that doesn't verify.
  stops signatures-fail "" "signatures or provenance didn't verify, or couldn't be checked"
  # A new high or critical advisory.
  stops advisory-left-pad critical "add known vulnerabilities rated high or critical (left-pad: critical)" "Problem in left-pad"
  # An audit that gives no answer: it can't be shown not to get worse.
  stops audit-fails "" "npm couldn't check the known vulnerabilities in . before the plan's dependency changes"
  # An update to a package that isn't there: the plan is out of date.
  stops "" "" "update left-pad in ., but it isn't one of its dependencies" "" ATTACHMENT_CONTENT_FIXTURE="$(deps_plan 's/`\.`: add/`.`: update/')"
  # Not an npm project with a lockfile: checked before npm runs at all.
  fresh_repo && stub_npm
  deps_run
  run failure
  assert_output --partial "isn't an npm project with a package.json and package-lock.json"
  [ ! -s "$NPM_STUB/calls" ] || fail "npm ran before every change was checked"
  # An invalid minimum release age.
  run_scenario ready 'VARS={"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9", "AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS": "soon"}'
  run failure
  assert_output --partial "AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS must be a whole number of days"
}

@test "dependency changes: removing the last dependency (no signatures left to verify) builds" {
  stub_npm
  jq '.dependencies = {"left-pad": "^1.3.0"}' "$STEP_CWD/package.json" > "$BATS_TEST_TMPDIR/p.json" && cp "$BATS_TEST_TMPDIR/p.json" "$STEP_CWD/package.json"
  npm_project
  (cd "$STEP_CWD" && PATH="$NPM_STUB:$PATH" npm install --package-lock-only > /dev/null) && change_main "left-pad"
  DEPS_PLAN=$(deps_plan 's/`\.`: add `left-pad@^1.3.0`/`.`: remove `left-pad`/') deps_run
  run trace
  assert_line "Apply: success"
  run grep -c "audit signatures" "$NPM_STUB/calls"
  assert_output 0
  [ "$(remote_file agent-hub/PROJ-99 package.json | jq -r '.dependencies["left-pad"] // "gone"')" = gone ]
}

@test "dependency changes: the agent changing what the hub applied is a decision item, never pushed as the plan's" {
  stub_npm
  npm_project
  printf 'bash -e %q\njq %q package.json > p && mv p package.json\n' "$FIXTURES/edits/greet.sh" '.dependencies["is-odd"] = "^3.0.0"' > "$BATS_TEST_TMPDIR/edits.sh"
  deps_run CLAUDE_EDITS="$BATS_TEST_TMPDIR/edits.sh"
  run jq -r '.decisions[] | "\(.path): \(.reason)"' "$RUNNER_TEMP/gates.json"
  assert_line "package.json: changed after the hub applied the plan's dependency changes"
}

@test "the cost line says how Claude was reached: a plan's usage counts against its limits, an API key's is billed" {
  run_scenario ready CLAUDE_AUTH=api-key CLAUDE_EDITS=edits/greet.sh
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_output --partial "Claude, via an API key: 2.41 USD, billed to the API key"
  fresh_repo
  run_scenario ready CLAUDE_AUTH=account CLAUDE_EDITS=edits/greet.sh
  run jq -r 'select(.path | endswith("/pulls")) | .body.body' "$GH_CALLS"
  assert_output --partial "Claude, via a logged-in Claude account (pro): 2.41 USD API-equivalent, counted against the plan’s usage limits"
  refute_output --partial "private-person@example.com"
}

@test "a build that Claude can't finish (no usable result, or its budget cap): the comment's retry advice is the build's, never /revise" {
  for fixture in none claude/budget-exceeded.json; do
    fresh_repo
    [ "$fixture" = none ] || cp "$TESTS_DIR/work-order/fixtures/claude/budget-exceeded.json" "$BATS_TEST_TMPDIR/budget.json"
    run_scenario ready CLAUDE_FIXTURE="$([ "$fixture" = none ] && echo none || echo "$BATS_TEST_TMPDIR/budget.json")" CLAUDE_EXIT=1
    run trace
    assert_line "Agent: failure"
    run failure_notice
    assert_output --partial "To try again, move the ticket back to Implementation Plan and approve it again"
    refute_output --partial "/revise"
  done
}
