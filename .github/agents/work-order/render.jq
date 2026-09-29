# Render a work order (the `work_order` object from schema.json) as the Jira
# ticket description: h3 groups with h4 sections, separated by dividers.
#
# Usage:  jq -L "$AGENTS_DIR/lib" -f render.jq work-order.json
#
# Later stages replace the Delivery placeholders by heading, so keep those
# headings stable.

include "adf";

.overview as $overview
| .scope as $scope
| .developer_notes as $notes
| .risk as $risk
| doc([
    h3("Overview"),
      ($overview.summary[] | para(.)),
      h4("Clarifications"), bullets($overview.clarifications),
      h4("Important Details"), bullets($overview.important_details),
    divider,
    h3("Scope"),
      h4("Acceptance Criteria"), checkboxes("acceptance-criteria"; $scope.acceptance_criteria),
      h4("Out of Scope"), bullets($scope.out_of_scope),
    divider,
    h3("Developer Notes"),
      h4("Where Things Are in the Codebase"),
        bullets([$notes.codebase[] | [code(.path), text(" — \(.relevance)")]]),
      h4("Resources & Background"),
        bullets([$notes.resources[]
          | [strong(.topic), text(": \(.summary)")]
            + (if (.sources | length) > 0
               then [text(" Sources: ")] + ([.sources[] | link(.)] | join_inline(", "))
               else [] end)]),
      h4("Getting Started"), bullets($notes.getting_started),
    divider,
    h3("Risk & Open Questions"),
      h4("Confidence / Risk"), para("\($risk.confidence.level) — \($risk.confidence.reason)"),
      h4("Contains Customer Data (Y/N)"), para("\($risk.customer_data.contains) — \($risk.customer_data.reason)"),
      h4("Open Questions / Assumptions"), bullets($risk.open_questions),
    divider,
    h3("Delivery"),
      h4("Implementation Plan"), para("Pending — added once the plan is approved."),
      h4("Testing Instructions"), para("Pending — added once implementation is complete."),
      h4("Pull Request"), para("Pending — added once implementation begins.")
  ])
