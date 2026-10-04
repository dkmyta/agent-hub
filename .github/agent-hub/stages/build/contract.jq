# The approved plan's contract, read back from the attached plan file (the
# implementation-plan stage writes its sections with fixed headings and
# labels; people may edit it, so it's read, not trusted to be well-formed):
#
#   jq -Rs -L "$HUB_DIR/lib" -f contract.jq plan.md
#
# → {base_commit, changes: [{path, action}], governance: {risk, includes,
#    scope_patterns, must_not_touch, manual_changes}, dependencies, problems}
#
# Every problem is listed (a missing section, a missing or unreadable label);
# the build stops on any, rather than guess what was approved.

include "markdown";

def kinds: [
  ["dependencies", "Dependencies"], ["schema_or_migration", "Schema or migration"],
  ["public_api", "Public API or contract"], ["auth_or_permissions", "Auth or permissions"],
  ["sensitive_data", "Sensitive data"], ["infrastructure", "Infrastructure"],
  ["workflow_or_ci", "Workflow or CI"], ["configuration", "Configuration"]];

# The section titled $title, as lines (without its heading), or null.
def section($title): [md_sections[1:][] | select(heading_key == $title) | split("\n")[1:]] | first;

# The `code` items of a bulleted list (one per "- `x`" line).
def code_items: [.[] | capture("^- `(?<p>[^`]+)`") | .p];

# The lines after a "**Label**" line, up to the next "**…**" line.
def after_label($label):
  . as $lines
  | ([$lines | to_entries[] | select(.value == "**\($label)**") | .key] | first) as $at
  | if $at == null then null
    else $lines[$at + 1:] | (([to_entries[] | select(.value | test("^\\*\\*[^*]+\\*\\*$")) | .key] | first) // length) as $end
      | .[:$end] end;

. as $md
| ($md | gsub("\r\n"; "\n")) as $md
| ($md | section("Changes by File")) as $changes
| ($md | section("Scope & Governance")) as $gov
| ($md | section("Dependencies & Configuration")) as $deps
| [
    (if ($md | test("against commit [0-9a-f]{40}")) then empty else "no base commit in the Version line" end),
    (if $changes == null then "no Changes by File section" else empty end),
    (if $gov == null then "no Scope & Governance section (the plan predates it: revise it)" else empty end)
  ] as $structural
| ($gov // []) as $g
| ([$g[] | capture("^\\*\\*Risk:\\*\\* (?<level>low|medium|high) — (?<reason>.+)$")] | first) as $risk
| ([kinds[] as [$key, $label]
    | {key: $key, value: ([$g[] | capture("^\\| \(($label | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\\(.)"))) \\| (?<v>yes|no) \\|$")
        | .v == "yes"] | first)}] | from_entries) as $includes
| {
    base_commit: ([$md | capture("against commit (?<c>[0-9a-f]{40})") | .c] | first),
    changes: [($changes // [])[] | capture("^- `(?<path>[^`]+)` \\((?<action>add|modify|delete)\\)")],
    governance: (if $gov == null then null else {
      risk: $risk,
      includes: $includes,
      scope_patterns: ($g | after_label("Also in scope") // [] | code_items),
      must_not_touch: ($g | after_label("Must not touch") // [] | code_items),
      manual_changes: [($g | after_label("Manual changes") // [])[] | capture("^- `(?<path>[^`]+)` — (?<change>.+)$")]
    } end),
    dependencies: (($deps // []) | join("\n")),
    problems: ($structural + (if $gov == null then [] else
      [(if $risk == null then "no readable risk level" else empty end),
       ($includes | to_entries[] | select(.value == null) | "no yes/no for \"\(.key)\""),
       ([["Also in scope"], ["Must not touch"], ["Manual changes"]][] as [$label]
         | if ($g | after_label($label)) == null then "no \"\($label)\" list" else empty end)] end))
  }
