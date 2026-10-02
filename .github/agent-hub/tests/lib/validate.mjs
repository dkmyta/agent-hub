// Schema checks for the agent hub pipeline.
//
//   node validate.mjs claude-schema <schema.json>             usable as a --json-schema?
//   node validate.mjs output <schema.json> <claude-output> [payload] [bounce field]
//        output matches the schema, and has its stage's payload (default: work_order,
//        or the bounce field, default: missing)?
//   node validate.mjs adf <calls.jsonl>                       every ADF sent to the tracker valid?
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import AjvDraft04 from "ajv-draft-04";

const [command, ...args] = process.argv.slice(2);
const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));
const problems = [];

if (command === "claude-schema") {
  const schema = readJson(args[0]);
  // Claude Code structured output rejects these (found the hard way).
  if (schema.type !== "object") problems.push("top level must be \"type\": \"object\"");
  for (const key of ["anyOf", "oneOf", "allOf"]) {
    if (key in schema) problems.push(`top level can't use ${key}`);
  }
  if (JSON.stringify(schema).includes('"$ref"')) problems.push("inline definitions instead of $ref");
  try {
    new Ajv({ strict: false }).compile(schema);
  } catch (error) {
    problems.push(`does not compile: ${error.message}`);
  }
} else if (command === "output") {
  const validate = new Ajv({ strict: false, allErrors: true }).compile(readJson(args[0]));
  const [, , payload = "work_order", bounceField = "missing"] = args;
  const output = readJson(args[1]).structured_output;
  if (!validate(output)) {
    for (const e of validate.errors) problems.push(`${e.instancePath || "/"} ${e.message}`);
  }
  if (output?.status === "ready" && !output[payload]) problems.push(`ready without ${payload}`);
  if (output?.status && output.status !== "ready" && !output[bounceField]?.length) {
    problems.push(`${output.status} without ${bounceField}`);
  }
} else if (command === "adf") {
  const adfSchema = readJson(fileURLToPath(new URL("../vendor/adf-schema-57.6.16.json", import.meta.url)));
  const validate = new AjvDraft04({ strict: false, allErrors: true }).compile(adfSchema);
  const calls = readFileSync(args[0], "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  calls.forEach((call, index) => {
    const docs = [call.body?.body, call.body?.fields?.description].filter((d) => d?.type === "doc");
    for (const doc of docs) {
      if (!validate(doc)) {
        // ADF is a big anyOf; the deepest error is usually the real one.
        const deepest = validate.errors.reduce((a, b) => (b.instancePath.length > a.instancePath.length ? b : a));
        problems.push(`call ${index + 1} (${call.method} ${call.path}): ${deepest.instancePath} ${deepest.message} ${JSON.stringify(deepest.params)}`);
      }
    }
  });
} else {
  throw new Error(`Unknown command: ${command}`);
}

if (problems.length) {
  for (const problem of problems) console.error(`  ${problem}`);
  process.exit(1);
}
