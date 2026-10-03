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
     (`AGENT_HUB_CLAUDE_CODE_VERSION`, default `latest` — pin it for repeatability).
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
run summary and the evals show the version used. To upgrade deliberately
instead:

1. Add `DISABLE_AUTOUPDATER=1` to the runner's `.env` file (in the runner's
   install directory) and restart the runner service.
2. To upgrade: run `claude update` on the runner, then run **Agent hub: Evals** with stage **all**.

On GitHub-hosted runners, pin `AGENT_HUB_CLAUDE_CODE_VERSION` and change it deliberately.

The hub needs a Claude Code with restricted mode (`claude --help` lists
`--restricted`): it keeps the agents inside the repository whatever the
repository's settings say. A version without it stops the run, saying so.

## When Claude is used

Only when a ticket or a person asks for it — never from the tests, git hooks
or CI. What triggers it and what it typically costs:
[claude-usage.md](claude-usage.md).
