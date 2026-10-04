# shellcheck shell=bash
# The plan's change: greet by name, with a test.
cat > src/greet.js <<'JS'
export function greet(name) {
  return name ? `Hello, ${name}!` : "Hello!";
}
JS
cat >> test/greet.test.js <<'JS'

test("greets by name", () => {
  assert.equal(greet("Ada"), "Hello, Ada!");
});
JS
