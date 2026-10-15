# Target moves: overlap without a conflict

Changes `playground/src/text.js`, which the reverse-words build also
changes, but only `slugify`'s comment, far from the new function.

```sh
git switch main && git pull
perl -pi -e 's|/\*\* "Hello, World!" → "hello-world" \*/|/** "Hello, World!" → "hello-world" (lower case, dashes between words) */|' playground/src/text.js
git diff    # one comment line changed, nothing else
git commit -am "Live test: clarify slugify's comment" && git push
```
