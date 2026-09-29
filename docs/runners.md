# Runners

> **Current setup:** the agent workflows run on **one self-hosted runner** (a
> Mac, label `claude`) where Claude Code is **logged in with a personal Claude
> Pro subscription**. Nothing is billed per run; runs draw on the
> subscription's usage limits. No Anthropic API key is used anywhere.
>
> To move to the **Claude API**, see [Switching to the Claude API](#switching-to-the-claude-api).
> Nothing in the prompts, schemas, Jira steps or tests changes.

## How Claude is authenticated today

The Claude step runs `claude -p …` on the runner. Claude Code uses the
login stored on that machine (made once by running `claude` as the runner's
user), so the workflow needs no Claude secret.

What that means in practice:

| | With the current subscription login |
|---|---|
| **Cost per run** | None billed. The run summary's "Cost (API-equivalent)" shows what the run *would* cost on the API ($0.10–0.80 per work order so far) |
| **Limits** | Runs use the Pro plan's usage limits, **shared with your own Claude use** — heavy days of tickets and personal use compete |
| **`CLAUDE_MAX_BUDGET_USD` ($2)** | Stops a run once it passes $2 API-equivalent (~2.5× the largest run so far), so a runaway run can't eat the plan's usage. With the API it becomes a real spending cap |
| **Parallelism** | One job at a time on one runner |
| **If the login expires** | Runs fail and the ticket gets the failure comment; run `claude` on the runner and log in again |

## Setting up the self-hosted runner

1. Add the runner: repo **Settings → Actions → Runners → New self-hosted
   runner**, follow GitHub's steps, and install it as a service so it survives
   restarts.
2. Give it the **`claude`** label (Settings → Actions → Runners → the runner →
   labels). Jobs wait for a runner with this label indefinitely.
3. Install on the machine, on the runner service's `PATH`: `claude` (Claude
   Code CLI), `jq` (1.6+; 1.7 recommended), `curl`, `bash`, `git`, and Node 22
   (for the eval workflow).
4. Log in: run `claude` once as the runner's user and complete the login.
5. Check it: **Actions → Agent — Work Order → Run workflow** with the key of a
   test ticket in the Work Order status.

**The machine is trusted.** A self-hosted runner can reach anything the
machine can, and this repository is public. The agent workflows never run on
`pull_request` events, so code from forks never runs on the runner — keep it
that way (CI for pull requests runs on GitHub-hosted runners).

## Switching to the Claude API

Do this when usage outgrows the subscription, when work should be billed to a
team rather than a personal plan, or to run several tickets in parallel.
Claude Code reads an API key from the `ANTHROPIC_API_KEY` environment
variable, so only the workflow's runner and the Claude step's environment
change.

### Steps

1. **Create an API key** in the [Claude Console](https://console.anthropic.com)
   (set a monthly spend limit there too), and add it as the repository secret
   **`ANTHROPIC_API_KEY`**.
2. **Give only the Claude step the key**, in `agent-work-order.yml`:
   ```yaml
   - name: Generate work order (Claude Code)
     id: claude
     env:
       ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
   ```
3. **Choose where it runs:**
   - **Keep the self-hosted runner** — nothing else changes. Remove the
     subscription login from the runner (or use a runner without one) so it's
     unambiguous which account is used.
   - **Or use GitHub-hosted runners** (parallel runs, no machine to maintain):
     ```yaml
     runs-on: ubuntu-latest   # was [self-hosted, claude]
     steps:
       - uses: actions/checkout@v6
         with:
           persist-credentials: false
       - run: npm install -g @anthropic-ai/claude-code@<version>   # pin it
     ```
     These runners have jq 1.7, which the tests already cover.
4. **Review the Claude settings** in the workflow's `env:` —
   `CLAUDE_MAX_BUDGET_USD` is now real money per run.
5. **Make the same change to `agent-evals.yml`** and run the evals before
   switching the Jira rule over.
6. **Update this page's "Current setup"** note and the workflow's comment above
   `runs-on`.

Amazon Bedrock and Google Vertex AI work the same way, using their Claude
Code environment variables instead of `ANTHROPIC_API_KEY`.

### Comparison

| | Subscription on a self-hosted runner (today) | API key |
|---|---|---|
| Billing | Flat subscription | Per run (API pricing) |
| Limits | Plan usage limits, shared with personal use | Your API rate and spend limits |
| Runs in parallel | One per runner | As many as GitHub-hosted runners allow |
| Maintenance | Keep the machine on, tools installed, login fresh | None with GitHub-hosted runners |
| Account | A person's plan | Can belong to a team or organisation |
