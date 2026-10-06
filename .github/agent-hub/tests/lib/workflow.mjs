// Reads a workflow file so tests run its real step scripts.
//
//   node workflow.mjs extract <workflow> <dir>   write <dir>/env.sh and <dir>/<step-id>.sh
//   node workflow.mjs shape <workflow>           step names, ids, conditions and env keys
//   node workflow.mjs timeouts <workflow> [caller] job and step timeout-minutes as JSON, with
//                                                `${{ inputs.X }}` resolved from the caller's `with`
//   node workflow.mjs checkout <workflow>        the actions/checkout step's `with` as JSON
//   node workflow.mjs excludes <workflow>        paths the sparse checkout leaves out, one per line
//
// Steps without an id are written as the slug of their name, e.g.
// "Apply work order to ticket" → apply-work-order-to-ticket.sh.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { parse } from "yaml";

const [command, file, dir] = process.argv.slice(2);
const caller = command === "timeouts" && dir ? parse(readFileSync(dir, "utf8")) : null;
const workflow = parse(readFileSync(file, "utf8"), { merge: true });
const jobs = Object.values(workflow.jobs);
if (jobs.length !== 1) throw new Error(`${file}: expected exactly one job`);
const steps = jobs[0].steps;

export const slug = (step) =>
  step.id ?? step.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const quote = (value) => `'${String(value).replaceAll("'", `'\\''`)}'`;

if (command === "extract") {
  mkdirSync(dir, { recursive: true });
  // The workflow's and the job's env. Expression values (the stage, the ticket
  // key, the repository variables) are provided by the test; with no VARS,
  // settings take their defaults, like a fresh installation.
  const env = Object.entries({ ...workflow.env, ...jobs[0].env })
    .filter(([, value]) => !String(value).includes("${{"))
    .map(([key, value]) => `export ${key}=${quote(value)}`);
  writeFileSync(`${dir}/env.sh`, env.join("\n") + "\n");
  for (const step of steps.filter((s) => s.run)) writeFileSync(`${dir}/${slug(step)}.sh`, step.run);
} else if (command === "shape") {
  for (const step of steps) {
    const env = Object.keys(step.env ?? {}).join(",") || "-";
    // Action versions are left out: Dependabot updates them, and the shape is
    // about the steps and their conditions.
    const name = step.name ?? step.uses.replace(/@.*$/, "");
    console.log(`${name} | id: ${step.id ?? "-"} | if: ${step.if ?? "-"} | env: ${env}`);
  }
} else if (command === "checkout" || command === "excludes") {
  const checkout = steps.find((s) => s.uses?.startsWith("actions/checkout@"));
  if (command === "checkout") {
    console.log(JSON.stringify(checkout?.with ?? {}));
  } else {
    // "!/tests/*/fixtures/" → "/tests/*/fixtures/" (usable as an rsync exclude)
    const patterns = String(checkout?.with?.["sparse-checkout"] ?? "").split("\n").map((p) => p.trim());
    for (const p of patterns.filter((p) => p.startsWith("!"))) console.log(p.slice(1));
  }
} else if (command === "timeouts") {
  // A reusable workflow's limits can come from its caller's inputs.
  const inputs = caller ? Object.values(caller.jobs)[0].with ?? {} : {};
  const resolve = (value) => {
    const name = String(value ?? "").match(/^\$\{\{\s*inputs\.([\w-]+)\s*\}\}$/)?.[1];
    return name ? (inputs[name] ?? null) : (value ?? null);
  };
  // Steps only code stages run (if: inputs.code-stage …) count only for a
  // caller that sets code-stage.
  const codeStage = inputs["code-stage"] === true;
  const stepTimeouts = steps
    .filter((s) => s.run || s.uses?.startsWith("actions/setup-node@"))
    .filter((s) => codeStage || !String(s.if ?? "").includes("inputs.code-stage"))
    .map((s) => ({ step: s.name, minutes: resolve(s["timeout-minutes"]) }));
  console.log(JSON.stringify({ job: resolve(jobs[0]["timeout-minutes"]), steps: stepTimeouts }));
} else {
  throw new Error(`Unknown command: ${command}`);
}
