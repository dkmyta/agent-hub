# Installing and updating the hub

The hub is copied into each repository that uses it, and updated by
replacing its files wholesale with a newer version. One script does both.
Your repository's own files — its extensions
(`.github/agent-hub-extensions/`), other workflows, templates and code — are
never touched.

## Versions

Each release has a version number in `VERSION` (`MAJOR.MINOR.PATCH`) and an
entry in [CHANGELOG.md](../CHANGELOG.md) saying what changed and what a
repository has to do when updating to it (its **Updating** line). Releases
are git tags on the hub repository (`v1.0.0`). A repository's installed
version is in its own `.github/agent-hub/VERSION`.

- **Patch** (1.0.**1**): fixes; nothing to do but update.
- **Minor** (1.**1**.0): new features, compatible; anything new to set up is
  optional.
- **Major** (**2**.0.0): something must change when updating — a renamed
  variable, a Jira rule, a required check — listed under **Updating**.

## What the hub's files are

| Path | Installed |
|---|---|
| `.github/agent-hub/` | Always |
| `.github/workflows/agent-hub-*.yml` | Always |
| `.github/ISSUE_TEMPLATE/agent-hub-request.yml` | Only for the GitHub Projects tracker (`--with-issue-form`); kept up to date once installed |

Everything else belongs to your repository. Anything named `agent-hub-*` in
`.github/workflows/` belongs to the hub, so don't add your own workflows with
that prefix — an update would remove them.

**Don't edit the hub's files in your repository**, including through
automated pull requests: Dependabot, for example, may propose newer action
versions for the `agent-hub-*` workflows. Decline those — the hub's releases
bring them — or the next update reports those files as changed here and
stops (`--force` overwrites them).

## Installing

From the root of the repository to install into, on a new branch — with
`vX.Y.Z` replaced by the release you want (the newest is the top entry of
[CHANGELOG.md](../CHANGELOG.md), and the newest tag):

```sh
git clone --depth 1 --branch vX.Y.Z https://github.com/dkmyta/agent-hub /tmp/agent-hub
/tmp/agent-hub/.github/agent-hub/scripts/update.sh /tmp/agent-hub
# GitHub Projects as the tracker? Add --with-issue-form.
```

A repository with no `.github/agent-hub-extensions/` folder also gets one,
holding only a README on what goes there ([extending.md](extending.md));
nothing in it is loaded until you add stage folders. Then review the new
files, commit them, and continue with [setup.md](setup.md) from step 2
(runner, secrets, variables, tracker).

## Updating

1. Read [CHANGELOG.md](../CHANGELOG.md) in the new version, from your
   installed version up, especially the **Updating** lines.
2. From the repository's root, on a new branch:

   ```sh
   git clone --depth 1 --branch vX.Y.Z https://github.com/dkmyta/agent-hub /tmp/agent-hub
   /tmp/agent-hub/.github/agent-hub/scripts/update.sh /tmp/agent-hub
   ```

   Run the **new** version's script, as above, so the update logic is the
   newest too.
3. Review the changes (`git status`, `git diff`), do what the **Updating**
   lines say, and open a pull request. CI runs the new version's tests in your
   repository; the pull request's **Agent behaviour changed** notice says
   which stages to try or evaluate.

**Undoing an update:** revert its pull request — the previous version's files
come back as they were. Before committing, this puts back the hub's changed
and deleted files, without touching anything else:

```sh
git restore .github/agent-hub ':(glob).github/workflows/agent-hub-*.yml'
git restore .github/ISSUE_TEMPLATE/agent-hub-request.yml   # only if you use the intake form
```

then delete any new hub files `git status` lists as untracked.

**Undo the manual steps too.** A revert brings back the files, not the
changes you made by hand when updating — each release's **Updating** list in
the [CHANGELOG](../CHANGELOG.md). Undo the ones the older version can't work
with. For example, going back before 2.20.0: the stage job no longer uses
the `agent-hub` environment, so secrets moved there must go back to the
repository level, and Jira rules already switched to `workflow_dispatch`
keep working only while the older version's workflows accept it.

## What the script checks

It stops, changing nothing, when:

- it isn't run from the root of a git repository, or the path given isn't a
  copy of the hub;
- the hub's files have uncommitted changes;
- **hub files were changed in your repository** since the last install or
  update — edited, deleted or added. It names them, so the changes aren't
  silently lost. Move them into an extension
  ([extending.md](extending.md)) or propose them to the hub, then run again;
  `--force` overwrites them;
- the hub's folder exists but wasn't installed by the script (e.g. copied by
  hand), so local changes can't be detected — check, then use `--force`.

It knows what it installed from `.github/agent-hub/.installed` — a checksum
of every file it installed, written on every install and update. Commit it
with the rest.

## Releasing a version (hub maintainers)

In the hub repository, as part of the pull request with the changes:

1. Bump `VERSION` (see [Versions](#versions)).
2. Add a `CHANGELOG.md` entry at the top: `## <version> — <date>`, what
   changed, and an **Updating** line ("Nothing" if there's nothing to do). A
   test checks the newest entry matches `VERSION`.

After it merges, tag the merge commit and push the tag:

```sh
git tag vX.Y.Z <merge commit> && git push origin vX.Y.Z
```
