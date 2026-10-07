#!/usr/bin/env bats
# The interfaces that keep the stages independent of where tickets live and
# what runs the agent (docs/architecture.md), and the two trackers' intake
# staying the same.

setup() {
  load ../lib/helpers
}

@test "the GitHub issue form has the same fields as the Jira intake template" {
  [ -f "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml" ] || skip "the GitHub Projects intake form isn't installed here"
  # Jira: the template block in docs/jira.md ("Original Request:" …).
  jira=$(awk '/^  ```$/ {inblock = !inblock; next} inblock && /:$/ {sub(/^ +/, ""); sub(/:$/, ""); print}' "$HUB_DIR/docs/jira.md")
  # GitHub: the issue form's field labels.
  github=$(node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const form = parse(readFileSync(process.argv[1], "utf8"));
    for (const field of form.body) if (field.type !== "markdown") console.log(field.attributes.label);' \
    "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml")
  assert_equal "$github" "$jira"
  # And it really compared the six fields (an empty match would also be equal).
  assert_equal "$(wc -l <<< "$jira" | tr -d ' ')" 6
  assert_equal "$(head -1 <<< "$jira")" "Original Request"
}

# The form is how an issue enters the pipeline (and only an issue made with
# it): it must add the label the board's auto-add filter and the stages use,
# and require the request itself.
@test "the GitHub issue form adds the agent-hub label and requires the request" {
  [ -f "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml" ] || skip "the GitHub Projects intake form isn't installed here"
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const form = parse(readFileSync(process.argv[1], "utf8"));
    const request = form.body.find((field) => field.id === "original-request");
    console.log(JSON.stringify(form.labels), request.validations.required);' \
    "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml"
  assert_output '["agent-hub"] true'
}

# Every tracker adapter provides the whole tracker interface, so a stage works
# with any of them.
@test "every tracker defines the tracker interface" {
  local tracker
  for tracker in "$HUB_DIR"/trackers/*/tracker.sh; do
    run env TICKET_KEY=PROJ-1 RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c 'source "$1"
      declare -F tracker_issue tracker_status tracker_account_id tracker_edited_after tracker_history_since tracker_require_status tracker_set_description \
        tracker_comments tracker_comment tracker_update_comment tracker_delete_comment \
        tracker_labels tracker_ticket_labels tracker_ledger tracker_set_ledger tracker_attachments tracker_attach \
        tracker_attachment_content tracker_delete_attachment tracker_transition_id tracker_transition > /dev/null
      [ -n "$TICKET_URL" ] && [ -n "$TRACKER_NAME" ] && [ -f "$HUB_DIR/$TRACKER_DOC" ]' _ "$tracker"
    assert_success "$tracker"
  done
}

@test "every agent runner defines the runner interface" {
  local runner
  for runner in "$HUB_DIR"/lib/runners/*.sh; do
    run env RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c 'source "$1"
      declare -F agent_run agent_check agent_review agent_summary agent_cleanup > /dev/null' _ "$runner"
    assert_success "$runner"
  done
}
