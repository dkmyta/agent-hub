# Jira Cloud REST helpers shared by the agent workflows.
#
# Source from a workflow step:  source "$AGENTS_DIR/lib/jira.sh"
# Requires: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN, TICKET_KEY.
# Request and response bodies are Atlassian Document Format (REST API v3).

set -o pipefail

[[ "$TICKET_KEY" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]] || {
  echo "::error::Invalid Jira ticket key: '$TICKET_KEY'"
  exit 1
}

ISSUE_URL="https://$JIRA_DOMAIN/rest/api/3/issue/$TICKET_KEY"
TICKET_URL="https://$JIRA_DOMAIN/browse/$TICKET_KEY"
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

jira() {
  curl -sS --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" -H "Accept: application/json" "$@"
}

# Issue fields, e.g. jira_issue summary,description,status
jira_issue() { jira "$ISSUE_URL?fields=$1"; }

jira_status() { jira_issue status | jq -r '.fields.status.name'; }

# Succeeds only while the ticket is in the given status, so a run never writes
# to a ticket someone has moved on since the run started. Callers use it as
# `jira_require_status X || exit 0`, which disables `set -e` inside, so API
# failures exit explicitly rather than reading as a status mismatch.
jira_require_status() {
  local current
  current=$(jira_status) || { echo "::error::Could not read $TICKET_KEY's status from Jira."; exit 1; }
  if [ "$current" != "$1" ]; then
    echo "::notice::$TICKET_KEY is in '$current', not '$1' — leaving it untouched."
    return 1
  fi
}

# Replace the description with the ADF document on stdin.
jira_set_description() {
  jq -c '{fields: {description: .}}' \
    | jira -X PUT "$ISSUE_URL?notifyUsers=${JIRA_NOTIFY_USERS:-true}" -d @-
}

# Post the ADF document on stdin as a comment and print the new comment's id.
jira_comment() {
  jq -c '{body: .}' | jira -X POST "$ISSUE_URL/comment" -d @- | jq -r '.id'
}

# Replace comment $1's body with the ADF document on stdin.
jira_update_comment() {
  jq -c '{body: .}' | jira -X PUT "$ISSUE_URL/comment/$1" -d @- > /dev/null
}

jira_delete_comment() { jira -X DELETE "$ISSUE_URL/comment/$1"; }

jira_comments() { jira "$ISSUE_URL/comment?maxResults=100"; }

jira_add_label() {
  jq -nc --arg name "$1" '{update: {labels: [{add: $name}]}}' \
    | jira -X PUT "$ISSUE_URL" -d @-
}

# Print the id of the transition into status $1, or nothing if unavailable.
jira_transition_id() {
  jira "$ISSUE_URL/transitions" \
    | jq -r --arg status "$1" '[.transitions[] | select(.to.name == $status)][0].id // empty'
}

jira_transition() {
  jq -nc --arg id "$1" '{transition: {id: $id}}' \
    | jira -X POST "$ISSUE_URL/transitions" -d @-
}
