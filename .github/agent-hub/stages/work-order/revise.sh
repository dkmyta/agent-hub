# shellcheck shell=bash
# Revisions of a work order (see docs/architecture.md). A revision returns
# only the changed fields, grouped like the work order (overview.summary,
# scope.acceptance_criteria, …), so fields are optional two levels down.
# shellcheck disable=SC2034 # read by lib/runners/claude-code.sh
REVISION_DEPTH=2

# revision_description <updates.json> < description.json: the description (ADF)
# with only the updated sections replaced — the rest, including people's
# edits, stays exactly as it is.
revision_description() {
  jq -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode patch --slurpfile updates "$1"
}

# revision_missing_sections <updates.json> < description.json: the headings
# the updates need that the description no longer has, e.g. "Out of Scope",
# comma-separated; nothing if all are there.
revision_missing_sections() {
  jq -r -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode missing --slurpfile updates "$1" \
    | jq -r 'map("\"\(.)\"") | join(", ")'
}

# revision_edited_sections <updates.json> < description.json: the headings
# the updates change that were edited since the run started (the fetched
# description), comma-separated; nothing if none were.
revision_edited_sections() {
  jq -r -L "$HUB_DIR/lib" -f "$STAGE_DIR/render.jq" --arg mode edited --slurpfile updates "$1" \
      --slurpfile before <(jq '.fields.description' "$RUNNER_TEMP/ticket.json") \
    | jq -r 'map("\"\(.)\"") | join(", ")'
}

# revision_preview <updates.json>: the whole revised work order as Markdown,
# for the expert review.
revision_preview() {
  jq '.fields.description' "$RUNNER_TEMP/ticket.json" | revision_description "$1" \
    | jq -r -L "$HUB_DIR/lib" 'include "adf"; to_markdown'
}
