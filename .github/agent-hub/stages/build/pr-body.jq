# The build's pull request description, from the hub's template — never
# free-form (docs/workflows/build.md, "Content"). The state block is added
# after it (lib/state.sh).
#
#   jq -nr -f pr-body.jq --slurpfile out agent-output.json --slurpfile context build-context.json \
#     --slurpfile gates gates.json --slurpfile contract contract.json --slurpfile state state.json \
#     --arg ticket KEY --arg url "<ticket URL, or empty>" --arg run "<run URL>"
#
# The publication policy ("Publication policy"): unless ticket content may be
# published (a private repository, or the setting), it carries only the
# ticket key and what the hub itself determined — files, the gates, each
# check's result — never Claude's summary, the criteria, the decision log,
# the manual steps or the commands it ran (Claude wrote them, so they could
# carry ticket text).

# Text from Claude or the ticket: no HTML (which could also forge a state
# block's marker line), one line where a list item needs it.
def safe: tostring | gsub("<"; "&lt;");
def line: safe | gsub("\\s*\\n\\s*"; " ");
def code: "`" + (tostring | gsub("`"; "'") | gsub("\\n"; " ")) + "`";
def section($title; $lines): if ($lines | length) > 0 then "", "## \($title)", "", $lines[] else empty end;

$out[0] as $o | $o.structured_output.build as $b | $context[0] as $c | $gates[0] as $g
| $contract[0] as $p | $state[0] as $s | $c.publish as $publish
| "# Build: \($ticket)",
  "",
  (if $url != "" then "Ticket: [\($ticket)](\($url))" else "Ticket: \($ticket)" end)
    + " · from the approved implementation plan (attachment \($c.plan.attachment), sha256 \($c.plan.sha256[0:12]))",
  "",
  "> [!NOTE]",
  "> A draft from the agent hub. Automated review and the CI gate come in a later version: a person reviews this before it's marked ready.",

  section("Summary"; if $publish then [$b.summary | safe] else [] end),

  section("Acceptance criteria"; [$b.verification | to_entries[]
    | if $publish then "\(.key + 1). \(.value.criterion | line) — **\(.value.method)**: \(.value.detail | line)"
      else "\(.key + 1). **\(.value.method)**" end]),

  section("Verification in the sandbox";
    (if any($b.tests_run[]; .result == "failed") then ["> [!WARNING]", "> Claude reported a failing check.", ""] else [] end)
    + [$b.tests_run | to_entries[] | if $publish then "- \(.value.command | code) — **\(.value.result)**: \(.value.summary | line)"
       else "- Check \(.key + 1) — **\(.value.result)**" end]),

  section("Manual testing"; if $publish then [$b.manual_checks[]
      | if .checked then "- [x] \(.step | line) — checked by the agent: \(.result | line)"
        else "- [ ] \(.step | line) — needs a person" end]
    elif ($b.manual_checks | length) > 0 then
      ["\($b.manual_checks | length) manual step(s), \([$b.manual_checks[] | select(.checked)] | length) checked by the agent; the rest need a person (the steps are in the plan)."]
    else [] end),

  section("Decision log"; if $publish then [$b.decision_log[]
    | "- **\(.decision | line)** — \(.why | line)" + (if (.alternatives // []) != [] then " Alternatives: \(.alternatives | map(line) | join("; "))." else "" end)]
    else [] end),

  section("Items for a person"; [$s.items[]
    | if (.id | startswith("D")) then
        "- **\(.id)** " + (if .path != "" then "\(.path | code) — " else "" end) + "decision: \(.reason)"
      else .path as $path
        | "- **\(.id)** \(.path | code) — a manual change for a person"
          + (if $publish then ": \([$p.governance.manual_changes[] | select(.path == $path)][0].change // "" | line)" else "" end)
      end]),

  section("Scope"; ["\($g.totals.files) file(s), \($g.totals.lines) changed line(s), against the plan's Changes by File:", ""]
    + [$g.files[] | "- \(.path | code) (\(.status)) — \(.class)" + (if .reason != "" then ": \(.reason)" else "" end)]),

  section("Risk and governance"; ["- Risk: **\($p.governance.risk.level)**" + (if $publish then " — \($p.governance.risk.reason | line)" else "" end),
    "- Declared in the plan: " + ([$p.governance.includes | to_entries[] | select(.value) | .key | gsub("_"; " ")] | if length > 0 then join(", ") else "none of the sensitive kinds" end)]),

  section("Run"; ["Claude: \($o.total_cost_usd // 0 | . * 100 | round / 100) USD (API-equivalent), \(($o.duration_ms // 0) / 60000 | floor) min · hub \($s.hub_version) · [run summary](\($run))"])
