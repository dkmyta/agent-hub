#!/usr/bin/env bats
# scripts/update.sh: installing and updating the hub in a repository, from a
# copy of the hub (this repository's working tree), into a throwaway one.

setup() {
  load ../lib/helpers
  UPDATE="$HUB_DIR/scripts/update.sh"
  H=.github/agent-hub
  cd "$BATS_TEST_TMPDIR" || return 1
  git init -q -b main repo && cd repo || return 1
  git config user.email test@example.com && git config user.name test
  # The repository's own files, which an install or update must never touch.
  mkdir -p .github/workflows .github/agent-hub-extensions/work-order .github/ISSUE_TEMPLATE
  echo "# App" > README.md
  echo "name: deploy" > .github/workflows/deploy.yml
  echo "name: Bug" > .github/ISSUE_TEMPLATE/bug.yml
  echo "Use British English." > .github/agent-hub-extensions/work-order/guidance.md
  git add -A && git commit -qm "the repository"
}

own_files_untouched() {
  assert_equal "$(cat README.md)" "# App"
  assert_equal "$(cat .github/workflows/deploy.yml)" "name: deploy"
  assert_equal "$(cat .github/ISSUE_TEMPLATE/bug.yml)" "name: Bug"
  assert_equal "$(cat .github/agent-hub-extensions/work-order/guidance.md)" "Use British English."
}

install() { "$UPDATE" "$REPO_DIR" "$@" && git add -A && git commit -qm "install the hub"; }

@test "first install: the hub's files and workflows, a record of them, and nothing else" {
  run "$UPDATE" "$REPO_DIR"
  assert_success
  assert_line "Agent hub: not installed → $(cat "$HUB_DIR/VERSION") ($(wc -l < $H/.installed | tr -d ' ') files)."
  assert_equal "$(cat $H/VERSION)" "$(cat "$HUB_DIR/VERSION")"
  assert [ -f $H/lib/settings.sh ]
  assert [ -x $H/scripts/update.sh ]
  assert [ -f .github/workflows/agent-hub-stage.yml ]
  # Not the hub repository's installed test dependencies, nor the intake form unless asked.
  assert [ ! -e $H/tests/node_modules ]
  assert [ ! -e .github/ISSUE_TEMPLATE/agent-hub-request.yml ]
  # The record lists exactly what was installed.
  run awk '{ print $2 }' $H/.installed
  assert_line .github/workflows/agent-hub-stage.yml
  assert_line $H/VERSION
  refute_line --partial agent-hub-extensions
  refute_line --partial deploy.yml
  own_files_untouched
}

@test "the GitHub Projects intake form only when asked, then kept up to date" {
  [ -f "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml" ] || skip "the GitHub Projects intake form isn't installed here"
  install --with-issue-form
  assert [ -f .github/ISSUE_TEMPLATE/agent-hub-request.yml ]
  echo "stale" > .github/ISSUE_TEMPLATE/agent-hub-request.yml.tmp  # an unrelated file, kept
  run "$UPDATE" "$REPO_DIR"
  assert_success
  assert_equal "$(cat .github/ISSUE_TEMPLATE/agent-hub-request.yml)" "$(cat "$REPO_DIR/.github/ISSUE_TEMPLATE/agent-hub-request.yml")"
  assert_equal "$(cat .github/ISSUE_TEMPLATE/agent-hub-request.yml.tmp)" stale
  own_files_untouched
}

@test "update: files the new version dropped are removed; the repository's own files stay" {
  install
  # As if the installed version had a file and a workflow the new one doesn't.
  echo "old" > $H/lib/old.sh
  echo "name: old" > .github/workflows/agent-hub-old.yml
  git add -A && git commit -qm "the old version's extra files"
  "$UPDATE" "$REPO_DIR" --force > /dev/null
  assert [ ! -e $H/lib/old.sh ]
  assert [ ! -e .github/workflows/agent-hub-old.yml ]
  assert [ -f $H/lib/settings.sh ]
  own_files_untouched
}

@test "update: hub files changed here stop the update, naming them; --force overwrites them" {
  install
  echo "# my tweak" >> $H/lib/stage.sh
  rm $H/docs/evals.md
  echo "mine" > $H/lib/mine.sh
  git add -A && git commit -qm "local changes"
  run "$UPDATE" "$REPO_DIR"
  assert_failure
  assert_output --partial "$H/lib/stage.sh"
  assert_output --partial "$H/docs/evals.md (deleted)"
  assert_output --partial "$H/lib/mine.sh (added)"
  assert_output --partial "Move the changes into an extension"
  # Nothing was changed.
  assert [ -f $H/lib/mine.sh ]
  run "$UPDATE" "$REPO_DIR" --force
  assert_success
  assert_equal "$(cat $H/lib/stage.sh)" "$(cat "$HUB_DIR/lib/stage.sh")"
  assert [ -f $H/docs/evals.md ]
  assert [ ! -e $H/lib/mine.sh ]
}

@test "an update with no changes since the install goes ahead" {
  install
  run "$UPDATE" "$REPO_DIR"
  assert_success
  run git status --porcelain
  assert_output ""
}

@test "refuses: uncommitted changes to the hub's files" {
  install
  echo "# draft" >> $H/README.md
  run "$UPDATE" "$REPO_DIR"
  assert_failure
  assert_output --partial "commit or discard the changes"
}

@test "refuses: a hub folder that wasn't installed by the script, unless --force" {
  mkdir -p $H && echo "0.9.0" > $H/VERSION && git add -A && git commit -qm "copied by hand"
  run "$UPDATE" "$REPO_DIR"
  assert_failure
  assert_output --partial "wasn't installed by this script"
  run "$UPDATE" "$REPO_DIR" --force
  assert_success
  assert_line --partial "Agent hub: 0.9.0 →"
}

@test "refuses: not from the repository's root, not a hub copy, or the hub copy is this repository" {
  mkdir sub && cd sub
  run "$UPDATE" "$REPO_DIR"
  assert_failure
  assert_output --partial "from the repository's root"
  cd ..
  run "$UPDATE" "$BATS_TEST_TMPDIR"
  assert_failure
  assert_output --partial "isn't a copy of the agent hub"
  install
  run "$UPDATE" .
  assert_failure
  assert_output --partial "the hub copy is this repository"
  run "$UPDATE"
  assert_failure
  assert_output --partial "Usage:"
}

@test "VERSION is a version number and CHANGELOG.md's newest entry is for it" {
  assert_regex "$(cat "$HUB_DIR/VERSION")" '^[0-9]+\.[0-9]+\.[0-9]+$'
  run grep -m1 '^## ' "$HUB_DIR/CHANGELOG.md"
  assert_output --regexp "^## $(sed 's/\./\\./g' "$HUB_DIR/VERSION") — [0-9]{4}-[0-9]{2}-[0-9]{2}$"
}
