# shellcheck shell=bash
# A fix pass that changes one line of src/greet.js — small on its own.
sed -i.bak 's/: "Hello!";/: "Hello, you!";/' src/greet.js && rm -f src/greet.js.bak
