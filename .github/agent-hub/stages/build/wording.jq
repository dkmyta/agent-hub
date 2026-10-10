# The build's wording that the pull request (pr-body.jq) and the ticket's
# report (stage.sh, _ticket_report) share, so they always say the same.
#
#   jq -L "$HUB_DIR/lib" -L "$STAGE_DIR" 'include "wording"; …'

include "adf";

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
def claude_cost($access; $amount):
  "Claude (build, review and fixes), via \($access.label // "unknown access"): \($amount // 0 | usd)"
    + ({"api-key": ", billed to the API key", account: " API-equivalent, counted against the plan’s usage limits"}[$access.method // ""]
       // " (API-equivalent)");
# review_items(gates; review; fix): the pull request's decision (D) and
# review (R) items from the gates, the code review (review.sh) and the fix
# pass (fix.sh), numbered in that order. A fix-eligible finding a kept fix
# resolved is listed as fixed; one it didn't, or any finding when no fix was
# kept, stays open; a kept fix's new concerns are sorted like findings — hub-written fields only: the state block is in the description,
# which a public repository shows to anyone, so a finding's own text stays
# with the review's result and the ticket. A review that didn't finish is a
# decision item itself.
def review_items($gates; $review; $fix):
  ($gates.decisions | length) as $gd
  | ($review.findings // []) as $f
  | (if $fix.status == "kept" then $fix else {checks: [], new_concerns: []} end) as $kept
  | ([$f[] | select(.policy == "decision")] | length) as $rd
  | ([$f[] | select(.policy != "decision")] | length) as $rr
  | [$gates.decisions | to_entries[] | {id: "D\(.key + 1)", path: .value.path, reason: .value.reason, status: "open"}]
    + (if $review.status == "incomplete" then
         [{id: "D\($gd + 1)", path: "", source: "hub", reason: "the automated code review didn’t finish: \($review.reason)", status: "open"}]
       else
         [[$f[] | select(.policy == "decision")] | to_entries[]
          | {id: "D\($gd + .key + 1)", source: "review", finding: .value.n, kind: .value.kind, severity: .value.severity, area: .value.area, status: "open"}]
       end)
    + [[$f[] | select(.policy != "decision")] | to_entries[]
       | .value.n as $n
       | {id: "R\(.key + 1)", source: "review", finding: $n, kind: .value.kind, severity: .value.severity, area: .value.area,
          fix_eligible: (.value.policy == "fix"),
          status: (if any($kept.checks[]; .finding == $n and .verdict == "resolved") then "fixed" else "open" end)}]
    + [[$kept.new_concerns[] | select(.policy == "decision")] | to_entries[]
       | {id: "D\($gd + $rd + .key + 1)", source: "fix-check", concern: .value.n, kind: .value.kind, severity: .value.severity, area: .value.area, status: "open"}]
    + [[$kept.new_concerns[] | select(.policy != "decision")] | to_entries[]
       | {id: "R\($rr + .key + 1)", source: "fix-check", concern: .value.n, kind: .value.kind, severity: .value.severity, area: .value.area,
          fix_eligible: false, status: "open"}];

# Markdown helpers for the pull request: text from Claude, the ticket — or
# anything else not the hub's own, like a gate reason quoting a package's
# licence from the registry — gets no HTML (which could also forge a marker
# line), no links or images (an image GitHub fetches could carry data out to
# any server; a link could pass for the hub's) and no mentions — the
# characters that make them shown as they are — and one line where a list
# item needs it.
def safe: tostring | gsub("\\\\"; "\\\\") | gsub("<"; "&lt;") | gsub("(?<c>[\\[\\]@])"; "\\\(.c)");
def line: safe | gsub("\\s*\\n\\s*"; " ");
def code: "`" + (tostring | gsub("`"; "'") | gsub("\\n"; " ")) + "`";
def section($title; $lines): if ($lines | length) > 0 then "", "## \($title)", "", $lines[] else empty end;

# The markers around the pull request's hub-managed status — the automated
# review and the items — which a reconcile run rewrites (lib/state.sh,
# status_render); everything else in the description is left as it is.
def status_start: "<!-- agent-hub:status -->";
def status_end: "<!-- /agent-hub:status -->";

# status_lines(state; review; fix; contract; publish; what was reviewed): the
# hub-managed status, as Markdown lines between its markers. Open items only
# (and fixed ones); items closed by a later generation aren't listed.
def status_lines($s; $r; $x; $p; $publish; $what):
  "", status_start,
  section("Automated review"; if $r.status == "incomplete" then
      ["The automated code review didn't finish (\($r.reason | line)), so this build is unreviewed: a person reviews it without one (a decision item below)."]
    else
      [(if $publish then ($r.summary | line) + " " else "" end)
        + "A fresh, read-only session reviewed \($what) against the plan: "
        + (if ($r.findings | length) == 0 then "no findings."
           else "\(plural($r.findings | length; "finding")) — \([$r.findings[] | select(.policy == "decision")] | length) for a person to decide, \([$r.findings[] | select(.policy == "fix")] | length) fix-eligible, \([$r.findings[] | select(.policy == "review")] | length) review item(s)." end)]
      + (if $x.status == "kept" then
          ["", "The fix-eligible findings were fixed once, in the commit after the reviewed one, and a fresh read-only session checked each fix: \([$x.checks[] | select(.verdict == "resolved")] | length) resolved, \([$x.checks[] | select(.verdict != "resolved")] | length) not (still open below)"
             + (if ($x.new_concerns | length) > 0 then ", and \(plural($x.new_concerns | length; "new concern")) the fixes raised (below)" else "" end)
             + ". The hub's gates and the repository's checks passed on the fix before it was kept."]
        elif $x.status == "dropped" or $x.status == "failed" then
          ["", "A fix pass ran, but its changes weren't kept: \($x.reason | line). The fix-eligible findings stay open below."]
        else [] end)
    end),

  section("Items for a person"; [$s.items[] | select(.status != "closed") | . as $i
    | (if .source == "review" then
        ([$r.findings[] | select(.n == $i.finding)] | first) as $f
        | "- **\(.id)** " + (if (.id | startswith("D")) then "decision" elif .status == "fixed" then "fixed by the fix pass (checked)" elif .fix_eligible then "review item, fix-eligible, not fixed" else "review item" end)
          + " — \(.severity) \(.kind | gsub("-"; " ")), \(.area | gsub("-"; " "))"
          + (if $publish then ": \($f.title | line)" + (if ($f.file // "") != "" then " (\($f.file | code)\(if $f.line then ":\($f.line)" else "" end))" else "" end)
             else " (details on the ticket)" end)
      elif .source == "fix-check" then
        ([$x.new_concerns[] | select(.n == $i.concern)] | first) as $f
        | "- **\(.id)** " + (if (.id | startswith("D")) then "decision" else "review item" end) + ", raised by the fix check"
          + " — \(.severity) \(.kind | gsub("-"; " ")), \(.area | gsub("-"; " "))"
          + (if $publish then ": \($f.title | line)" + (if ($f.file // "") != "" then " (\($f.file | code)\(if $f.line then ":\($f.line)" else "" end))" else "" end)
             else " (details on the ticket)" end)
      elif .source == "ci-fix-check" then
        "- **\(.id)** " + (if (.id | startswith("D")) then "decision" else "review item" end) + ", raised by a CI fix's check"
          + " — \(.severity) \(.kind | gsub("-"; " ")), \(.area | gsub("-"; " ")) (details on the ticket)"
      elif (.id | startswith("D")) then
        "- **\(.id)** " + (if .path != "" then "\(.path | code) — " else "" end) + "decision: \(.reason | line)"
      else .path as $path
        | "- **\(.id)** \(.path | code) — a manual change for a person"
          + (if $publish then ": \([$p.governance.manual_changes[] | select(.path == $path)][0].change // "" | line)" else " (described on the ticket)" end)
      end)
      # A person's /skip (step 5): a decision accepted, or an item skipped.
      + {accepted: " — **accepted** by an approver", skipped: " — **skipped** by an approver"}[$i.status] // ""]),
  status_end;

# reconcile_items(previous items; fresh items): a reconcile run's items
# (docs/workflows/build-design.md, "Decision items: ownership"). A gate decision
# still there on the new head keeps its id and status; one that's gone is
# closed. The new review's and fix check's items replace the previous
# generation's open ones, which are closed. Manual changes (C) carry over.
# Ids are never reused: new items continue each prefix's numbering.
def reconcile_items($prev; $fresh):
  def num: .id[1:] | tonumber;
  def gate: (.source // "gate") == "gate" and (.id | startswith("D"));
  ([$prev[] | select(.id | startswith("D")) | num] | max // 0) as $dmax
  | ([$prev[] | select(.id | startswith("R")) | num] | max // 0) as $rmax
  | [$prev[] | select(gate and .status != "closed")] as $open_gates
  | [$fresh[] | select(gate) | . as $f
      | ([$open_gates[] | select(.path == $f.path and .reason == $f.reason)] | first) as $m
      | if $m then $f + {id: $m.id, status: $m.status} else $f + {new: true} end] as $gates
  | [$fresh[] | select(gate | not)] as $others
  | (reduce ($gates[], $others[]) as $i ({d: $dmax, r: $rmax, out: []};
      if ($i.new // false) or ($i | gate | not) then
        if ($i.id | startswith("D")) then .d += 1 | .out += [$i + {id: "D\(.d)"} | del(.new)]
        else .r += 1 | .out += [$i + {id: "R\(.r)"}] end
      else .out += [$i] end)).out as $now
  | [$prev[] | select(.status == "closed")]
    + [$open_gates[] | select(.id as $id | $now | any(.id == $id) | not) | .status = "closed"]
    + [$prev[] | select((gate | not) and (.id | startswith("C") | not) and .status != "closed") | .status = "closed"]
    + $now
    + [$prev[] | select(.id | startswith("C"))]
  | sort_by((.id[0:1] | {D: 0, R: 1, C: 2}[.]), num);

# reconcile_cause(build context): why a reconcile run re-checked the pull
# request — people's commits, a merge of the moved target, or both — in hub
# facts only (counts, commits, the branch's name).
def reconcile_cause($c):
  [if $c.people_commits > 0 then "\(plural($c.people_commits; "commit")) pushed since the hub's last push, at \($c.start_head[0:7])" else empty end,
   if $c.sync then "\($c.target) moved by \(plural($c.sync.commits; "commit")) and the hub merged it in, at \($c.sync.head[0:7]) — "
     + (if $c.sync.drift == "mechanical" then "its changes touch nothing this pull request or its plan touches, and no drift-sensitive path"
        else "its changes touch " + ([if $c.sync.overlap > 0 then plural($c.sync.overlap; "file") + " this pull request or its plan touches" else empty end,
            if $c.sync.sensitive > 0 then plural($c.sync.sensitive; "drift-sensitive file") else empty end] | join(" and ")) end)
   else empty end] | join("; and ");

# reconcile_after(build context): what the re-checked head comes after.
def reconcile_after($c):
  [if $c.people_commits > 0 then "people's commits" else empty end, if $c.sync then "merging \($c.target)" else empty end] | join(" and ");
