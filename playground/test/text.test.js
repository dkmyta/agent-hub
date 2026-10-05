import assert from "node:assert/strict";
import { test } from "node:test";
import { slugify, truncate, wordCount } from "../src/text.js";

test("slugify lowercases and joins words with hyphens", () => {
  assert.equal(slugify("Hello, World!"), "hello-world");
  assert.equal(slugify("  Already-slugged  "), "already-slugged");
});

test("wordCount counts whitespace-separated words", () => {
  assert.equal(wordCount("one two  three"), 3);
  assert.equal(wordCount("   "), 0);
});

test("truncate leaves short text unchanged and cuts long text to max with an ellipsis", () => {
  assert.equal(truncate("hello", 10), "hello");
  assert.equal(truncate("hello world", 8), "hello w…");
  assert.equal(truncate("hello world", 8).length, 8);
  assert.equal(truncate("hello", 0), "");
  assert.equal(truncate("hello", 1), "…");
  assert.equal(truncate("", 5), "");
});
