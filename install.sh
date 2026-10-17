#!/bin/bash
# omaforecast installer: puts the single script in ~/.local/bin and runs setup.
#   curl -fsSL https://raw.githubusercontent.com/w-mir1/omaforecast/main/install.sh | bash
# Extra setup flags pass through:  ... | bash -s -- --pacman-hook
set -euo pipefail
REPO=${OMAFORECAST_REPO:-w-mir1/omaforecast}
REF=${OMAFORECAST_REF:-main}
dest=$HOME/.local/bin/omaforecast
mkdir -p "$(dirname "$dest")"

# Use a local bin/omaforecast only when this installer was run as a real file
# from a checkout (bash install.sh). Piped through curl, it reads from stdin,
# and then it always downloads: never run whatever is in the current directory.
src=${BASH_SOURCE[0]:-}
here=""
if [[ -n $src && $src != /dev/* && $src != /proc/* && -f $src ]]; then
  here=$(cd "$(dirname "$src")" && pwd -P)
fi
if [[ -n $here && -f $here/bin/omaforecast ]]; then
  install -m755 "$here/bin/omaforecast" "$dest"
else
  tmp=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/bin/omaforecast" -o "$tmp"
  bash -n "$tmp"
  install -m755 "$tmp" "$dest"; rm -f "$tmp"
fi
echo "Installed $dest"

command -v bwrap >/dev/null || echo "Tip: install bubblewrap for full dry runs: sudo pacman -S bubblewrap"
"$dest" setup "$@"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH to run 'omaforecast'." ;; esac
echo
echo "Next: omaforecast check"
