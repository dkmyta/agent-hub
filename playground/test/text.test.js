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

test("truncate returns text no longer than maxLength unchanged", () => {
  assert.equal(truncate("hello", 10), "hello");
  assert.equal(truncate("hello", 5), "hello");
});

test("truncate cuts at the last space before the limit", () => {
  assert.equal(truncate("hello world foo", 12), "hello world…");
  assert.equal(truncate("hello world", 8), "hello…");
  assert.ok(truncate("hello world foo", 12).length <= 12);
  assert.ok(truncate("hello world", 8).length <= 8);
});

test("truncate cuts mid-word when there is no space", () => {
  assert.equal(truncate("abcdefghij", 5), "abcd…");
  assert.ok(truncate("abcdefghij", 5).length <= 5);
  assert.equal(truncate("hello", 1), "…");
});

test("truncate removes spaces before the ellipsis", () => {
  assert.equal(truncate("hello    world", 9), "hello…");
});

test("truncate throws when maxLength is below 1", () => {
  assert.throws(() => truncate("hello", 0), /maxLength must be/);
  assert.throws(() => truncate("hello", -1), /maxLength must be/);
});
