# shellcheck shell=bash
# The Jira tracker: the tracker_* functions on Jira Cloud's REST API.
#
# Loaded by lib/load.sh when AGENT_HUB_TRACKER is jira (the default).
# Requires: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN, TICKET_KEY.
# Request and response bodies are Atlassian Document Format (REST API v3).

set -o pipefail

# How messages on the ticket and in the log name the tracker, and where its
# setup is documented.
# shellcheck disable=SC2034 # used by lib/stage.sh and the stages
TRACKER_NAME=Jira
# shellcheck disable=SC2034
TRACKER_DOC=docs/jira.md

[[ "$TICKET_KEY" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]] || {
  echo "::error::Invalid Jira ticket key: '$TICKET_KEY'"
  exit 1
}

ISSUE_URL="https://$JIRA_DOMAIN/rest/api/3/issue/$TICKET_KEY"
# shellcheck disable=SC2034 # used by the workflow steps that source this file
TICKET_URL="https://$JIRA_DOMAIN/browse/$TICKET_KEY"

# Credentials go to curl through a file only this user can read, never on its
# command line, where other users of the runner machine could see them.
JIRA_CURL_CONFIG=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jira-curl.XXXXXX")
trap 'rm -f "$JIRA_CURL_CONFIG"' EXIT
printf 'user = "%s:%s"\n' \
  "$(printf '%s' "$JIRA_EMAIL" | sed 's/[\\"]/\\&/g')" \
  "$(printf '%s' "$JIRA_API_TOKEN" | sed 's/[\\"]/\\&/g')" > "$JIRA_CURL_CONFIG"

# Every Jira call goes through jira_request (the tests replace just this).
jira_request() {
  curl -sS --fail-with-body --config "$JIRA_CURL_CONFIG" -H "Accept: application/json" "$@"
}

# A JSON request: jira [-X METHOD] URL [-d BODY].
jira() { jira_request -H "Content-Type: application/json" "$@"; }

# Issue fields, e.g. tracker_issue summary,description,status
tracker_issue() { jira "$ISSUE_URL?fields=$1"; }

tracker_status() { tracker_issue status | jq -r '.fields.status.name'; }

# Succeeds only while the ticket is in the given status, so a run never writes
# to a ticket someone has moved on since the run started. Callers use it as
# `tracker_require_status X || exit 0`, which disables `set -e` inside, so API
# failures exit explicitly rather than reading as a status mismatch.
tracker_require_status() {
  local current
  current=$(tracker_status) || { echo "::error::Could not read $TICKET_KEY's status from $TRACKER_NAME."; exit 1; }
  if [ "$current" != "$1" ]; then
    echo "::notice::$TICKET_KEY is in '$current', not '$1' — leaving it untouched."
    return 1
  fi
}

# _label_changes <+name|-name>...: Jira's label update operations.
_label_changes() { printf '%s\n' "$@" | jq -R 'select(. != "") | if startswith("-") then {remove: .[1:]} else {add: ltrimstr("+")} end' | jq -sc .; }

# tracker_set_description [+label|-label]...: replace the description with the
# ADF document on stdin, and change labels in the same request — one update,
# so one "work item updated" event for Jira automation, not several.
tracker_set_description() {
  jq -c --argjson labels "$(_label_changes "$@")" \
      '{fields: {description: .}} + (if ($labels | length) > 0 then {update: {labels: $labels}} else {} end)' \
    | jira -X PUT "$ISSUE_URL?notifyUsers=${JIRA_NOTIFY_USERS:-true}" -d @-
}

# tracker_labels <+label|-label>...: add (+) and remove (-) labels in one request.
tracker_labels() {
  jq -nc --argjson labels "$(_label_changes "$@")" '{update: {labels: $labels}}' \
    | jira -X PUT "$ISSUE_URL" -d @-
}

# Post the ADF document on stdin as a comment and print the new comment's id.
tracker_comment() {
  jq -c '{body: .}' | jira -X POST "$ISSUE_URL/comment" -d @- | jq -r '.id'
}

# Replace comment $1's body with the ADF document on stdin.
tracker_update_comment() {
  jq -c '{body: .}' | jira -X PUT "$ISSUE_URL/comment/$1" -d @- > /dev/null
}

tracker_delete_comment() { jira -X DELETE "$ISSUE_URL/comment/$1"; }

tracker_comments() { jira "$ISSUE_URL/comment?maxResults=100"; }

# Attach Markdown file $1 to the ticket (a multipart upload; Jira requires the
# X-Atlassian-Token header). Prints the new attachment's id.
tracker_attach() {
  jira_request -H "X-Atlassian-Token: no-check" -F "file=@$1;type=text/markdown" \
    "$ISSUE_URL/attachments" | jq -r '.[0].id'
}

# The ticket's attachments: [{id, filename, created, ...}].
tracker_attachments() { tracker_issue attachment | jq '.fields.attachment // []'; }

tracker_delete_attachment() { jira -X DELETE "https://$JIRA_DOMAIN/rest/api/3/attachment/$1"; }

# Print attachment $1's content. Jira redirects to its media store, which curl
# follows without resending the credentials (they're only for the Jira host).
tracker_attachment_content() { jira_request -L "https://$JIRA_DOMAIN/rest/api/3/attachment/content/$1"; }

# Print the id of the transition into status $1, or nothing if unavailable.
tracker_transition_id() {
  jira "$ISSUE_URL/transitions" \
    | jq -r --arg status "$1" '[.transitions[] | select(.to.name == $status)][0].id // empty'
}

tracker_transition() {
  jq -nc --arg id "$1" '{transition: {id: $id}}' \
    | jira -X POST "$ISSUE_URL/transitions" -d @-
}
