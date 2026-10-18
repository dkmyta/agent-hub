# Changes to the target branch

Each goes on the target branch (main) after the build's pull request
exists, to test how the build follows a target that moved: pushed straight
to a test repository's main, or — in the hub's own repository, whose main is
protected — as a small pull request a person merges (reverted together
after the journey). One per journey step.

| Fixture | Change | Expected from the next build run |
|---|---|---|
| [no-overlap.md](no-overlap.md) | A file the pull request doesn't touch | Mechanical drift: merged in, verified, no full review |
| [overlap.md](overlap.md) | A file the pull request changes, different lines | Semantic drift: merged in, the whole change reviewed again |
| [conflict.md](conflict.md) | The same README line the build changes | A conflict: nothing pushed, the file listed, a person resolves it |
