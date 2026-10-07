# shellcheck shell=bash
# A fix pass that breaks the build: greet() now always throws.
cat > src/greet.js <<'JS'
export function greet() {
  throw new Error("broken");
}
JS
