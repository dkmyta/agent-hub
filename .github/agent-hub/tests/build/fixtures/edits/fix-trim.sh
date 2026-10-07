# shellcheck shell=bash
# The fix pass's change for the review's finding 1: trim the name, with a test.
cat > src/greet.js <<'JS'
export function greet(name) {
  const trimmed = name?.trim();
  return trimmed ? `Hello, ${trimmed}!` : "Hello!";
}
JS
cat >> test/greet.test.js <<'JS'

test("a name of only spaces greets without one", () => {
  assert.equal(greet("  "), "Hello!");
});
JS
