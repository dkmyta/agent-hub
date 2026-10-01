# shellcheck shell=bash
# Revisions of a plan (see docs/architecture.md). The attached Markdown file is
# the plan's source of truth — people may edit and re-upload it — so a
# revision returns only the changed fields and they're spliced into that file.
# shellcheck disable=SC2034 # read by lib/claude.sh
REVISION_DEPTH=1

# revision_plan_markdown <updates.json> <current plan.md>: the plan file with
# only the updated sections replaced (its old review notes dropped).
revision_plan_markdown() {
  jq -nr -L "$AGENTS_DIR/lib" -f "$AGENT_DIR/render.jq" --arg mode splice --arg file "" --argjson level 2 \
    --rawfile md "$2" --slurpfile updates "$1"
}

# revision_version_line <line> < plan.md: the plan with its version line (or
# the older "Written by …" line) replaced by <line> — or, if someone removed
# it, <line> added under the title.
revision_version_line() {
  awk -v version="$1" '
    { lines[++n] = $0
      if (!at && ($0 ~ /^_Version: / || $0 ~ /^Written by the implementation plan workflow/)) at = n }
    END {
      for (i = 1; i <= n; i++) {
        print (i == at ? version : lines[i])
        if (!at && i == 1) { print ""; print version }
      }
    }'
}

# revision_missing_sections <updates.json> <current plan.md>: the headings of
# sections every plan has that the revision changes but the file no longer
# has (removed or renamed by hand), comma-separated; nothing if all are there.
revision_missing_sections() {
  jq -nr -L "$AGENTS_DIR/lib" -f "$AGENT_DIR/render.jq" --arg mode missing --arg file "" --argjson level 2 \
    --rawfile md "$2" --slurpfile updates "$1" | jq -r 'map("\"\(.)\"") | join(", ")'
}

# revision_summary <updates.json> <plan file name> < description.json: the
# blocks for the description's Implementation Plan section, with only the
# updated parts of the summary re-rendered.
revision_summary() {
  jq -L "$AGENTS_DIR/lib" -f "$AGENT_DIR/render.jq" --arg mode summary-patch --arg file "$2" --argjson level 5 \
    --slurpfile updates "$1"
}

# revision_preview <updates.json>: the whole revised plan, for the expert review.
revision_preview() { revision_plan_markdown "$1" "$RUNNER_TEMP/current-plan.md"; }
