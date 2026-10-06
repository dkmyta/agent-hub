# Runners and Claude access

The agent hub pipeline needs somewhere Claude Code can run and a Claude account to
run it with. Two setups are supported; switching between them is a matter of
secrets and variables, not workflow edits.

| | **Self-hosted runner + Claude subscription** (default) | **Claude API** |
|---|---|---|
| Where it runs | A machine you register as a runner, labelled `claude` | GitHub-hosted runners (or a self-hosted one) |
| Claude account | Claude Code logged in on that machine (Pro, Max, Team or Enterprise plan) | An API key in the `AGENT_HUB_ANTHROPIC_API_KEY` secret |
| Cost per run | Nothing billed; runs use the plan's usage limits | Billed per run at API prices |
| Runs in parallel | One per runner | As many as runners allow |
| Maintenance | Keep the machine on, tools installed, login fresh | None with GitHub-hosted runners |
| Configure with | Nothing (the default) | `AGENT_HUB_ANTHROPIC_API_KEY` secret + `AGENT_HUB_RUNS_ON` variable |

Every run's summary shows the models used, the Claude Code version, and the
**API-equivalent cost** — what the run would cost on the API, whichever setup
is used.

## Self-hosted runner with a Claude subscription

1. **Register the runner**: Settings → Actions → Runners → **New self-hosted
   runner**, follow GitHub's steps, and install it as a service so it survives
   restarts. (Organisation-level runners work too, and can serve several
   repositories.)
2. **Label it `claude`** (Settings → Actions → Runners → the runner → labels).
   Jobs wait indefinitely for a runner with the labels in `AGENT_HUB_RUNS_ON`.
3. **Install on the machine**, on the runner service's `PATH`: Claude Code
   (`claude`), `jq` 1.7+, `curl`, `bash`, `git`, and Node 22
   (for the evals).
4. **Log in**: run `claude` once as the user the runner service runs as, and
   log in with the Claude account the automation should use.
5. **Check it**: Actions → **Agent hub: Work order → Run workflow** with a test
   ticket's key.

Things to know:
- **Usage limits are shared** with anyone else using that Claude login.
  Each stage's budget caps (`AGENT_HUB_<STAGE>_MAX_BUDGET_USD` and the others
  in [setup.md](setup.md#4-set-variables-only-what-differs-from-the-defaults),
  in API-equivalent dollars) stop a runaway run before it uses up the plan's
  allowance.
- **If the login expires**, runs fail and the ticket gets the failure comment;
  log in again on the machine.
- **Only the login is shared, not your personal Claude setup.** Runs ignore
  that account's own settings, `CLAUDE.md`, hooks and MCP servers (in
  `~/.claude`), so the agents behave the same on anyone's runner.
- **One runner per machine (or per OS user).** Runs clean up Claude Code's
  session files when they end, but two runners under the same user can run
  jobs at once, and one could read the other's while both are running. For
  the strongest isolation between jobs, GitHub recommends ephemeral runners
  (one job each, then a fresh machine) — practical with the Claude API on
  GitHub-hosted or autoscaled runners, less so for one machine with a
  subscription login.
- **The machine is trusted**: a self-hosted runner can reach anything the
  machine can. The agent hub pipeline never runs on `pull_request` events, so code
  from forks never runs on it — a test enforces this. Keep it that way.

## Using the Claude API

1. **Create an API key** in the [Claude Console](https://console.anthropic.com)
   (set a monthly spend limit there as well) and add it as the repository
   secret **`AGENT_HUB_ANTHROPIC_API_KEY`**. The workflows pass it only to the agent step.
2. **Choose where it runs**:
   - **GitHub-hosted runners**: set the variable **`AGENT_HUB_RUNS_ON`** to
     `["ubuntu-latest"]`. The workflows install Claude Code on the runner
     (`AGENT_HUB_CLAUDE_CODE_VERSION`, default `latest` — pin it for repeatability;
     the build requires an exact version).
   - **A self-hosted runner**: keep the default, but make sure Claude Code on
     that machine is **not logged in** — a login takes precedence over the API
     key.
3. **Review the stages' budget caps** (`AGENT_HUB_<STAGE>_*_BUDGET_USD`) — they're now real money per run.
4. **Check it works**: run one real ticket through, or the evals (Actions →
   Agent hub: Evals, stage **all**) if the cost is acceptable.

Amazon Bedrock or Google Vertex AI work the same way with their Claude Code
environment variables instead of `ANTHROPIC_API_KEY` (add them as secrets and
to the agent step's `env` in `agent-hub-stage.yml`).

## Clearing old session files (one-time, for runners set up before this was fixed)

Also after a runner machine went down mid-run: its cleanup step couldn't run.

Runs now delete their Claude Code session files when they end (see
[architecture.md](architecture.md#safety)), but a runner that ran the agents
before that keeps their session records — full transcripts of real tickets —
and temp folders. Delete them once, as the runner's user, with no run in
progress. They're named after the runner's work folder, with `/` and `_`
turned into `-` (`~/actions-runner/_work/…` becomes `-…-actions-runner--work-…`;
use your runner's folder name if it's installed elsewhere). List them first:

```sh
ls -d ~/.claude/projects/*actions-runner--work-* /tmp/claude-$(id -u)/*actions-runner--work-* 2>/dev/null
```

Then remove them. Only jobs run in the work folder, so this never touches your
own Claude Code sessions:

```sh
rm -rf ~/.claude/projects/*actions-runner--work-* /tmp/claude-$(id -u)/*actions-runner--work-*
```

## Claude Code version

Claude Code updates itself on a self-hosted runner by default, and an update
can change how the agents behave without any change in the repository. The
run summary and the evals show the version used. The workflows set
`DISABLE_AUTOUPDATER=1`, so it never updates during a run; to keep it from
updating between runs too (when you use Claude Code on that machine
yourself), and to upgrade deliberately:

1. Add `DISABLE_AUTOUPDATER=1` to the runner's `.env` file (in the runner's
   install directory) and restart the runner service.
2. To upgrade: run `claude update` on the runner, run the
   [sandbox check](#checking-the-sandbox), then **Agent hub: Evals** with stage
   **all**, and — for the build — set `AGENT_HUB_CLAUDE_CODE_VERSION` to the new
   version.

On GitHub-hosted runners, `AGENT_HUB_CLAUDE_CODE_VERSION` is the version
installed; pin it and change it deliberately.

**The build requires a pinned version.** Its boundary rests on how the
installed version enforces the sandbox, so it runs only when
`AGENT_HUB_CLAUDE_CODE_VERSION` is an exact version (e.g. `2.1.280`, not
`latest`) and the runner's `claude --version` matches it. That's checked
before any Claude usage, and a mismatch stops the build saying both versions.
The pin keeps the version from changing beneath the build; it doesn't prove
the sandbox works on the runner — that's the sandbox check, which uses
Claude, so it's run by hand (on a new runner, after every Claude Code
upgrade, and after changing the sandbox settings or the runner's setup) and
never automatically before a build.

The hub needs a Claude Code with restricted mode (`claude --help` lists
`--restricted`): it keeps the agents inside the repository whatever the
repository's settings say. A version without it stops the run, saying so.

## The sandbox (build stage)

The build stage runs commands — the repository's tests, linters
and builds — in Claude Code's sandbox: they read only the repository and a
temp folder, write only those, reach only localhost, and get no secrets in
their environment (an API key included). If the sandbox can't start, the
command doesn't run. The hub's own steps that run the repository's code
without an agent — installing its dependencies, and re-running its checks
on the build's commit — use the same sandbox runtime (`srt`, which the hub
installs once per runner into its tool cache, from a lockfile), with the
package registries as the only network for the install
([build.md](workflows/build.md#install)). The document stages don't run
commands, so they don't need it.

| Runner | What the sandbox needs |
|---|---|
| macOS (self-hosted) | Nothing — it uses macOS's built-in Seatbelt |
| Linux (self-hosted) | `bubblewrap`, `socat` and `ripgrep`: `sudo apt-get install bubblewrap socat ripgrep` (Debian/Ubuntu) or your distribution's equivalent. On Ubuntu 24.04 and later, also allow unprivileged user namespaces: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (and in `/etc/sysctl.d/` to keep it) |
| GitHub-hosted (Linux, with the Claude API) | Installed by the build workflow (its **Install sandbox tools** step) |

Every runner also needs **npm** on its `PATH` before the build starts (the
workflow's **Set up Node** step provides it) — the hub installs `srt` with
it — and network access to `registry.npmjs.org` for that first install.

The build also needs **git 2.40 or later** on the runner (it reads
`.gitattributes` from the commit it checks, not the working tree).

**Node comes from the repository, not the runner.** The build workflow sets
up the Node version the repository declares (`actions/setup-node`, into the
runner's tool cache) and makes that one folder readable in the sandbox, so
the runner's own Node — through nvm or otherwise — doesn't matter
([build.md](workflows/build.md#toolchain)). **Other tools installed in your
home folder aren't visible to the build's commands:** the sandbox denies
reading the home folder (where credentials live), so a toolchain installed
there — Python through pyenv or `~/.local`, Ruby through rbenv — can't run
inside it, and commands fall back to whatever is installed outside the home
folder (e.g. `/usr/local/bin`), which may be older or missing. Keep the tools
a non-Node repository's checks need installed outside the home folder.

### Checking the sandbox

The agents' limits are Claude Code's to enforce, so check them with the real
Claude Code **on a new runner** (macOS or Linux), **after every Claude Code
upgrade**, and **before turning the build stage on**:

```sh
.github/agent-hub/scripts/check-sandbox.sh   # from the repository root, on the runner
```

It asks you to type `use-claude` (it uses Claude: two short sessions, about
$0.20, capped under $1), works in a throwaway copy of the repository under
your home folder, and removes it afterwards. It checks, with the hub's own
runner code:

- **Read-only profile** (the document stages): a hostile repository setup — a
  settings file, a `CLAUDE.md` asking for forbidden access, an agent declaring
  a permission mode, hooks and extra tools, a skill pre-approving tools, a
  linked agent from outside — gains nothing: no shell, no reading outside the
  repository, no fetch off the allowlist, no linked agent, no hooks run. The
  repository's `CLAUDE.md`, agents and skills still load (each visibly
  changes Claude's answer), without Claude Code's bundled skills.
- **Build profile** (the build stage): commands can't read the home folder or
  a planted secret file, write outside the repository, reach the internet,
  see a planted environment secret, or edit `.github/`; they can write the
  repository and a temp folder, and use localhost.

Each result is checked on disk and in Claude's output, not just from its
report. It prints a line per check and fails if any does. **If a check fails,
don't run the build stage on that runner**: pin the previous Claude Code
version (see [Claude Code version](#claude-code-version)) and report it.

### Before running the build on real tickets

The sandbox keeps commands away from your files, credentials and the
internet, but two things remain within reach on the runner machine:

- **Anything listening on localhost** — local databases, dev servers, admin
  pages — because commands may use localhost (tests often start a local
  server).
- **Whatever Claude Code itself can read**: only commands are sandboxed;
  Claude Code's own file tools are bounded by restricted mode (the repository
  only) and the hub's deny rules, not by the sandbox.

On a personal machine that's acceptable for developing and testing the hub,
not for real tickets. Before then, use one of: a **dedicated macOS or Linux
user** for the runner (your files, logins and keychain then aren't
reachable), a **dedicated machine**, or **GitHub-hosted runners with the
Claude API** (a fresh machine every run).

## When Claude is used

Only when a ticket or a person asks for it — never from the tests, git hooks
or CI. What triggers it and what it typically costs:
[claude-usage.md](claude-usage.md).
