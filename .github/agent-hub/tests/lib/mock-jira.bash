# shellcheck shell=bash
# Replaces jira_request() from trackers/jira/tracker.sh — the one function
# every Jira call goes through — with a mock (sourced by helpers.bash right
# after each step loads the real library). Each call is logged to $CALLS as
# {method, path, body}; uploaded files are copied to $RUNNER_TEMP/attached/.
# Responses come from the scenario:
#
#   TICKET_FIXTURE       issue JSON (summary, description)
#   TICKET_LATER_FIXTURE  the description on later reads (default:
#                        TICKET_FIXTURE) — e.g. a person editing it mid-run
#   COMMENTS_FIXTURE     comments JSON (default: none)
#   COMMENTS_PAGE2_FIXTURE  the second page of comments (startAt=100), when
#                        COMMENTS_FIXTURE's total says there are more
#   COMMENTS_LATER_FIXTURE  comments from the second lookup on (default:
#                        COMMENTS_FIXTURE) — e.g. a comment added or edited mid-run
#   TRANSITIONS_FIXTURE  transitions JSON
#   CHANGELOG_FIXTURE    the ticket's change history (default: one entry, a
#                        person moving it to Work Order Approved); the second
#                        page (startAt=100) from CHANGELOG_PAGE2_FIXTURE
#   ATTACHMENTS_FIXTURE  attachments JSON array (default: none)
#   ATTACHMENTS_LATER_FIXTURE  attachments from lookup ATTACHMENTS_LATER_FROM
#                        (default: the second) on — e.g. a person uploading mid-run
#   ATTACHMENT_CONTENT_FIXTURE  file served as any attachment's content
#   MOCK_STATUS          status when the ticket is fetched
#   MOCK_STATUS_LATER    status on later checks (default: MOCK_STATUS); a
#                        transition the run makes changes it, as in Jira
#   MOCK_FAIL            "METHOD path" of a call that should fail
#   MOCK_FAIL_FROM       fail it from this occurrence on (default: the first)
#   MOCK_LEDGER          the hub's record of the ticket (its Claude usage) when
#                        the run starts, as JSON (default: none); the run's
#                        writes replace it, as in Jira
#   MOCK_LABELS          the ticket's labels, as a JSON array, when read on
#                        their own (default: none)
#   MOCK_LOST            a transition works, but the first reply is lost (a
#                        failure, as when a connection breaks after Jira acted)
#
# Any request not listed here fails, so a test can't pass on a call it never
# meant to make. The automation account's id is agent-hub-bot.

jira_request() {
  local method=GET url="" body="" file
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method=$2; shift 2 ;;
      -H) shift 2 ;;
      -L) shift ;;
      -d) case "$2" in @-) body=$(cat) ;; @*) body=$(cat "${2#@}") ;; *) body=$2 ;; esac; shift 2 ;;
      -F) # file=@PATH;type=...: record the file name, keep a copy of the content
          file=${2#file=@}; file=${file%%;*}; method=POST
          mkdir -p "$RUNNER_TEMP/attached"; cp "$file" "$RUNNER_TEMP/attached/"
          body=$(jq -nc --arg name "$(basename "$file")" '{upload: $name}'); shift 2 ;;
      *) url=$1; shift ;;
    esac
  done
  # Paths relative to the ticket, or to the API for other resources.
  local path=${url#"$ISSUE_URL"}
  [ "$path" != "$url" ] || path=${url#"https://$JIRA_DOMAIN/rest/api/3"}
  jq -nc --arg method "$method" --arg path "$path" --arg body "$body" \
    '{method: $method, path: $path, body: (if $body == "" then null else ($body | fromjson) end)}' >> "$CALLS"

  if [ "$method $path" = "${MOCK_FAIL:-}" ] && [ "$(jq -c --arg m "$method" --arg p "$path" \
      'select(.method == $m and .path == $p)' "$CALLS" | wc -l)" -ge "${MOCK_FAIL_FROM:-1}" ]; then
    echo '{"errorMessages":["Mock Jira failure"]}'
    return 22
  fi

  case "$method $path" in
    "GET ?fields=summary,description,status")
      jq -c --arg status "$MOCK_STATUS" '.fields.status.name = $status' "$TICKET_FIXTURE" ;;
    "GET ?fields=status")
      local status=${MOCK_STATUS_LATER:-$MOCK_STATUS}
      [ ! -s "$RUNNER_TEMP/mock-status" ] || status=$(cat "$RUNNER_TEMP/mock-status")
      jq -nc --arg status "$status" '{fields: {status: {name: $status}}}' ;;
    "POST /transitions")
      if [ -n "${TRANSITIONS_FIXTURE:-}" ]; then
        jq -r --argjson body "$body" '.transitions[] | select(.id == $body.transition.id) | .to.name' \
          "$TRANSITIONS_FIXTURE" > "$RUNNER_TEMP/mock-status"
      fi
      if [ -n "${MOCK_LOST:-}" ] && [ ! -e "$RUNNER_TEMP/mock-lost" ]; then
        touch "$RUNNER_TEMP/mock-lost"
        echo '{"errorMessages":["Mock lost reply"]}'
        return 22
      fi ;;
    "GET ?fields=description"|"GET ?fields=description,labels")
      jq -c '{fields: {description: .fields.description, labels: (.fields.labels // [])}}' "${TICKET_LATER_FIXTURE:-$TICKET_FIXTURE}" ;;
    "GET /comment?maxResults=100")
      if [ -n "${COMMENTS_LATER_FIXTURE:-}" ] && [ "$(grep -c '"GET","path":"/comment?maxResults=100"' "$CALLS")" -gt 1 ]; then
        cat "$COMMENTS_LATER_FIXTURE"
      elif [ -n "${COMMENTS_FIXTURE:-}" ]; then cat "$COMMENTS_FIXTURE"
      else echo '{"startAt":0,"maxResults":100,"total":0,"comments":[]}'; fi ;;
    "GET /comment?maxResults=100&startAt="*) cat "$COMMENTS_PAGE2_FIXTURE" ;;
    "GET /transitions") cat "$TRANSITIONS_FIXTURE" ;;
    "GET /changelog?startAt=0&maxResults=100")
      if [ -n "${CHANGELOG_FIXTURE:-}" ]; then cat "$CHANGELOG_FIXTURE"
      else echo '{"startAt":0,"maxResults":100,"total":1,"isLast":true,"values":[{"author":{"accountId":"dana-lead"},"items":[{"field":"status","toString":"Work Order Approved"}]}]}'; fi ;;
    "GET /changelog?startAt=100&maxResults=100") cat "$CHANGELOG_PAGE2_FIXTURE" ;;
    "GET ?fields=attachment")
      local attachments=${ATTACHMENTS_FIXTURE:-}
      if [ -n "${ATTACHMENTS_LATER_FIXTURE:-}" ] && [ "$(grep -c '"GET","path":"?fields=attachment"' "$CALLS")" -ge "${ATTACHMENTS_LATER_FROM:-2}" ]; then
        attachments=$ATTACHMENTS_LATER_FIXTURE
      fi
      if [ -n "$attachments" ]; then jq -c '{fields: {attachment: .}}' "$attachments"; else echo '{"fields":{"attachment":[]}}'; fi ;;
    "GET /myself") echo '{"accountId":"agent-hub-bot"}' ;;
    "GET /properties")
      if [ -s "$RUNNER_TEMP/mock-ledger.json" ] || [ -n "${MOCK_LEDGER:-}" ]; then echo '{"keys":[{"key":"agent-hub-ledger"}]}'
      else echo '{"keys":[]}'; fi ;;
    "GET /properties/agent-hub-ledger")
      if [ -s "$RUNNER_TEMP/mock-ledger.json" ]; then jq -c '{key: "agent-hub-ledger", value: .}' "$RUNNER_TEMP/mock-ledger.json"
      else jq -nc --argjson v "$MOCK_LEDGER" '{key: "agent-hub-ledger", value: $v}'; fi ;;
    "PUT /properties/agent-hub-ledger") printf '%s\n' "$body" > "$RUNNER_TEMP/mock-ledger.json" ;;
    "GET ?fields=labels") jq -nc --argjson labels "${MOCK_LABELS:-[]}" '{fields: {labels: $labels}}' ;;
    "POST /attachments") echo '[{"id":"9001"}]' ;;
    "GET /attachment/content/"*) cat "$ATTACHMENT_CONTENT_FIXTURE" ;;
    "POST /comment")
      # Sequential ids so snapshots show which comment later calls refer to.
      local n; n=$(( $(grep -c '"POST","path":"/comment"' "$CALLS") + 5000 ))
      echo "{\"id\":\"$n\"}" ;;
    # Writes Jira answers with no content.
    "PUT "|"PUT ?notifyUsers="*|"PUT /comment/"*|"DELETE /comment/"*|"DELETE /attachment/"*) ;;
    *) echo "mock-jira: unexpected request: $method $path" >&2; return 99 ;;
  esac
}
