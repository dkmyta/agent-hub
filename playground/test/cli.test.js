import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { test } from "node:test";

const cli = new URL("../src/cli.js", import.meta.url).pathname;

test("the CLI runs a command on its text", () => {
  assert.equal(execFileSync("node", [cli, "slugify", "Hello", "World"], { encoding: "utf8" }), "hello-world\n");
});

test("the CLI explains an unknown command", () => {
  const run = spawnSync("node", [cli, "shout", "hi"], { encoding: "utf8" });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /Usage:/);
});
