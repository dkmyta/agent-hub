# Runners and Claude access

The agent hub pipeline needs somewhere Claude Code can run and a way for it to
reach Claude. **How the hub reaches Claude** is one of two setups — a
self-hosted runner logged in to a Claude account (a subscription plan), or a
Claude API key (on GitHub-hosted or self-hosted runners) — and switching
between them is a matter of secrets and variables, not workflow edits.

| | **Self-hosted runner + Claude subscription** (default) | **Claude API** |
|---|---|---|
| Where it runs | A machine you register as a runner, labelled `claude` | GitHub-hosted runners (or a self-hosted one) |
| Claude account | Claude Code logged in on that machine (Pro, Max, Team or Enterprise plan) | An API key in the `AGENT_HUB_ANTHROPIC_API_KEY` secret |
| Cost per run | Nothing billed; runs use the plan's usage limits | Billed per run at API prices |
| Runs in parallel | One per runner | As many as runners allow |
| Maintenance | Keep the machine on, tools installed, login fresh | None with GitHub-hosted runners |
| Configure with | Nothing (the default) | `AGENT_HUB_ANTHROPIC_API_KEY` secret + `AGENT_HUB_RUNS_ON` variable |
| Check the setup with | `check-sandbox.sh` on the machine, or **Agent hub: Sandbox check** | **Agent hub: Sandbox check** (Actions) |
| Proven so far | End to end, on a macOS self-hosted runner (2.5–2.7) | Built and tested without a real key; **not yet run with one** ([Not yet verified](#not-yet-verified-the-claude-api)) |

Every run says **how it reached Claude** — "Claude access: a logged-in Claude
account (pro)", "an API key", or another provider — in the run log, the run
summary's *Claude access* column, and the build's pull request and ticket
(read from `claude auth status`, which uses no Claude; the account's email
and organisation, which that also gives, are never recorded). A runner with
both a key and a login gets a warning. Every summary also shows the models
used, the Claude Code version and the **API-equivalent cost** — what the run
would cost on the API. With a subscription that's a measure of how much of
the plan's usage it took; with an API key, it's what's billed (the build's
pull request and ticket say which).

## Self-hosted runner with a Claude subscription

1. **Register the runner**: Settings → Actions → Runners → **New self-hosted
   runner**, follow GitHub's steps, and install it as a service so it survives
   restarts. (Organisation-level runners work too, and can serve several
   repositories.)
2. **Label it `claude`** (Settings → Actions → Runners → the runner → labels).
   Jobs wait indefinitely for a runner with the labels in `AGENT_HUB_RUNS_ON`.
3. **Install on the machine**, on the runner service's `PATH`:
   - every stage: Claude Code (`claude`, and the Node it runs on), `jq`
     1.7+, `curl`, `bash` (3.2, as macOS has it, is enough) and `git`;
   - the build, too: `git` 2.40+, `perl` and `npm` (the hub installs its
     sandbox runtime with it; the build sets up the repository's own Node
     version for each job), and on Linux the sandbox's tools
     ([The sandbox](#the-sandbox-build-stage));
   - the sandbox check: `rsync` and `python3`;
   - the evals: Node 22.

   macOS and Ubuntu have all of these but Claude Code, `jq` and Node.
4. **Log in**: run `claude` once as the user the runner service runs as, and
   log in with the Claude account the automation should use. Make that a user
   of its own, not yours: Claude Code shares its temp folder between
   everything one user runs, so the agents' commands would share it with
   your own sessions. A run warns when it finds that
   ([Before running the build on real tickets](#before-running-the-build-on-real-tickets)).
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
- **Everyone with write access can run code on it.** Anyone who can push a
  branch can push a workflow of their own with `runs-on: [self-hosted,
  claude]`, and it runs as the runner's user, outside any sandbox — able to
  read the Claude login in `~/.claude` (or the macOS keychain) and anything
  else that user can. The `agent-hub` environment keeps GitHub's secrets
  from runs on other branches; it can't protect what's on the machine. So
  treat the runner's Claude login as shared with everyone who has write
  access. Where that's too wide: in an organisation, a runner group limited
  to this repository's hub workflows on the default branch; otherwise the
  Claude API on GitHub-hosted runners (nothing kept on a machine).

## Using the Claude API

1. **Create an API key** in the [Claude Console](https://console.anthropic.com)
   (set a monthly spend limit there as well) and add it as the secret
   **`AGENT_HUB_ANTHROPIC_API_KEY`** in the **`agent-hub` environment**,
   limited to the default branch ([setup.md](setup.md#3-add-secrets)) — not
   at the repository level, where a run on any branch could read it. The
   workflows pass it only to the agent steps. (For the evals with the API,
   the `agent-hub-evals` environment needs its own copy.)
2. **Choose where it runs**:
   - **GitHub-hosted runners**: set the variable **`AGENT_HUB_RUNS_ON`** to
     `["ubuntu-latest"]`. The workflows install Claude Code on the runner
     (`AGENT_HUB_CLAUDE_CODE_VERSION`, default `latest` — pin it for repeatability;
     the build requires an exact version).
   - **A self-hosted runner**: keep the default, and make sure Claude Code on
     that machine is **not logged in** (`claude auth logout` as the runner's
     user). With both a key and a login, which one Claude Code uses in a
     run isn't verified yet — the run warns; keep only one.
3. **Review the stages' budget caps** (`AGENT_HUB_<STAGE>_*_BUDGET_USD`) — they're now real money per run.
4. **Check it works**: run **Actions → Agent hub: Sandbox check** (type
   `use-claude`; about $0.30) — every line should be `ok`, and the log's
   "Claude access:" line should say "an API key". Then one real ticket, or
   the evals (Actions → Agent hub: Evals) if the cost is acceptable.

### Switching between them

- **To the API:** add the `AGENT_HUB_ANTHROPIC_API_KEY` secret to the
  `agent-hub` environment; for
  GitHub-hosted runners, set `AGENT_HUB_RUNS_ON` to `["ubuntu-latest"]`
  (and `AGENT_HUB_CLAUDE_CODE_VERSION` to an exact version); then the sandbox
  check above.
- **Back to the subscription:** delete `AGENT_HUB_RUNS_ON` (or set it to your
  runner's labels) and the environment's `AGENT_HUB_ANTHROPIC_API_KEY` secret — an empty
  secret means no key — and check the "Claude access:" line of the next run.
- Nothing else changes: the stages, budgets, extensions and Jira rules are
  the same either way.

### Not yet verified: the Claude API

Everything the API setup needs is built and tested without a real key — the
workflows pass the key only to the agent step and the sandbox check,
install the pinned Claude Code and the sandbox tools on GitHub-hosted runners,
and the hub's own sandbox is tested on Linux in CI — but no run has used a
real key yet. Before relying on it:

1. **The sandbox check on a GitHub-hosted runner, with a key**: set up as
   above, run Agent hub: Sandbox check, and confirm every line is `ok` —
   above all the build profile's (Claude Code's sandbox on Linux has only
   been checked with stand-ins) — and "Claude access: an API key".
2. **One playground build** on that runner, end to end; the pull request's
   Run line should say "billed to the API key".
3. **Which access wins when a runner has both** (a key and a login): until
   checked, keep only one. A run warns when it sees both.
4. Then switch back, if the subscription runner is the one you use.

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
and builds — in Claude Code's sandbox: they can't read the home folder or the
runner's own folders — its install folder, temp folder and tool cache,
wherever it's installed (since 2.21.0) — apart from the repository, their
temp folder and the toolchain; they write only the repository and that temp
folder, reach only localhost, and get no secrets in their environment (an
API key included). **The rest of the machine stays readable**: system
folders, `/etc`, `/tmp`, and anything else outside those folders — so keep
secrets of your own off the runner machine (a dedicated machine or OS user:
[below](#before-running-the-build-on-real-tickets)), since what a command
reads could be written into the pull request. If the sandbox can't start, the
command doesn't run. The hub's own steps that run the repository's code
without an agent — installing its dependencies, and re-running its checks
on the build's commit — use the same sandbox runtime (`srt`, which the hub
installs for each job from a lockfile; npm's download cache stays in the
runner's tool cache and is checked against the lockfile every time), with the
package registries as the only network for the install (and, for npm's
signature check on the plan's dependency changes, Sigstore's trust metadata
at `tuf-repo-cdn.sigstore.dev`)
([build.md](workflows/build.md#install)). The document stages don't run
commands, so they don't need it.

| Runner | What the sandbox needs |
|---|---|
| macOS (self-hosted) | Nothing — it uses macOS's built-in Seatbelt |
| Linux (self-hosted) | `bubblewrap`, `socat` and `ripgrep`: `sudo apt-get install bubblewrap socat ripgrep` (Debian/Ubuntu) or your distribution's equivalent. On Ubuntu 24.04 and later, also allow unprivileged user namespaces: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (and in `/etc/sysctl.d/` to keep it) |
| GitHub-hosted (Linux, with the Claude API) | Installed by the build workflow (its **Install sandbox tools** step) |

The hub's sandboxed commands get the job's temp folder as `TMPDIR` (srt
would otherwise hand them a shared `/tmp/claude`). srt itself keeps
`/tmp/claude` writable for every sandboxed command, whatever the settings: a
folder on the runner that commands from different jobs can write to. The
agent's own commands (Claude Code's sandbox) likewise get Claude Code's
per-user temp folder, `/tmp/claude-<uid>`, shared by every job run as that
user (the sandbox check prints it). On a
runner that builds untrusted code, prefer one that starts fresh for each job
(GitHub-hosted, or ephemeral self-hosted runners).

Every runner also needs **npm** on its `PATH` before the build starts (the
workflow's **Set up Node** step provides it) — the hub installs `srt` with
it — and network access to `registry.npmjs.org` the first time (and
whenever the cached download doesn't match). The secret scan's gitleaks is
kept the same way: its release archive in the tool cache, checked against
its pinned checksum on every job, downloaded from GitHub's releases when
it's missing or doesn't match. Other jobs on a self-hosted runner can write
to its tool cache, so nothing there is used unchecked.

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

Or run **Actions → Agent hub: Sandbox check** (type `use-claude`): the same
check, on the runner `AGENT_HUB_RUNS_ON` names and with its access to Claude —
the only way to check a GitHub-hosted runner. Its log says which access it
used ("Claude access: …").

It asks you to type `use-claude` (it uses Claude: three short sessions, about
$0.30, capped under $1.20), works in a throwaway copy of the repository under
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
  see a planted environment secret, edit `.github/`, or hard-link a file
  from outside the repository into it; they can write the
  repository and a temp folder (outside both the repository and the home
  folder; the check shows which), and use localhost.
- **Review profile** (the build's code review and fix check, since 2.9.0): commands still
  run and can read the repository and write the temp folder, but nothing
  writes the repository — not a shell redirect, `touch` or a child process —
  and the file tools are refused.
- It also says which access to Claude it used ("Claude access: …"), so a
  check proves the setup it ran with.

Each result is checked on disk and in Claude's output, not just from its
report. It prints a line per check and fails if any does. **If a check fails,
don't run the build stage on that runner**: pin the previous Claude Code
version (see [Claude Code version](#claude-code-version)) and report it.

### Before running the build on real tickets

The sandbox keeps commands away from the home folder, the runner's own
folders and the internet, but these remain within reach on the runner
machine:

- **The rest of the file system**: system folders, `/etc`, `/tmp` and
  anything outside the home folder and the runner's folders is readable by
  commands, and whatever they read could end up in the pull request.
- **Anything listening on localhost** — local databases, dev servers, admin
  pages — because commands may use localhost (tests often start a local
  server).
- **Whatever Claude Code itself can read**: only commands are sandboxed;
  Claude Code's own file tools are bounded by restricted mode (the repository
  only) and the hub's deny rules, not by the sandbox.
- **Processes a command leaves running (macOS):** the hub's own steps end
  everything a command started when it finishes (since 2.21.0); Claude Code's
  sandbox on macOS may not, so a background process an agent's command
  starts can outlive it. On Linux the sandbox ends them.
- **Everyone with write access**, through a workflow of their own
  ([above](#self-hosted-runner-with-a-claude-subscription)).

On a personal machine that's acceptable for developing and testing the hub,
not for real tickets. Before then, use one of: a **dedicated macOS or Linux
user** for the runner (your files, logins and keychain then aren't
reachable), a **dedicated machine**, or **GitHub-hosted runners with the
Claude API** (a fresh machine every run).

## When Claude is used

Only when a ticket or a person asks for it — never from the tests, git hooks
or CI. What triggers it and what it typically costs:
[claude-usage.md](claude-usage.md).
