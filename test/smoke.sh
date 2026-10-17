#!/bin/bash
# The checks are eval'd strings, so single-quoted expansions and "unused" variables are intended.
# shellcheck disable=SC2016,SC2034
# Fast test that runs anywhere bash runs: no root, no Docker, no Omarchy.
# Uses a fake $HOME and a fake $OMARCHY_PATH with one shipped config file.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin=$here/../bin/omaforecast
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Never touch the real state: drop every override that could point there.
unset "${!OMAFORECAST_@}" OMARCHY_MIGRATION_STATE
export HOME=$t/home OMARCHY_PATH=$t/omarchy NO_COLOR=1 XDG_STATE_HOME='' XDG_CACHE_HOME='' XDG_CONFIG_HOME=''
mkdir -p "$HOME/.config/hypr" "$OMARCHY_PATH/config/hypr" "$HOME/.config/omarchy/extensions"
echo 'o.bind("SUPER + J", "Joplin", "joplin")' >"$HOME/.config/hypr/bindings.lua"
echo '-- stock' >"$OMARCHY_PATH/config/hypr/bindings.lua"
echo '-- mine' >"$HOME/.config/hypr/monitors.lua"
printf '{\n  "personal": {"label":"Personal"}\n}\n' >"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

check "help prints usage" '"$bin" help | grep -q "omaforecast 0"'
id=$("$bin" snapshot before --quiet)
check "snapshot returns an id" '[[ $id == *-before ]]'
check "snapshot holds the tracked files" '[[ -f $HOME/.local/state/omaforecast/snapshots/$id/files/.config/hypr/bindings.lua ]]'

echo 'broken' >"$HOME/.config/hypr/bindings.lua"
rm "$HOME/.config/hypr/monitors.lua"
echo 'new' >"$HOME/.config/hypr/extra.lua"
check "diff lists the modified file" '"$bin" diff "$id" --stat | grep -q "modified  ~/.config/hypr/bindings.lua"'
check "diff lists the deleted file" '"$bin" diff "$id" --stat | grep -q "deleted   ~/.config/hypr/monitors.lua"'
check "dry run changes nothing" '"$bin" restore "$id" --dry-run >/dev/null && grep -q broken "$HOME/.config/hypr/bindings.lua"'

"$bin" restore "$id" ~/.config/hypr/monitors.lua --yes >/dev/null
check "single-file restore" '[[ -f $HOME/.config/hypr/monitors.lua ]] && grep -q broken "$HOME/.config/hypr/bindings.lua"'
"$bin" restore "$id" --yes >/dev/null
check "full restore" 'grep -q Joplin "$HOME/.config/hypr/bindings.lua"'
check "restore keeps files added since" '[[ -f $HOME/.config/hypr/extra.lua ]]'
"$bin" restore "$id" --delete --yes >/dev/null
check "restore --delete removes them" '[[ ! -e $HOME/.config/hypr/extra.lua ]]'
check "restore left an undo snapshot" '"$bin" list | grep -q pre-restore'

mkdir -p "$t/dots/hypr"; mv "$HOME/.config/hypr/bindings.lua" "$t/dots/hypr/bindings.lua"
ln -s "$t/dots/hypr/bindings.lua" "$HOME/.config/hypr/bindings.lua"
id2=$("$bin" snapshot linked --quiet)
echo 'changed' >"$t/dots/hypr/bindings.lua"
"$bin" restore "$id2" --yes >/dev/null
check "restore writes through a stow symlink" '[[ -L $HOME/.config/hypr/bindings.lua ]] && grep -q Joplin "$t/dots/hypr/bindings.lua"'

# ---- regressions from code review (H1-H8) ----
S=$HOME/.local/state/omaforecast/snapshots
nsnaps() { "$bin" list | grep -c '^20'; }

# H1: a failed copy must not publish a snapshot.
mkdir -p "$t/badtar"
printf '#!/bin/bash\nfor a in "$@"; do [[ $a == -c* ]] && { /usr/bin/env -u PATH true; command -p tar "$@"; exit 2; }; done\nexec command -p tar "$@"\n' >"$t/badtar/tar"
sed -i 's#command -p tar#'"$(command -v tar)"'#g' "$t/badtar/tar"; chmod +x "$t/badtar/tar"
before=$(nsnaps)
PATH=$t/badtar:$PATH "$bin" snapshot broken --quiet >/dev/null 2>&1; rc=$?
check "H1 failed copy: snapshot fails loudly" '((rc != 0))'
check "H1 failed copy: nothing published or left behind" '[[ $(nsnaps) == "$before" ]] && ! ls -A "$S" | grep -q "^\.tmp"'
id3=$("$bin" snapshot good --quiet)
echo 'tampered' >"$S/$id3/files/.config/hypr/monitors.lua"
check "H1 damaged snapshot: restore refuses it" '! "$bin" restore "$id3" --yes >/dev/null 2>&1'
rm -rf "${S:?}/$id3"

if (($(id -u) != 0)); then
  mkdir -p "$HOME/.config/hypr/locked"; echo x >"$HOME/.config/hypr/locked/a.lua"; chmod 0300 "$HOME/.config/hypr/locked"
  before=$(nsnaps)
  "$bin" snapshot unlistable --quiet >/dev/null 2>&1; rc=$?
  check "H1 a directory that can't be listed fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
  chmod 0700 "$HOME/.config/hypr/locked"; rm -rf "$HOME/.config/hypr/locked"
fi

if (($(id -u) != 0)); then
  mkdir -p "$HOME/.config/omaforecast"; echo .config/newapp >"$HOME/.config/omaforecast/include"; chmod 000 "$HOME/.config/omaforecast/include"
  before=$(nsnaps)
  "$bin" snapshot noinclude --quiet >/dev/null 2>&1; rc=$?
  check "H1 an unreadable include list fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
  rm -rf "$HOME/.config/omaforecast"
fi

if (($(id -u) != 0)); then
  before=$(nsnaps); chmod 0600 "$HOME/.config"
  "$bin" snapshot noconfig --quiet >/dev/null 2>&1; rc=$?
  chmod 0700 "$HOME/.config"
  check "H1 an unsearchable ~/.config fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
fi

if (($(id -u) != 0)); then
  mkdir -p "$t/private/nvim"; echo x >"$t/private/nvim/init.lua"; ln -s "$t/private/nvim" "$HOME/.config/nvim"
  chmod 0600 "$t/private"; before=$(nsnaps)
  "$bin" snapshot hiddenlink --quiet >/dev/null 2>&1; rc=$?
  check "H1 a symlink into an unsearchable directory fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
  mkdir -p "$HOME/.config/omaforecast"; rm -f "$HOME/.config/nvim"; ln -s "$t/private/include" "$HOME/.config/omaforecast/include"
  "$bin" snapshot hiddeninclude --quiet >/dev/null 2>&1; rc=$?
  check "H1 an include list behind an unsearchable directory fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
  chmod 0700 "$t/private"; rm -rf "$HOME/.config/omaforecast" "$t/private"
fi

if (($(id -u) != 0)); then
  mkdir -p "$t/private2"; mv "$HOME/.config" "$t/private2/config"; ln -s "$t/private2/config" "$HOME/.config"
  before=$(nsnaps); chmod 0600 "$t/private2"
  "$bin" snapshot hiddenconfig --quiet >/dev/null 2>&1; rc=$?
  chmod 0700 "$t/private2"; rm "$HOME/.config"; mv "$t/private2/config" "$HOME/.config"
  check "H1 a symlinked ~/.config behind an unsearchable directory fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'
fi

mkdir -p "$HOME/.config/omaforecast/include"; before=$(nsnaps)
"$bin" snapshot badinclude --quiet >/dev/null 2>&1; rc=$?
rm -rf "$HOME/.config/omaforecast"
check "H1 an include list that can't be read fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]]'

# H2: --delete never removes files the snapshot didn't see.
mkdir -p "$HOME/.config/newapp"; echo 'old file' >"$HOME/.config/newapp/app.conf"
if (($(id -u) != 0)); then echo 'secret' >"$HOME/.config/hypr/private.lua"; chmod 000 "$HOME/.config/hypr/private.lua"; fi
id4=$("$bin" snapshot scope --quiet 2>/dev/null)
mkdir -p "$HOME/.config/omaforecast"; echo '.config/newapp' >"$HOME/.config/omaforecast/include"
[[ -e $HOME/.config/hypr/private.lua ]] && chmod 600 "$HOME/.config/hypr/private.lua"
echo 'really new' >"$HOME/.config/hypr/brand-new.lua"
"$bin" restore "$id4" --delete --yes >/dev/null 2>&1
check "H2 file outside the snapshot's scope is kept" '[[ -f $HOME/.config/newapp/app.conf ]]'
if (($(id -u) != 0)); then check "H2 file unreadable at snapshot time is kept" '[[ -f $HOME/.config/hypr/private.lua ]]'; fi
check "H2 file proven new is removed" '[[ ! -e $HOME/.config/hypr/brand-new.lua ]]'
rm -rf "$HOME/.config/newapp" "$HOME/.config/omaforecast" "$HOME/.config/hypr/private.lua"

# H3: the undo snapshot covers out-of-scope files the restore overwrites.
echo '[user] name = old' >"$HOME/.gitconfig"; echo .gitconfig >"$t/extra"
id5=$(OF_EXTRA_FILES=$t/extra "$bin" snapshot extra --quiet)
echo '[user] name = current' >"$HOME/.gitconfig"
out=$("$bin" restore "$id5" ~/.gitconfig --yes 2>&1)
undo=$(grep -oE '[0-9]{8}-[0-9]{6}-pre-restore[-0-9]*' <<<"$out" | head -1)
check "H3 restore put the out-of-scope file back" 'grep -q old "$HOME/.gitconfig"'
check "H3 undo snapshot holds its current version" '[[ -n $undo ]] && grep -q current "$S/$undo/files/.gitconfig"'
"$bin" restore "$undo" ~/.gitconfig --yes >/dev/null 2>&1
check "H3 undo brings it back" 'grep -q current "$HOME/.gitconfig"'
rm -f "$HOME/.gitconfig"

# H4: a ~/.config/nvim that became a symlink to a dotfiles repo.
mkdir -p "$HOME/.config/nvim/lua"; echo 'old init' >"$HOME/.config/nvim/init.lua"
id6=$("$bin" snapshot nvim --quiet)
rm -rf "$HOME/.config/nvim"; mkdir -p "$t/dotfiles/nvim/lua"
echo 'dotfiles init' >"$t/dotfiles/nvim/init.lua"; echo 'plugins' >"$t/dotfiles/nvim/lua/plugins.lua"
ln -s "$t/dotfiles/nvim" "$HOME/.config/nvim"
"$bin" restore "$id6" --delete --yes >/dev/null 2>&1
check "H4 restore --delete leaves the dotfiles repo alone" '[[ -f $t/dotfiles/nvim/lua/plugins.lua ]] && grep -q "dotfiles init" "$t/dotfiles/nvim/init.lua"'
check "H4 the new symlink is left in place" '[[ -L $HOME/.config/nvim ]]'
rm -f "$HOME/.config/nvim"
mkdir -p "$t/somedir"; rm -f "$HOME/.config/hypr/monitors.lua"; ln -s "$t/somedir" "$HOME/.config/hypr/monitors.lua"
"$bin" restore "$id6" ~/.config/hypr/monitors.lua --yes >/dev/null 2>&1
check "H4 never writes into a directory a new link points to" '[[ -z $(ls -A "$t/somedir") ]]'
rm -f "$HOME/.config/hypr/monitors.lua"; "$bin" restore "$id6" ~/.config/hypr/monitors.lua --yes >/dev/null 2>&1

# H4: a link further down the chain retargeted after the snapshot.
mkdir -p "$t/dotA/nvim" "$t/unrelated" "$t/chain"; echo 'A init' >"$t/dotA/nvim/init.lua"; echo 'UNRELATED' >"$t/unrelated/init.lua"
ln -s "$t/dotA/nvim" "$t/chain/nvim"; ln -s "$t/chain/nvim" "$HOME/.config/nvim"
id7=$("$bin" snapshot chain --quiet)
rm "$t/chain/nvim"; ln -s "$t/unrelated" "$t/chain/nvim"
"$bin" restore "$id7" --yes >/dev/null 2>&1
check "H4 never writes through a retargeted link chain" 'grep -qx UNRELATED "$t/unrelated/init.lua"'
rm -f "$HOME/.config/nvim"

# H5: a migration that swaps a directory for a link to ~/.ssh can't leak it.
w=$t/sim; mkdir -p "$w/state.0/.config/probe" "$w/state.1/.config" "$t/fake-ssh"
echo 'harmless' >"$w/state.0/.config/probe/id_rsa"; echo 'PRIVATE KEY' >"$t/fake-ssh/id_rsa"
ln -s "$t/fake-ssh" "$w/state.1/.config/probe"
printf '%s\n' .config/probe/id_rsa >"$w/l.old"; printf '%s\n' .config/probe >"$w/l.new"
leak=$(OMAFORECAST_SOURCED=1 bash -c '. "$1"; sim_changes "$2/state.0" "$2/l.old" "$2/state.1" "$2/l.new"
  show_diff_into "$2" 1 x.sh .config/probe/id_rsa; show_diff_into "$2" 1 x.sh .config/probe' _ "$bin" "$w")
check "H5 symlinked directory is not followed when diffing" '! grep -q "PRIVATE KEY" <<<"$leak" && grep -q "^D	.config/probe/id_rsa" <<<"$leak"'

# New: a migration file name can't inject commands on the host.
mkdir -p "$t/evtree/migrations" "$t/cwd"
printf 'echo "Write pwn"\nmkdir -p "$HOME/.config/hypr"; echo hi > "$HOME/.config/hypr/pwn.conf"\n' >"$t/evtree/migrations/x#;e touch PWNED;#.sh"
(cd "$t/cwd" && "$bin" check --offline --no-snapshot --from "$t/evtree" >"$t/ev.out" 2>&1)
check "migration names with shell or sed syntax are skipped, not run" '[[ ! -e $t/cwd/PWNED && ! -e $HOME/PWNED ]] && grep -q "unexpected file name" "$t/ev.out"'

# An exclude list that can't be read stops omaforecast instead of being ignored.
if (($(id -u) != 0)); then
  mkdir -p "$HOME/.config/omaforecast"; echo .config/hypr/secret >"$HOME/.config/omaforecast/exclude"; chmod 000 "$HOME/.config/omaforecast/exclude"
  "$bin" snapshot noexclude --quiet >/dev/null 2>&1; rc=$?
  check "an unreadable exclude list stops omaforecast" '((rc != 0))'
  rm -rf "$HOME/.config/omaforecast"
fi
# An exclude list behind a folder that can't be searched also stops it.
if (($(id -u) != 0)); then
  mkdir -p "$HOME/.config/omaforecast"; echo .config/hypr/secret >"$HOME/.config/omaforecast/exclude"; chmod 000 "$HOME/.config/omaforecast"
  "$bin" snapshot noexclude2 --quiet >/dev/null 2>&1; rc=$?
  chmod 700 "$HOME/.config/omaforecast"
  check "an exclude list in an unsearchable folder stops omaforecast" '((rc != 0))'
  rm -rf "$HOME/.config/omaforecast"
fi
# An incoming tree whose bin/ links outside it is refused.
mkdir -p "$t/linktree/migrations" "$t/fake-ssh2"; echo key >"$t/fake-ssh2/omarchy-prod"; ln -s "$t/fake-ssh2" "$t/linktree/bin"
echo 'echo "x"' >"$t/linktree/migrations/1700000001.sh"
"$bin" check --offline --no-snapshot --from "$t/linktree" >"$t/lt.out" 2>&1; rc=$?
check "an incoming tree with bin/ linking outside it is refused" '((rc != 0)) && grep -q "links outside itself" "$t/lt.out"'

# H6: state, snapshots, and forecast output are private.
mkdir -p "$t/tree/migrations"; echo 'echo "Touch kitty"' >"$t/tree/migrations/1700000000.sh"
OMAFORECAST_NO_SANDBOX=1 "$bin" check --offline --no-snapshot --from "$t/tree" >/dev/null 2>&1
check "H6 state dir is 700" '[[ $(stat -c %a "$HOME/.local/state/omaforecast") == 700 ]]'
check "H6 snapshot dirs are private" '[[ $(stat -c %a "$S/$id6") == 700 ]]'
check "H6 forecast diff is 600" '[[ $(stat -c %a "$HOME/.local/state/omaforecast/last-forecast.diff") == 600 ]]'
check "H6 saved files keep their own mode" '[[ $(stat -c %a "$S/$id6/files/.config/hypr/bindings.lua") == 644 ]] || [[ $(stat -c %a "$S/$id6/files/.config/hypr/bindings.lua") == $(stat -c %a "$t/dots/hypr/bindings.lua") ]]'

# H7: a bad or missing signature stops the forecast.
echo 'package' >"$t/pkg.tar"; echo 'not a signature' >"$t/pkg.tar.sig"
sig() { OMAFORECAST_SOURCED=1 OMAFORECAST_GNUPG_HOME=$t/nognupg bash -c '. "$1"; ALLOW_UNSIGNED=${2:-0}; verify_pkg "$3/cached.tar" "file://$3/pkg.tar" omarchy && echo "OK: $PKG_SIG"' _ "$bin" "$1" "$t" 2>&1; }
cp "$t/pkg.tar" "$t/cached.tar"
check "H7 bad signature aborts" '! sig 0 | grep -q "^OK"'
check "H7 --allow-unsigned overrides" 'sig 1 | grep -q "^OK"'
rm -f "$t/pkg.tar.sig"
command -v pacman-conf >/dev/null || check "H7 missing signature aborts when signatures are required" '! sig 0 | grep -q "^OK"'

# H8: piped install never runs a bin/omaforecast from the current directory.
mkdir -p "$t/evil/bin"; printf '#!/bin/bash\necho EVIL-RAN\n' >"$t/evil/bin/omaforecast"; chmod +x "$t/evil/bin/omaforecast"
out=$(cd "$t/evil" && HOME=$t/evilhome OMAFORECAST_REPO=omaforecast-invalid/none timeout 30 bash <"$here/../install.sh" 2>&1)
check "H8 piped installer ignores ./bin/omaforecast" '! grep -q EVIL-RAN <<<"$out" && [[ ! -e $t/evilhome/.local/bin/omaforecast ]]'

"$bin" setup --no-hook >/dev/null
check "setup adds menu rows" 'grep -q update.forecast "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"'
"$bin" setup >/dev/null
check "setup is idempotent" '[[ $(grep -c ">>> omaforecast" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc") == 1 ]]'
check "post-update hook installed" '[[ -x $HOME/.config/omarchy/hooks/post-update.d/50-omaforecast ]]'
if command -v python3 >/dev/null; then
  check "menu JSONC parses like Omarchy parses it" 'python3 -c "
import re,json,sys
s=open(sys.argv[1]).read()
s=re.sub(r\"^\\s*//[^\\n]*(\\n|\$)\",\"\",s,flags=re.M); s=re.sub(r\",(\\s*[}\\]])\",r\"\\1\",s)
d=json.loads(s); assert \"update.forecast\" in d and \"personal\" in d" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"'
fi
cp "$bin" "$t/omaforecast-copy"
"$t/omaforecast-copy" uninstall >/dev/null
check "uninstall removes menu rows and hook" '! grep -q omaforecast "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" && [[ ! -e $HOME/.config/omarchy/hooks/post-update.d/50-omaforecast ]]'
check "uninstall keeps the user's own menu rows" 'grep -q personal "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"'
check "uninstall leaves the repo script alone" '[[ -x $bin ]]'

echo
((fails == 0)) && echo "smoke: all passed" || echo "smoke: $fails failed"
((fails == 0))
