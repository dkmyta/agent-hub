#!/usr/bin/env bats
# The settings (lib/settings.sh and each stage's settings.sh): repository
# variables (VARS, as the workflow passes them) or the defaults.

setup() {
  load ../lib/helpers
}

# settings <stage> <VARS json> <name>...: each setting's value, one per line.
settings() {
  local stage=$1 vars=$2; shift 2
  STAGE=$stage VARS=$vars bash -c 'source "$HUB_DIR/lib/settings.sh" && for name; do printf "%s\n" "${!name}"; done' _ "$@"
}

@test "with no repository variables, every setting has its default" {
  run settings work-order "" TRACKER AGENT_RUNNER CLAUDE_MODEL CLAUDE_MAX_BUDGET_USD WORK_ORDER_STATUS REVISE_COMMAND HOME_STATUS STAGE_DIR
  assert_output "jira
claude-code
claude-sonnet-5-5
2.00
Work Order
/revise
Work Order
$HUB_DIR/stages/work-order"
  run settings implementation-plan "{}" CLAUDE_MODEL CLAUDE_MAX_BUDGET_USD REVISION_MAX_BUDGET_USD HOME_STATUS
  assert_output "claude-opus-5-5
5.00
2.00
Work Order Approved"
}

@test "a repository variable overrides the default; an empty one doesn't" {
  run settings work-order '{"AGENT_HUB_WORK_ORDER_STATUS": "Ready to plan", "AGENT_HUB_REVISE_COMMAND": "", "AGENT_HUB_WORK_ORDER_MODEL": "x"}' \
    WORK_ORDER_STATUS HOME_STATUS REVISE_COMMAND CLAUDE_MODEL
  assert_output "Ready to plan
Ready to plan
/revise
x"
}

@test "each stage reads its own AGENT_HUB_<STAGE>_* settings; one stage's never changes another's" {
  local vars='{"AGENT_HUB_IMPLEMENTATION_PLAN_MODEL": "plan-model", "AGENT_HUB_WORK_ORDER_REVIEW_MAX_BUDGET_USD": "9.00"}'
  run settings implementation-plan "$vars" CLAUDE_MODEL REVIEW_CLAUDE_MAX_BUDGET_USD
  assert_output "plan-model
5.00"
  run settings work-order "$vars" CLAUDE_MODEL REVIEW_CLAUDE_MAX_BUDGET_USD
  assert_output "claude-sonnet-5-5
9.00"
  # The review model is shared by every stage.
  run settings work-order '{"AGENT_HUB_REVIEW_MODEL": "reviewer"}' REVIEW_CLAUDE_MODEL
  assert_output reviewer
}

@test "values with spaces, quotes and shell syntax are kept as text" {
  run settings work-order '{"AGENT_HUB_INTAKE_STATUS": "To do $(false) \"now\" '"'"'s"}' INTAKE_STATUS
  assert_output "To do \$(false) \"now\" 's"
}

@test "malformed VARS falls back to the defaults" {
  run settings work-order "not json" WORK_ORDER_STATUS
  assert_output "Work Order"
}

@test "lib/load.sh refuses an unknown part" {
  run bash -c 'STAGE=work-order source "$HUB_DIR/lib/load.sh" tracer'
  assert_failure
  assert_output --partial "unknown part 'tracer'"
}

@test "a tracker or runner that isn't one of the hub's: refused by name, before anything loads" {
  run bash -c 'STAGE=work-order RUNNER_TEMP="$1" VARS="{\"AGENT_HUB_TRACKER\": \"../../tmp/x\"}" source "$2/lib/load.sh" tracker' _ "$BATS_TEST_TMPDIR" "$HUB_DIR"
  assert_failure
  assert_output --partial "AGENT_HUB_TRACKER is '../../tmp/x', which isn't one of the hub's trackers (jira)"
  run bash -c 'STAGE=work-order RUNNER_TEMP="$1" VARS="{\"AGENT_HUB_RUNNER\": \"codex\"}" source "$2/lib/load.sh" agent' _ "$BATS_TEST_TMPDIR" "$HUB_DIR"
  assert_failure
  assert_output --partial "AGENT_HUB_RUNNER is 'codex', which isn't one of the hub's agent runners (claude-code)"
}

# Every setting the code defines is in setup.md, with the default the code
# has: the settings files are the source, and the docs can't drift from them.
# A default documented in words (a list of sites, the licences) or for an
# empty one ("none", "latest") isn't compared.
@test "setup.md documents every setting, with the code's default" {
  run node --input-type=module -e '
    import { readFileSync, readdirSync } from "node:fs";
    const hub = process.argv[1], doc = readFileSync(`${hub}/docs/setup.md`, "utf8").split("\n");
    const defs = [];
    const read = (file, stage) => {
      for (const line of readFileSync(file, "utf8").split("\n")) {
        const m = line.match(/^(stage_)?setting_into \S+ (\S+) (.*)$/);
        if (!m) continue;
        defs.push({ stage: m[1] ? stage : null, name: m[2], dflt: m[3].trim().replace(/^(["\x27])(.*)\1$/, "$2") });
      }
    };
    read(`${hub}/lib/settings.sh`, null);
    for (const s of readdirSync(`${hub}/stages`)) read(`${hub}/stages/${s}/settings.sh`, s);
    const codes = (cell) => [...(cell ?? "").matchAll(/`([^`]*)`/g)].map((m) => m[1]);
    const only = (cell) => /^\s*(`[^`]*`(,\s*)?)+\s*$/.test(cell ?? "");
    const row = (pred) => doc.map((l) => l.split("|").slice(1, -1).map((c) => c.trim())).find((cells) => cells.length > 1 && pred(cells));
    const problems = [];
    const compare = (what, cell, i, dflt) => {
      if (dflt === "" || !only(cell)) return;
      const got = codes(cell)[i];
      if (got !== dflt) problems.push(`${what}: documented ${got}, the code has ${dflt}`);
    };
    for (const d of defs) {
      if (!d.stage) {
        const r = row((c) => codes(c[0]).includes(d.name));
        if (!r) { problems.push(`${d.name}: not in setup.md`); continue; }
        compare(d.name, r[1], 0, d.dflt);
      } else if (d.stage !== "build") {
        const col = { "work-order": 1, "implementation-plan": 2 }[d.stage];
        const r = row((c) => codes(c[0]).includes(d.name) && c.length >= 4);
        if (!r) { problems.push(`${d.stage} ${d.name}: not in setup.md`); continue; }
        compare(`${d.stage} ${d.name}`, r[col], 0, d.dflt);
      } else {
        const r = row((c) => codes(c[0]).includes(d.name) && c.length === 3);
        if (r) { compare(`build ${d.name}`, r[1], codes(r[0]).indexOf(d.name), d.dflt); continue; }
        const prose = doc.join("\n").match(new RegExp("`" + d.name + "`\\s+\\(`([^`]*)`"));
        if (prose) { if (d.dflt !== "" && prose[1] !== d.dflt) problems.push(`build ${d.name}: documented ${prose[1]}, the code has ${d.dflt}`); continue; }
        if (!doc.join("\n").includes(`AGENT_HUB_BUILD_${d.name}`)) problems.push(`build ${d.name}: not in setup.md`);
      }
    }
    console.log(problems.join("\n") || `${defs.length} settings documented`);' "$HUB_DIR"
  assert_success
  assert_output --regexp '^[0-9]+ settings documented$'
}
