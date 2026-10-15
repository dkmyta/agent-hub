# Live test evidence

Copy this file **outside the repository** for each journey run: it can hold
ticket content. Record facts as observed, not as expected; a later reader
should be able to check each one from its run, commit or ticket.

## Run

| | |
|---|---|
| Journey | |
| Tracker | |
| Hub version | (the test repository's `.github/agent-hub/VERSION`) |
| Installed from | (`update.sh --check`'s "Installed from" line) |
| Test repository | |
| Runner, Claude Code version | |
| Ticket | |
| Pull request | |
| Date, person | |

## Steps

One row per observation. Outcome: **passed**, **failed**, **waiting** (not
yet observable), **blocked** (a prerequisite failed) or **inconclusive**
(observed, but it doesn't settle the expectation).

| Step | Observation | Expected | Actual | Outcome | Evidence (run id + attempt, commit, comment id) |
|---|---|---|---|---|---|
| | | | | | |

## Cost

| Stage run (run id) | Claude (API-equivalent, from the run summary) | Tracker automation runs |
|---|---|---|
| | | |
| **Total** | | |

## Deviations

What differed from the journey, why, and what follows: a hub fix, a
journey fix, or nothing.
