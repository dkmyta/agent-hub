# The build's wording that the pull request (pr-body.jq) and the ticket's
# report (stage.sh, _ticket_report) share, so they always say the same.
#
#   jq -L "$STAGE_DIR" 'include "wording"; …'

# What the dependency step found in one folder (dependencies.sh), as one
# line: the lockfile's changes, publication times, signatures, advisories and
# licences — the same on the pull request and the ticket.
def dependency_summary($before):
  "\(.lockfile.added) package\(if .lockfile.added == 1 then "" else "s" end) added, \(.lockfile.changed) changed, \(.lockfile.removed) removed"
  + (if $before != "" then "; every new version published on or before \($before) (checked against the registry)" else "" end)
  + "; registry signatures verified for \(.signatures.verified) package\(if .signatures.verified == 1 then "" else "s" end) (\(.signatures.with_provenance) with provenance)"
  + "; known advisories: \(.advisories.before) before, \(.advisories.after) after"
  + (if (.advisories.new | length) > 0 then ", new: \(.advisories.new | map("\(.package) (\(.severity))") | join(", "))" else ", none new" end)
  + (if (.licenses_outside | length) > 0 then "; licences outside the allowed list: \(.licenses_outside | map("\(.name)@\(.version) (\(.license // "not stated"))") | .[:5] | join(", "))" else "; every new package’s licence on the allowed list" end);
# The run's Claude usage — the build and its review — as the access it used
# (agent-access.json) makes it: a plan's usage counts against its limits; an
# API key's is billed.
def claude_cost($access; $usd):
  ($usd // 0 | . * 100 | round / 100) as $c
  | "Claude (build and review), via \($access.label // "unknown access"): \($c) USD"
    + ({"api-key": ", billed to the API key", account: " API-equivalent, counted against the plan’s usage limits"}[$access.method // ""]
       // " (API-equivalent)");
# review_items(gates; review): the pull request's decision (D) and review (R)
# items from the gates and the code review (review.sh), numbered in that
# order — hub-written fields only: the state block is in the description,
# which a public repository shows to anyone, so a finding's own text stays
# with the review's result and the ticket. A review that didn't finish is a
# decision item itself.
def review_items($gates; $review):
  ($gates.decisions | length) as $gd
  | ($review.findings // []) as $f
  | [$gates.decisions | to_entries[] | {id: "D\(.key + 1)", path: .value.path, reason: .value.reason, status: "open"}]
    + (if $review.status == "incomplete" then
         [{id: "D\($gd + 1)", path: "", source: "hub", reason: "the automated code review didn’t finish: \($review.reason)", status: "open"}]
       else
         [[$f[] | select(.policy == "decision")] | to_entries[]
          | {id: "D\($gd + .key + 1)", source: "review", finding: .value.n, kind: .value.kind, severity: .value.severity, area: .value.area, status: "open"}]
       end)
    + [[$f[] | select(.policy != "decision")] | to_entries[]
       | {id: "R\(.key + 1)", source: "review", finding: .value.n, kind: .value.kind, severity: .value.severity, area: .value.area,
          fix_eligible: (.value.policy == "fix"), status: "open"}];
