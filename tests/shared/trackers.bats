#!/usr/bin/env bats
# Jira and GitHub Projects are both supported trackers sharing one process:
# their intake fields must stay the same.

setup() {
  load ../lib/helpers
}

@test "the GitHub issue template has the same fields as the Jira intake template" {
  # Jira: the template block in docs/jira.md ("Original Request:" …).
  jira=$(awk '/^  ```$/ {inblock = !inblock; next} inblock && /:$/ {sub(/^ +/, ""); sub(/:$/, ""); print}' "$REPO_DIR/docs/jira.md")
  # GitHub: the issue template's field lines.
  github=$(grep -E ':$' "$REPO_DIR/.github/issue_template.md" | sed 's/:$//')
  assert_equal "$github" "$jira"
  # And it really compared the six fields (an empty match would also be equal).
  assert_equal "$(wc -l <<< "$jira" | tr -d ' ')" 6
  assert_equal "$(head -1 <<< "$jira")" "Original Request"
}
