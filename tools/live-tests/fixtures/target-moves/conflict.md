# Target moves: a conflict

Replaces the README's whole `src/text.js` list item (three lines), which
the reverse-words build also changes, so merging the target into the pull
request conflicts.

```sh
git switch main && git pull
perl -0pi -e 's/^- `src\/text\.js` — text helpers:.*?(?=^- `src\/cli\.js`)/- `src\/text.js` — the text helpers (live test: changed on the target branch)\n/ms' playground/README.md
git diff    # one list item replaced, nothing else
git commit -am "Live test: reword the helper list" && git push
```
