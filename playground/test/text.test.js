import assert from "node:assert/strict";
import { test } from "node:test";
import { slugify, wordCount } from "../src/text.js";

test("slugify lowercases and joins words with hyphens", () => {
  assert.equal(slugify("Hello, World!"), "hello-world");
  assert.equal(slugify("  Already-slugged  "), "already-slugged");
});

test("wordCount counts whitespace-separated words", () => {
  assert.equal(wordCount("one two  three"), 3);
  assert.equal(wordCount("   "), 0);
});
