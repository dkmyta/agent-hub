# Render a work order (the `work_order` object from schema.json) as the
# ticket description: h3 groups with h4 sections, separated by dividers.
#
#   jq -L "$HUB_DIR/lib" -f render.jq work-order.json
#       the whole description
#   jq -L "$HUB_DIR/lib" -f render.jq --arg mode patch --slurpfile updates U description.json
#       a revision: the current description with only the sections in U (a
#       subset of the work order's groups and fields) replaced — everything
#       else, including people's edits, stays as it is
#   jq -L "$HUB_DIR/lib" -f render.jq --arg mode missing --slurpfile updates U description.json
#       the headings U needs that the description no longer has (e.g. removed
#       by hand), so the run can say so before changing anything
#
# Later stages replace the Delivery placeholders by heading, so keep those
# headings stable.

include "adf";

# Each field's heading (summary has none: it opens the Overview group).
def field_heading($group; $field): {
  overview: {clarifications: "Clarifications", important_details: "Important Details"},
  scope: {acceptance_criteria: "Acceptance Criteria", out_of_scope: "Out of Scope"},
  developer_notes: {codebase: "Where Things Are in the Codebase", resources: "Resources & Background",
    getting_started: "Getting Started"},
  risk: {confidence: "Confidence / Risk", customer_data: "Contains Customer Data (Y/N)",
    open_questions: "Open Questions / Assumptions"}
}[$group][$field];

# Each field's blocks.
def field_blocks($field; $value):
  if $field == "summary" then [$value[] | para(.)]
  elif $field == "acceptance_criteria" then [checkboxes("acceptance-criteria"; $value)]
  elif $field == "codebase" then [bullets([$value[] | [code(.path), text(" — \(.relevance)")]])]
  elif $field == "resources" then [bullets([$value[]
      | [strong(.topic), text(": \(.summary)")]
        + (if (.sources | length) > 0
           then [text(" Sources: ")] + ([.sources[] | link(.)] | join_inline(", "))
           else [] end)])]
  elif $field == "confidence" or $field == "customer_data" then
    [para("\($value | .level // .contains) — \($value.reason)")]
  else [bullets($value)] end;

def section($group; $field; $value): h4(field_heading($group; $field)), field_blocks($field; $value)[];

def updated_headings: [$ARGS.named.updates[0] | to_entries[] | .key as $group | .value | keys_unsorted[]
  | if . == "summary" then "Overview" else field_heading($group; .) end];

if ($ARGS.named.mode // "full") == "missing" then
  . as $doc | [updated_headings[] | select(. as $h | $doc | section_index($h) == null)]
elif ($ARGS.named.mode // "full") == "patch" then
  reduce ($ARGS.named.updates[0] | to_entries[] | .key as $group | .value | to_entries[] | {group: $group, field: .key, value: .value}) as $u
    (.; if $u.field == "summary" then replace_intro("Overview"; field_blocks("summary"; $u.value))
        else replace_section(field_heading($u.group; $u.field); field_blocks($u.field; $u.value)) end)
else
  .overview as $overview
  | .scope as $scope
  | .developer_notes as $notes
  | .risk as $risk
  | doc([
      h3("Overview"),
        field_blocks("summary"; $overview.summary)[],
        section("overview"; "clarifications"; $overview.clarifications),
        section("overview"; "important_details"; $overview.important_details),
      divider,
      h3("Scope"),
        section("scope"; "acceptance_criteria"; $scope.acceptance_criteria),
        section("scope"; "out_of_scope"; $scope.out_of_scope),
      divider,
      h3("Developer Notes"),
        section("developer_notes"; "codebase"; $notes.codebase),
        section("developer_notes"; "resources"; $notes.resources),
        section("developer_notes"; "getting_started"; $notes.getting_started),
      divider,
      h3("Risk & Open Questions"),
        section("risk"; "confidence"; $risk.confidence),
        section("risk"; "customer_data"; $risk.customer_data),
        section("risk"; "open_questions"; $risk.open_questions),
      divider,
      h3("Delivery"),
        h4("Implementation Plan"), para("Pending — added once the plan is approved."),
        h4("Testing Instructions"), para("Pending — added once implementation is complete."),
        h4("Pull Request"), para("Pending — added once implementation begins.")
    ])
end
