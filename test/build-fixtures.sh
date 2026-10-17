#!/bin/bash
# build-fixtures.sh OMARCHY_SRC OUT
# Lays out package trees for a v1 (older) and v2 (current) Omarchy release.
set -euo pipefail
umask 022
src=$1 out=$2
mkdir -p "$out"

# Migrations held back from v1, so v2 brings them in: real ones that touch
# user config (kitty remote control, two shell.json bar-layout rewrites),
# plus three that run helpers, install packages, or need sudo.
HELD=(1788745941 1791968925 1791969355 1792020559 1792041364 1792202836)

# The shell.json Omarchy shipped before the bar-layout migrations.
anchor_commit=$(git -C "$src" log --format=%h -1 -- migrations/1791969355.sh)
git -C "$src" show "$anchor_commit^:config/omarchy/shell.json" >"$out/shell.json.old"

mk_tree() { # mk_tree NAME HOLD(0/1)
  local t=$out/$1 m
  rm -rf "$t"; mkdir -p "$t/usr/share/omarchy" "$t/usr/bin" "$t/etc/skel/.config" "$t/etc/skel/.local/state/omarchy/migrations" "$t/etc/profile.d"
  cp -a "$src"/{config,migrations,default,themes,version} "$t/usr/share/omarchy/"
  cp -a "$src"/bin/omarchy* "$t/usr/bin/"
  cp -a "$src"/config/. "$t/etc/skel/.config/"
  if [[ $2 == 1 ]]; then
    for m in "${HELD[@]}"; do rm -f "$t/usr/share/omarchy/migrations/$m.sh"; done
    cp "$out/shell.json.old" "$t/usr/share/omarchy/config/omarchy/shell.json"
    cp "$out/shell.json.old" "$t/etc/skel/.config/omarchy/shell.json"
  fi
  for m in "$t"/usr/share/omarchy/migrations/*.sh; do touch "$t/etc/skel/.local/state/omarchy/migrations/${m##*/}"; done
  echo 'export OMARCHY_PATH=/usr/share/omarchy' >"$t/etc/profile.d/omarchy.sh"
}
mk_tree v1 1
mk_tree v2 0
printf '%s\n' "${HELD[@]}" >"$out/held.txt"
chmod -R u=rwX,go=rX "$out/v1" "$out/v2"
echo "fixtures in $out"
