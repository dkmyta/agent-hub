import assert from "node:assert/strict";
import { test } from "node:test";
import { greet } from "../src/greet.js";

test("greets", () => {
  assert.equal(greet(), "Hello!");
});
