# Render an implementation plan (the `plan` object from schema.json). Every
# section comes from one field, so a revision can replace just the sections
# it changes. Modes:
#
#   --arg mode full     the whole plan as ADF blocks (converted to Markdown and
#                       attached to the ticket, since thorough plans outgrow
#                       the tracker's field limit)
#   --arg mode summary  what goes in the ticket's Implementation Plan section:
#                       estimate, approach, acceptance-criteria coverage, the
#                       steps, and a pointer to the attached plan (--arg file <name>)
#   --arg mode splice   a revision of the attached plan, as Markdown: the
#                       current file (--rawfile md) with only the sections in
#                       --slurpfile updates replaced (added or removed in
#                       plan order), so everything else — including people's
#                       own edits — stays as it is. Its "Expert review" notes
#                       are dropped (the workflow adds the revision's). Run with -n.
#   --arg mode missing  the headings a revision (--slurpfile updates) needs
#                       that the attached plan (--rawfile md) no longer has —
#                       sections every plan has, removed or renamed by hand.
#                       Run with -n.
#   --arg mode summary-patch  a revision of the summary: the current
#                       description's Implementation Plan section with only the
#                       updated parts re-rendered (input: the description)
#
# Optional sections with nothing in them are left out; Security & Privacy
# always appears, saying so when there's no impact.
#
#   --argjson level N   heading level for the sections (5 under the work
#                       order's h4 "Implementation Plan"; 2 in the attached file)
#
# Usage:  jq -L "$HUB_DIR/lib" -f render.jq --arg mode summary --arg file X.md --argjson level 5 plan.json

include "adf";
include "markdown";

def section($t): heading($level; $t);

# A section only if it has content.
def optional($title; $items; blocks): if ($items | length) > 0 then section($title), blocks else empty end;

def estimate($plan): para([strong("Estimate: "), text("\($plan.estimate.size) — \($plan.estimate.reason)")]);

# Evidence and sources: links for URLs, code for file paths.
def reference: if test("^https?://") then link(.) else code(.) end;
def references($label; $items):
  if ($items | length) == 0 then []
  else [text(" \($label): ")] + ([$items[] | reference] | join_inline(", ")) end;

def approach($plan; $full):
  section("Approach"),
  ($plan.approach.summary[] | para(.)),
  (if $full then
     para([strong("Why this approach: "), text($plan.approach.rationale)]),
     (if ($plan.approach.alternatives | length) > 0 then
        para([strong("Alternatives considered")]),
        bullets([$plan.approach.alternatives[] | [strong(.option), text(" — \(.reason)")]])
      else empty end)
   else empty end);

def coverage($plan):
  section("Acceptance Criteria Coverage"),
  table(["Acceptance criterion", "How it's met", "How to verify"];
    [$plan.acceptance_criteria[] | [.criterion, .approach, .verification]]);

def summary_steps($plan):
  numbered([$plan.steps[] | [para([strong(.title)] + (if (.files | length) > 0
    then [text(" — ")] + ([.files[] | code(.)] | join_inline(", ")) else [] end))]]);

def pointer:
  para([strong("Full plan: "), text("attached to this ticket as "), code($file),
    text(" — current state, changes by file, scope and governance, detailed steps, testing, security, observability, risks, release and rollback, resolved questions and assumptions.")]);

# The governance kinds, with the fixed labels the full plan's table uses (the
# build stage reads them back, so they don't change).
def governance_kinds: [
  ["dependencies", "Dependencies"], ["schema_or_migration", "Schema or migration"],
  ["public_api", "Public API or contract"], ["auth_or_permissions", "Auth or permissions"],
  ["sensitive_data", "Sensitive data"], ["infrastructure", "Infrastructure"],
  ["workflow_or_ci", "Workflow or CI"], ["configuration", "Configuration"]];

# The summary's risk line: the level, and the sensitive kinds the plan includes
# — what the person approving it is agreeing to.
def risk_line($plan):
  [governance_kinds[] | select(.[0] as $k | $plan.governance.includes[$k]) | .[1] | ascii_downcase] as $yes
  | para([strong("Risk: "), text("\($plan.governance.risk.level) — \($plan.governance.risk.reason) "),
      strong("Includes: "), text(if ($yes | length) > 0 then $yes | join(", ") else "none of the sensitive kinds" end)]);

def path_list($items; $none): if ($items | length) > 0 then bullets([$items[] | [code(.)]]) else para($none) end;

# The plan's fields in order, and each one's heading in the full plan
# (the estimate is a line at the top, not a section).
def fields: ["estimate", "current_state", "approach", "acceptance_criteria", "changes", "governance", "steps",
  "dependencies", "testing", "security", "observability", "risks", "release", "resolved_questions", "assumptions"];
def full_heading($field): {current_state: "Current State", approach: "Approach",
  acceptance_criteria: "Acceptance Criteria Coverage", changes: "Changes by File",
  governance: "Scope & Governance",
  steps: "Implementation Steps", dependencies: "Dependencies & Configuration", testing: "Testing",
  security: "Security & Privacy", observability: "Observability", risks: "Risks", release: "Release & Rollback",
  resolved_questions: "Resolved Technical Questions", assumptions: "Assumptions"}[$field];

# One field's blocks in the full plan (none for an empty optional section).
def full_section($field; $plan):
  if $field == "estimate" then estimate($plan)
  elif $field == "current_state" then section("Current State"), ($plan.current_state[] | para(.))
  elif $field == "approach" then approach($plan; true)
  elif $field == "acceptance_criteria" then coverage($plan)
  elif $field == "changes" then
    section("Changes by File"),
    (if ($plan.changes | length) == 0 then
       para("None the build makes: every change is a manual change (Scope & Governance).")
     else
       {type: "bulletList", content: [$plan.changes[] | {type: "listItem", content: (
         [para([code(.path), text(" (\(.action)) — \(.summary)")])]
         + (if (.details | length) > 0 then [bullets(.details)] else [] end))}]}
     end)
  elif $field == "governance" then
    section("Scope & Governance"),
    para([strong("Risk: "), text("\($plan.governance.risk.level) — \($plan.governance.risk.reason)")]),
    table(["Change kind", "In this plan"];
      [governance_kinds[] | [.[1], (if $plan.governance.includes[.[0]] then "yes" else "no" end)]]),
    para([strong("Also in scope")]), path_list($plan.governance.scope_patterns; "Nothing beyond Changes by File."),
    para([strong("Must not touch")]), path_list($plan.governance.must_not_touch; "Nothing named."),
    para([strong("Manual changes")]),
    (if ($plan.governance.manual_changes | length) > 0
     then bullets([$plan.governance.manual_changes[] | [code(.path), text(" — \(.change)")]])
     else para("None.") end)
  elif $field == "steps" then
    section("Implementation Steps"),
    numbered([$plan.steps[] |
      [para([strong(.title)]), bullets(.details)]
      + (if (.files | length) > 0 then [para([text("Files: ")] + ([.files[] | code(.)] | join_inline(", ")))] else [] end)
      + (if (.criteria | length) > 0 then [para("Covers: " + (.criteria | join("; ")))] else [] end)])
  elif $field == "dependencies" then optional("Dependencies & Configuration"; $plan.dependencies; bullets($plan.dependencies))
  elif $field == "testing" then
    section("Testing"),
    (if ($plan.testing.automated | length) > 0 then para([strong("Automated tests")]), bullets($plan.testing.automated) else empty end),
    (if ($plan.testing.commands | length) > 0 then
       para([strong("Commands")]),
       {type: "codeBlock", content: [text($plan.testing.commands | join("\n"))]}
     else empty end),
    (if ($plan.testing.manual | length) > 0 then para([strong("Manual checks")]), bullets($plan.testing.manual) else empty end)
  elif $field == "security" then
    section("Security & Privacy"),
    (if ($plan.security | length) > 0 then bullets($plan.security)
     else para("No security or privacy impact identified.") end)
  elif $field == "observability" then
    section("Observability"),
    (if ($plan.observability | length) > 0 then bullets($plan.observability)
     else para("No observability changes needed.") end)
  elif $field == "risks" then optional("Risks"; $plan.risks; bullets([$plan.risks[] | [strong(.risk), text(" — \(.mitigation)")]]))
  elif $field == "release" then
    section("Release & Rollback"),
    (if ($plan.release.steps | length) > 0 then numbered([$plan.release.steps[] | [para(.)]])
     else para("No release steps beyond merging.") end),
    para([strong("Rollback: "), text($plan.release.rollback)])
  elif $field == "resolved_questions" then
    optional("Resolved Technical Questions"; $plan.resolved_questions;
      bullets([$plan.resolved_questions[] | [strong(.question), text(" \(.answer)")] + references("Evidence"; .evidence)]))
  elif $field == "assumptions" then optional("Assumptions"; $plan.assumptions; bullets($plan.assumptions))
  else error("Unknown plan field: \($field)") end;

# Sections every plan has (the others are left out when empty).
def always: ["current_state", "approach", "acceptance_criteria", "changes", "steps", "testing", "security", "release"];

def markdown(blocks): {content: [blocks]} | to_markdown;


# Splice updated sections into the attached plan's Markdown: it's split at its
# "## " headings (md_sections); each updated section replaces its namesake, or
# is inserted before the first later section in plan order; the estimate line
# is replaced in place.
def splice($md; $updates):
  ($md | md_sections) as $parts
  | ($parts[0] | rtrimstr("\n")) as $head
  | [$parts[1:][] | rtrimstr("\n") | {heading: heading_key, text: .}
     | select(.heading != "Expert review")] as $sections
  | [fields[] | full_heading(.) // empty] as $order
  | (if $updates | has("estimate") then
       markdown(estimate($updates)) as $line
       | if ($head | test("(?m)^\\*\\*Estimate:\\*\\*")) then $head | sub("(?m)^\\*\\*Estimate:\\*\\*.*$"; $line)
         else $head + "\n\n" + $line end
     else $head end) as $head
  | reduce ($updates | keys_unsorted[] | select(. != "estimate")) as $field ($sections;
      full_heading($field) as $heading
      | (markdown(full_section($field; $updates)) | ltrimstr("## ")) as $text
      | (map(.heading) | index($heading)) as $at
      | if $at != null then
          if $text == "" then del(.[$at]) else .[$at].text = $text end
        elif $text == "" then .
        else
          ($order | index($heading)) as $rank
          | ([to_entries[] | select(.value.heading as $h | ($order | index($h)) as $r | $r != null and $r > $rank) | .key][0] // length) as $i
          | .[:$i] + [{heading: $heading, text: $text}] + .[$i:]
        end)
  | [$head, (.[] | .text)] | join("\n\n## ");

# The summary's parts: the estimate line (before the first heading), then the
# Approach, Acceptance Criteria Coverage and Implementation Steps sections.
def summary_part($field; $plan):
  if $field == "estimate" then estimate($plan)
  elif $field == "approach" then approach($plan; false)
  elif $field == "acceptance_criteria" then coverage($plan)
  elif $field == "steps" then section("Implementation Steps"), summary_steps($plan)
  else empty end;

# Re-render only the updated parts of the current summary (the blocks under
# the description's Implementation Plan heading); the pointer goes last. Parts
# not updated are kept as they are (for the steps, the list itself).
def summary_patch($updates):
  section_blocks("Implementation Plan") as $current
  | {content: $current} as $doc
  | def kept($title): ($doc | section_index($title)) as $i
      | if $i == null then [] else [$current[$i]] + ($doc | section_blocks($title)) end;
    ([$current | to_entries[] | select(.value.type == "heading") | .key][0] // ($current | length)) as $first
  # Before the first heading: the estimate line, then the risk line (none in
  # summaries written before it existed).
  | (if $updates | has("estimate") then [summary_part("estimate"; $updates)] else $current[:$first][:1] end)
    + (if $updates | has("governance") then [risk_line($updates)] else $current[:$first][1:] end)
    + (if $updates | has("approach") then [summary_part("approach"; $updates)] else kept("Approach") end)
    + (if $updates | has("acceptance_criteria") then [summary_part("acceptance_criteria"; $updates)] else kept("Acceptance Criteria Coverage") end)
    + (if $updates | has("steps") then [summary_part("steps"; $updates)] else kept("Implementation Steps")[:2] end)
    + [pointer];

if $mode == "missing" then
  [$ARGS.named.md | md_sections[1:][] | heading_key] as $present
  | [$ARGS.named.updates[0] | keys_unsorted[] | select(IN(always[])) | full_heading(.)
     | select(IN($present[]) | not)]
elif $mode == "duplicated" then
  # Sections the revision changes that the file has more than once: which to
  # change would be a guess.
  [$ARGS.named.md | md_sections[1:][] | heading_key] as $present
  | [$ARGS.named.updates[0] | keys_unsorted[] | select(. != "estimate") | full_heading(.) // empty
     | select(. as $h | [$present[] | select(. == $h)] | length > 1)]
elif $mode == "splice" then splice($ARGS.named.md; $ARGS.named.updates[0])
elif $mode == "summary-patch" then summary_patch($ARGS.named.updates[0])
else
  . as $plan
  | if $mode == "summary" then [
      summary_part("estimate"; $plan),
      risk_line($plan),
      summary_part("approach"; $plan),
      summary_part("acceptance_criteria"; $plan),
      summary_part("steps"; $plan),
      pointer
    ]
    else [fields[] as $field | full_section($field; $plan)] end
end
