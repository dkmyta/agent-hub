# The build's pull request description, from the hub's template — never
# free-form (docs/workflows/build.md, "Content"). The state block is added
# after it (lib/state.sh).
#
#   jq -nr -L lib -L stages/build -f pr-body.jq --slurpfile out agent-output.json --slurpfile context build-context.json \
#     --slurpfile gates gates.json --slurpfile contract contract.json --slurpfile state state.json \
#     --slurpfile verify verify.json --slurpfile deps dependencies.json \
#     --slurpfile access agent-access.json \
#     --arg ticket KEY --arg url "<ticket URL, or empty>" --arg run "<run URL>"
#
# The publication policy ("Publication policy"): unless ticket content may be
# published (a private repository, or the setting), it carries only the
# ticket key and what the hub itself determined — files, the gates, the
# checks it ran (from the repository's own files) and each check's result — never Claude's summary, the criteria, the decision log,
# the review steps or the commands it ran (Claude wrote them, so they could
# carry ticket text).

# unstop and plural (adf.jq); the wording shared with the ticket's report.
include "adf";
include "wording";

# Text from Claude or the ticket: no HTML (which could also forge a state
# block's marker line), one line where a list item needs it.
def safe: tostring | gsub("<"; "&lt;");
# How a criterion is verified, as a phrase: "verified manually", "verified
# by a new test".
def verified: if . == "manual" then "verified **manually**"
  else "verified by **\(if test("^[aeiou]") then "an" else "a" end) \(.)**" end;
def line: safe | gsub("\\s*\\n\\s*"; " ");
def code: "`" + (tostring | gsub("`"; "'") | gsub("\\n"; " ")) + "`";
def section($title; $lines): if ($lines | length) > 0 then "", "## \($title)", "", $lines[] else empty end;

def status_word: {A: "added", M: "modified", D: "deleted"}[.] // .;
def line_counts: if .added == null then "binary" else "+\(.added) −\(.deleted)" end;
def duration: (. / 1000 | floor) as $s | if $s < 60 then "\($s)s" else "\($s / 60 | floor) min \($s % 60)s" end;

$out[0] as $o | $o.structured_output.build as $b | $context[0] as $c | $gates[0] as $g
| $contract[0] as $p | $state[0] as $s | $c.publish as $publish
| (if $url != "" then "[\($ticket)](\($url))" else "**\($ticket)**" end) as $ref
| "Built by the agent hub from the approved implementation plan for \($ref)."
    + (if $publish then ""
       else " This repository is public, so the ticket's details — the request, the acceptance criteria and how each is verified, the commands the checks ran, the steps to review it and the decision log — are on the ticket, not here." end),
  "",
  "> [!NOTE]",
  "> A draft: automated review and the CI gate come in a later version, so a person reviews this before it's marked ready.",

  section("What changed"; (if $publish then [$b.summary | safe, ""] else [] end)
    + ["\(plural($g.totals.files; "file")), \(plural($g.totals.lines; "changed line")):", ""]
    + [$g.files[] | "- \(.path | code) — \(.status | status_word), \(line_counts) — \(.class)" + (if .reason != "" then ": \(.reason)" else "" end)]),

  section("Acceptance criteria"; [$b.verification | to_entries[]
    | if $publish then "\(.key + 1). \(.value.criterion | line) — **\(.value.method)**: \(.value.detail | line)"
      else "\(.key + 1). Criterion \(.key + 1) (on the ticket) — \(.value.method | verified)" end]),

  section("Checks run by the hub"; ["The repository's own checks, run by the hub on exactly this commit, in the sandbox (no network) — the build pushes only a commit they pass on:", ""]
    + (if ($verify[0].checks | length) > 0 then [$verify[0].checks[] | "- \(.command | code) — **\(.result)**"]
       else ["- None: the repository declares no checks (no test, lint, typecheck or build script)."] end)),

  # The plan's dependency changes, as the hub applied them (dependencies.sh):
  # package names, ranges, versions and licences are in the diff anyway.
  section("Dependency changes"; if ($deps[0].changes // []) == [] then [] else
    ["Applied by the hub before the agent ran, exactly as the plan lists them"
      + (if $deps[0].min_release_age_days > 0
         then ": only versions published at least \($deps[0].min_release_age_days) days ago (before \($deps[0].before))"
         else " (no minimum release age)" end)
      + ":", ""]
    + [$deps[0].changes[] | "- \(.folder | code): \(.action) "
        + (if .action == "remove" then (.package | code)
           else "\("\(.package)@\(.version_range)" | code) (\(.kind)) → \(.version // "?"), licence \(.license // "not stated")" end)]
    + [$deps[0].folders[] | "- In \(.folder | code): \(dependency_summary($deps[0].before))"]
  end),

  section("Checks the build agent reported";
    (if any($b.tests_run[]; .result == "failed")
     then ["> [!NOTE]", "> The agent reported a failing check" + (if $publish then "" else " (details on the ticket)" end) + "; the hub's own run above is the one that decides.", ""]
     else [] end)
    + [$b.tests_run | to_entries[] | if $publish then "- \(.value.command | code) — **\(.value.result)**: \(.value.summary | line)"
       else "- Check \(.key + 1) — **\(.value.result)**" + (if .value.result == "passed" then "" else " (details on the ticket)" end) end]),

  section("How to review"; if $publish then [$b.review_steps[]
      | "- [ ] \(.step | line) — expect: \(.expected | line | unstop)"
        + (if .checked then " (the build saw this)" else " (not checked by the build: \(.result | line))" end)]
    elif ($b.review_steps | length) > 0 then
      ["\(plural($b.review_steps | length; "step")) with their expected results, \([$b.review_steps[] | select(.checked)] | length) already seen to pass by the build: they're on the ticket, under Testing Instructions."]
    else [] end),

  section("Decision log"; if $publish then [$b.decision_log[]
    | "- **\(.decision | line)** — \(.why | line)" + (if (.alternatives // []) != [] then " Alternatives: \(.alternatives | map(line) | join("; "))." else "" end)]
    else [] end),

  section("Items for a person"; [$s.items[]
    | if (.id | startswith("D")) then
        "- **\(.id)** " + (if .path != "" then "\(.path | code) — " else "" end) + "decision: \(.reason)"
      else .path as $path
        | "- **\(.id)** \(.path | code) — a manual change for a person"
          + (if $publish then ": \([$p.governance.manual_changes[] | select(.path == $path)][0].change // "" | line)" else " (described on the ticket)" end)
      end]),

  section("Risk and governance"; ["- Risk: **\($p.governance.risk.level)**" + (if $publish then " — \($p.governance.risk.reason | line)" else "" end),
    "- Declared in the plan: " + ([$p.governance.includes | to_entries[] | select(.value) | .key | gsub("_"; " ")] | if length > 0 then join(", ") else "none of the sensitive kinds" end),
    "- Plan: attachment \($c.plan.attachment) on the ticket (sha256 \($c.plan.sha256[0:12]))"]),

  section("Run"; ["\(claude_cost($access[0]; $o.total_cost_usd)), \($o.duration_ms // 0 | duration) · hub \($s.hub_version) · [run summary](\($run))"])
