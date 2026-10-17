#!/bin/bash
# Records demo/omaforecast.cast and renders demo/omaforecast.gif.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
work=${WORK:-$root/.work/e2e}
mkdir -p "$root/assets"
src=$work/omarchy-src
[[ -d $src ]] || { git init -q "$src"; git -C "$src" fetch -q --depth 100 https://github.com/basecamp/omarchy.git "${OMARCHY_REF:-cce8b1c971df64a7610b818ff8819e4bea04584a}"; git -C "$src" checkout -q FETCH_HEAD; }
"$here/build-fixtures.sh" "$src" "$work/fixtures"
docker image inspect omaforecast-test >/dev/null 2>&1 || docker build -q -t omaforecast-test "$here"
docker run --rm --privileged -e MODE=demo -v "$root:/omaforecast:ro" -v "$work:/work" omaforecast-test bash /omaforecast/test/e2e-inside.sh
cp "$work/omaforecast.cast" "$root/assets/omaforecast.cast"
agg=${AGG:-$work/agg}
if [[ ! -x $agg ]]; then
  curl -fsSL -o "$agg" https://github.com/asciinema/agg/releases/latest/download/agg-x86_64-unknown-linux-gnu
  chmod +x "$agg"
fi
"$agg" --font-size 15 --theme monokai --speed 1.2 "$root/assets/omaforecast.cast" "$root/assets/omaforecast.gif"
ls -la "$root/assets"
