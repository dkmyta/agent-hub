// Lists workflows that use Claude on anything other than a ticket request
// (repository_dispatch), a manual run (workflow_dispatch), or a call from
// another workflow (workflow_call, which inherits its caller's trigger).
// Prints nothing when every Claude-using workflow is on-demand only.
//
//   node claude-triggers.mjs <workflows dir>
import { readFileSync, readdirSync } from "node:fs";
import { basename } from "node:path";
import { parse } from "yaml";

const dir = process.argv[2];
const onDemand = ["repository_dispatch", "workflow_dispatch", "workflow_call"];
const workflows = Object.fromEntries(readdirSync(dir).filter((f) => /\.ya?ml$/.test(f))
  .map((f) => [f, parse(readFileSync(`${dir}/${f}`, "utf8"), { merge: true })]));

// Direct calls, the agent runner (lib/runners/), the evals — or calling a
// workflow in this folder that uses Claude.
const usesClaude = (file, seen = new Set()) => {
  if (seen.has(file) || !workflows[file]) return false;
  seen.add(file);
  return Object.values(workflows[file].jobs).some((job) =>
    (job.uses?.startsWith("./") && usesClaude(basename(job.uses), seen)) ||
    (job.steps ?? []).some((s) => /(^|[\s;&|(])claude\s|lib\/runners\/|agent_run|npm run evals/m.test(s.run ?? "")));
};

for (const [file, workflow] of Object.entries(workflows)) {
  // `on:` can be a string, a list, or a map of triggers.
  const on = workflow.on ?? workflow[true] ?? {};
  const triggers = typeof on === "string" ? [on] : Array.isArray(on) ? on : Object.keys(on);
  const other = triggers.filter((t) => !onDemand.includes(t));
  if (usesClaude(file) && other.length) console.log(`${file}: uses Claude on ${other.join(", ")}`);
}
