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

/** Shortens text to at most max characters, ending in "…" when cut. */
export function truncate(text, max) {
  if (max <= 0) return "";
  if (text.length <= max) return text;
  return text.slice(0, max - 1) + "…";
}
