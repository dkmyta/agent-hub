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

test("the CLI truncates text to maxLength", () => {
  assert.equal(execFileSync("node", [cli, "truncate", "12", "hello", "world", "foo"], { encoding: "utf8" }), "hello world…\n");
});

test("the CLI rejects a maxLength below 1", () => {
  for (const max of ["0", "abc"]) {
    const run = spawnSync("node", [cli, "truncate", max, "hi"], { encoding: "utf8" });
    assert.equal(run.status, 2);
    assert.match(run.stderr, /Usage:.*truncate <maxLength>/s);
  }
});

test("the CLI title-cases text", () => {
  assert.equal(execFileSync("node", [cli, "title-case", "hELLO", "wORLD"], { encoding: "utf8" }), "Hello World\n");
  assert.equal(execFileSync("node", [cli, "title-case", "a  b"], { encoding: "utf8" }), "A  B\n");
});
