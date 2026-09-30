// Lists workflows that use Claude on anything other than a Jira request
// (repository_dispatch) or a manual run (workflow_dispatch). Prints nothing
// when every Claude-using workflow is on-demand only.
//
//   node claude-triggers.mjs <workflows dir>
import { readFileSync, readdirSync } from "node:fs";
import { parse } from "yaml";

const dir = process.argv[2];
const onDemand = ["repository_dispatch", "workflow_dispatch"];

for (const file of readdirSync(dir).filter((f) => /\.ya?ml$/.test(f))) {
  const workflow = parse(readFileSync(`${dir}/${file}`, "utf8"), { merge: true });
  const scripts = Object.values(workflow.jobs).flatMap((job) => job.steps.map((s) => s.run ?? ""));
  // Direct calls, the shared runner (lib/claude.sh), or the evals.
  const usesClaude = scripts.some((run) => /(^|[\s;&|(])claude\s|lib\/claude\.sh|claude_run|npm run evals/m.test(run));
  // `on:` can be a string, a list, or a map of triggers.
  const on = workflow.on ?? workflow[true] ?? {};
  const triggers = typeof on === "string" ? [on] : Array.isArray(on) ? on : Object.keys(on);
  const other = triggers.filter((t) => !onDemand.includes(t));
  if (usesClaude && other.length) console.log(`${file}: uses Claude on ${other.join(", ")}`);
}
