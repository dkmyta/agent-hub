# Changes to the target branch

Each is pushed straight to the **test repository's** main branch (never the
hub's), after the build's pull request exists, to test how the build
follows a target that moved. One per journey step; reset between them if
needed.

| Fixture | Change | Expected from the next build run |
|---|---|---|
| [no-overlap.md](no-overlap.md) | A file the pull request doesn't touch | Mechanical drift: merged in, verified, no full review |
| [overlap.md](overlap.md) | A file the pull request changes, different lines | Semantic drift: merged in, the whole change reviewed again |
| [conflict.md](conflict.md) | The same README line the build changes | A conflict: nothing pushed, the file listed, a person resolves it |
