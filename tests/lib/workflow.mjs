// Reads a workflow file so tests run its real step scripts.
//
//   node workflow.mjs extract <workflow> <dir>   write <dir>/env.sh and <dir>/<step-id>.sh
//   node workflow.mjs shape <workflow>           step names, ids, conditions and env keys
//   node workflow.mjs timeouts <workflow>        job and step timeout-minutes as JSON
//
// Steps without an id are written as the slug of their name, e.g.
// "Apply work order to ticket" → apply-work-order-to-ticket.sh.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { parse } from "yaml";

const [command, file, dir] = process.argv.slice(2);
const workflow = parse(readFileSync(file, "utf8"), { merge: true });
const jobs = Object.values(workflow.jobs);
if (jobs.length !== 1) throw new Error(`${file}: expected exactly one job`);
const steps = jobs[0].steps;

export const slug = (step) =>
  step.id ?? step.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const quote = (value) => `'${String(value).replaceAll("'", `'\\''`)}'`;

if (command === "extract") {
  mkdirSync(dir, { recursive: true });
  // Expression values (e.g. the ticket key) are provided by the test.
  const env = Object.entries(workflow.env ?? {})
    .filter(([, value]) => !String(value).includes("${{"))
    .map(([key, value]) => `export ${key}=${quote(value)}`);
  writeFileSync(`${dir}/env.sh`, env.join("\n") + "\n");
  for (const step of steps.filter((s) => s.run)) writeFileSync(`${dir}/${slug(step)}.sh`, step.run);
} else if (command === "shape") {
  for (const step of steps) {
    const env = Object.keys(step.env ?? {}).join(",") || "-";
    console.log(`${step.name ?? step.uses} | id: ${step.id ?? "-"} | if: ${step.if ?? "-"} | env: ${env}`);
  }
} else if (command === "timeouts") {
  const stepTimeouts = steps.filter((s) => s.run).map((s) => ({ step: s.name, minutes: s["timeout-minutes"] ?? null }));
  console.log(JSON.stringify({ job: jobs[0]["timeout-minutes"] ?? null, steps: stepTimeouts }));
} else {
  throw new Error(`Unknown command: ${command}`);
}
