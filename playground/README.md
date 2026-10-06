# Playground

A tiny Node.js project for trying the agent hub's build stage in this
repository: small enough that a build is quick and cheap, with real tests
for the build to run and extend. It has no dependencies yet, declares its
Node version in `.nvmrc`, and has a `package-lock.json`, so a plan can add
npm packages to it: the build's dependency step applies them itself.

- `src/text.js` — text helpers (`slugify`, `wordCount`)
- `src/cli.js` — a command-line front end: `node src/cli.js slugify "Hello World"`
- `test/` — the tests, run with `npm test` (Node's built-in test runner)

Its CI is `.github/workflows/playground-tests.yml`, which runs the tests on
pull requests that change this folder, with the Node version in `.nvmrc`.
The build runs them too, on every build's commit, before anything is pushed:
the repository declares them in
`.github/agent-hub-extensions/build/checks.json`, since this project is in a
subfolder (the build looks for a `package.json` at the repository root),
with `"install": ["playground"]` so its dependencies are installed for them.

## Trying the build

Create a Jira ticket asking for a small change here (for example, "add a
`truncate` helper to the playground's text helpers"), then take it through
the pipeline: work order, implementation plan, approval. The build opens a
draft pull request on `agent-hub/<KEY>`. See
[docs/workflows/build.md](../.github/agent-hub/docs/workflows/build.md) and
the manual testing steps in the hub's CHANGELOG.

Anything may change here; nothing depends on it.
