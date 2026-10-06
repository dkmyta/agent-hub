# shellcheck shell=bash
# The plan's change, with a test that fails: the hub's checks catch it.
bash -e "$(dirname "${BASH_SOURCE[0]}")/greet.sh"
cat >> test/greet.test.js <<'JS'

test("greets in French", () => {
  assert.equal(greet("Ada"), "Bonjour, Ada!");
});
JS
