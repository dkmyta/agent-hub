// Text helpers.

/** "Hello, World!" → "hello-world" */
export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** The number of words, separated by whitespace. */
export function wordCount(text) {
  const trimmed = text.trim();
  return trimmed === "" ? 0 : trimmed.split(/\s+/).length;
}

/** Shortens text to at most maxLength characters, ending in "…", cutting at a space when possible. */
export function truncate(text, maxLength) {
  if (!Number.isInteger(maxLength) || maxLength < 1) {
    throw new RangeError("truncate: maxLength must be an integer of at least 1");
  }
  if (text.length <= maxLength) return text;
  const space = text.slice(0, maxLength).lastIndexOf(" ");
  const kept = space === -1 ? text.slice(0, maxLength - 1) : text.slice(0, space);
  return kept.trimEnd() + "…";
}
