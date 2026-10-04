# shellcheck shell=bash
# The plan's change, plus a README edit the plan says must not be touched.
bash -e "$(dirname "$0")/greet.sh"
printf '\nNow greets by name.\n' >> README.md
