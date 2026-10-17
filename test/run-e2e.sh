#!/bin/bash
# End-to-end test in a throwaway Arch Linux container.
#
# Builds two fake-but-real Omarchy packages from the actual omarchy source
# (v1 = an older state with the newest migrations held back, v2 = current),
# installs v1, customizes a user's config, publishes v2 to a local pacman repo,
# and checks that `omaforecast check` predicts exactly what the real update
# (pacman -Syu + omarchy-migrate + post-update hook) then does, and that
# `omaforecast restore` puts everything back.
#
# Usage: test/run-e2e.sh [path-to-omarchy-checkout]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
src=${1:-${OMARCHY_SRC:-}}
work=${WORK:-$root/.work/e2e}
mkdir -p "$work"; rm -rf "$work"/fixtures "$work"/*.txt

if [[ -z $src && -d $work/omarchy-src ]]; then src=$work/omarchy-src; fi
# Pinned so the held-back migrations in build-fixtures.sh keep existing.
OMARCHY_REF=${OMARCHY_REF:-cce8b1c971df64a7610b818ff8819e4bea04584a}
if [[ -z $src ]]; then
  src=$work/omarchy-src
  git init -q "$src"
  git -C "$src" fetch -q --depth 100 https://github.com/basecamp/omarchy.git "$OMARCHY_REF"
  git -C "$src" checkout -q FETCH_HEAD
fi
"$here/build-fixtures.sh" "$src" "$work/fixtures"

docker image inspect omaforecast-test >/dev/null 2>&1 || docker build -q -t omaforecast-test "$here"

docker run --rm --privileged \
  -v "$root:/omaforecast:ro" -v "$work:/work" \
  -e TERM=xterm-256color \
  omaforecast-test bash /omaforecast/test/e2e-inside.sh 2>&1 | tee "$work/e2e.log"
exit "${PIPESTATUS[0]}"
