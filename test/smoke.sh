#!/bin/bash
# The checks are eval'd strings, so single-quoted expansions and "unused" variables are intended.
# shellcheck disable=SC2016,SC2034
# Fast test that runs anywhere bash runs: no root, no Docker, no Omarchy.
# Uses a fake $HOME and a fake $OMARCHY_PATH with one shipped config file.
set -u
# Prefer a full UTF-8 locale: C.UTF-8 alone may hide collation/range bugs.
smoke_locale=$(locale -a 2>/dev/null | LC_ALL=C grep -iEx 'en_US\.utf-?8' | head -1)
[[ -n $smoke_locale ]] || smoke_locale=$(locale -a 2>/dev/null | LC_ALL=C grep -iEx 'C\.utf-?8' | head -1)
if [[ -n $smoke_locale ]]; then
  export LANG=$smoke_locale
  unset LC_ALL LC_CTYPE LC_COLLATE
fi
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

# Block HTTP for the entire suite; self-update fixtures use file:// only.
mkdir -p "$t/tools"
real_curl=$(command -v curl)
cat >"$t/tools/curl" <<'CURL'
#!/bin/bash
for arg in "$@"; do
  case $arg in http://* | https://*) exit 22 ;; esac
done
exec "$SMOKE_REAL_CURL" "$@"
CURL
chmod +x "$t/tools/curl"
export SMOKE_REAL_CURL=$real_curl PATH=$t/tools:$PATH OMAFORECAST_NO_UPDATE_CHECK=1

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

check "help prints usage" '"$bin" help | grep -q "omaforecast 0"'
check "version is 0.2.0" '[[ $("$bin" --version) == "omaforecast 0.2.0" ]]'
check "released changelog starts at 0.2.0" '[[ $(sed -n "/^## \[/{p;q;}" "$here/../CHANGELOG.md") == "## [0.2.0]"* ]]'
# ---- self-update and asynchronous notices (file:// fixtures only) ----
update_home=$t/update-home
OF_CACHE=$update_home/.cache/omaforecast
installed=$t/installed/omaforecast
fixture=$t/raw/fixture/main/bin/omaforecast
mkdir -p "${installed%/*}" "${fixture%/*}" "$update_home"
cp "$bin" "$installed"
update_fixture() { sed "s/^VERSION=.*/VERSION=$1/" "$bin" >"$fixture"; }
update_run() {
  env -u OMAFORECAST_NO_UPDATE_CHECK -u CI HOME="$update_home" \
    OMAFORECAST_RAW_BASE="file://$t/raw" OMAFORECAST_REPO=fixture \
    OMAFORECAST_UPDATE_CHECK_FORCE_TTY=1 "$@"
}
# Each poll has a five-second deadline, including when a regression stops the fetch.
poll_file() {
  local deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    [[ -f $1 ]] && grep -qxF -- "$2" "$1" && return 0
    sleep 0.05
  done
  return 1
}
notice_is() {
  printf 'omaforecast %s is available (you have 0.2.0). Run: omaforecast self-update\n' "$1" >"$t/notice.expected"
  cmp -s "$t/notice.expected" "$t/notice.err" && ! grep -q 'is available' "$t/notice.out"
}
no_notice() {
  ! grep -q 'is available' "$t/notice.err" &&
    ! grep -q 'is available.*Run: omaforecast self-update' "$t/notice.out"
}
update_fixture 0.2.1
if (($(id -u) != 0)); then
  update_run "$installed" help >"$t/notice.out" 2>"$t/notice.err"; rc=$?
  check "update notice: empty cache prints no notice" '((rc == 0)) && [[ ! -s $t/notice.err ]] && no_notice'
  check "update notice: first help fetches the fixture in the background" 'poll_file "$OF_CACHE/latest-version" 0.2.1'
  update_run "$installed" help >"$t/notice.out" 2>"$t/notice.err"; rc=$?
  check "update notice: second help prints exactly one stderr line, none on stdout" '((rc == 0)) && notice_is 0.2.1'

  update_fixture 0.2.2
  cache_mtime=$(stat -c %y "$OF_CACHE/latest-version")
  update_run "$installed" help >"$t/notice.out" 2>"$t/notice.err"
  sleep 1
  check "update notice: fresh cache keeps old version and mtime after one second" 'notice_is 0.2.1 && grep -qx 0.2.1 "$OF_CACHE/latest-version" && [[ $(stat -c %y "$OF_CACHE/latest-version") == "$cache_mtime" ]]'
  update_run env OMAFORECAST_UPDATE_CHECK_INTERVAL=0 "$installed" help >"$t/notice.out" 2>"$t/notice.err"
  check "update notice: interval zero still prints the previously cached version" 'notice_is 0.2.1'
  check "update notice: interval zero refreshes the cache" 'poll_file "$OF_CACHE/latest-version" 0.2.2'
  update_run "$installed" help >"$t/notice.out" 2>"$t/notice.err"
  check "update notice: next help prints the refreshed version" 'notice_is 0.2.2'

  # A stale cache makes accidental fetching observable even for silent commands.
  touch -d '@1' "$OF_CACHE/latest-version"
  cache_mtime=$(stat -c %y "$OF_CACHE/latest-version")
  update_run env OMAFORECAST_NO_UPDATE_CHECK=1 "$installed" help >"$t/notice.out" 2>"$t/notice.err"
  check "update notice: opt-out is silent" 'no_notice'
  update_run env CI=1 "$installed" help >"$t/notice.out" 2>"$t/notice.err"
  check "update notice: CI is silent" 'no_notice'
  mkdir -p "$t/notice-tree/migrations"
  update_run "$installed" check --offline --no-sim --no-snapshot --from "$t/notice-tree" >"$t/notice.out" 2>"$t/notice.err"; rc=$?
  check "update notice: offline is silent" '((rc == 0)) && no_notice'
  for silent in report quiet version setup self-check; do
    expected_rc=0
    case $silent in
      report) args=(report --hook) ;; quiet) args=(help --quiet) ;;
      version) args=(version) ;; setup) args=(setup) ;; self-check) args=(self-update --check); expected_rc=10 ;;
    esac
    update_run "$installed" "${args[@]}" >"$t/notice.out" 2>"$t/notice.err"; rc=$?
    check "update notice: $silent is silent" '((rc == expected_rc)) && no_notice'
  done
  check "update notice: suppressed commands leave stale cache untouched" 'grep -qx 0.2.2 "$OF_CACHE/latest-version" && [[ $(stat -c %y "$OF_CACHE/latest-version") == "$cache_mtime" ]]'
  update_run env -u OMAFORECAST_UPDATE_CHECK_FORCE_TTY "$installed" help >"$t/notice.out" 2>"$t/notice.err"; rc=$?
  sleep 1
  check "update notice: redirected stderr without FORCE_TTY is silent and spawns no fetch" '((rc == 0)) && no_notice && grep -qx 0.2.2 "$OF_CACHE/latest-version" && [[ $(stat -c %y "$OF_CACHE/latest-version") == "$cache_mtime" ]]'

  # HTTP is blocked above. A missing file URL plus a ten-second fake curl
  # exercises an unreachable source without any socket or real network access.
  mkdir -p "$t/slow-curl"
  cat >"$t/slow-curl/curl" <<'SLOW_CURL'
#!/bin/bash
printf '%s\n' "$@" >"$SMOKE_SLOW_ARGS"
printf '%s\n' "$$" >"$SMOKE_SLOW_PID"
exec sleep 10
SLOW_CURL
  chmod +x "$t/slow-curl/curl"
  started=$(date +%s%N)
  update_run env PATH="$t/slow-curl:$PATH" OMAFORECAST_RAW_BASE="file://$t/missing" \
    SMOKE_SLOW_ARGS="$t/slow.args" SMOKE_SLOW_PID="$t/slow.pid" \
    "$installed" help >"$t/notice.out" 2>"$t/notice.err"; rc=$?
  elapsed=$(( $(date +%s%N) - started ))
  check "update notice: unreachable slow curl leaves foreground help under two seconds" '((rc == 0 && elapsed < 2000000000)) && notice_is 0.2.2'
  # Confirm the slow fetch actually started; stop its sleep before fixture cleanup.
  slow_deadline=$((SECONDS + 5))
  while [[ ! -s $t/slow.pid ]] && ((SECONDS < slow_deadline)); do sleep 0.05; done
  slow_pid=$(cat "$t/slow.pid" 2>/dev/null) || slow_pid=''
  check "update notice: ten-second fetch is still running after help returns" '[[ -n $slow_pid ]] && kill -0 "$slow_pid" 2>/dev/null && grep -qxF "file://$t/missing/fixture/main/bin/omaforecast" "$t/slow.args"'
  [[ -z $slow_pid ]] || kill "$slow_pid" 2>/dev/null
else
  echo "skip update notice checks (notices disabled for root)"
  update_fixture 0.2.2
fi

# Self-update checks run against a disposable installed copy, never the checkout.
cp "$installed" "$t/installed.before"
update_run "$installed" self-update --check >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update check compares against 0.2.0 without replacement" '((rc == 10)) && grep -q "0.2.2 is available (you have 0.2.0)" "$t/update.out" && cmp -s "$t/installed.before" "$installed"'
update_run "$installed" update --self --check >"$t/update-alias.out" 2>"$t/update-alias.err"; rc=$?
check "self-update: update --self --check has identical output and exit 10" '((rc == 10)) && cmp -s "$t/update.out" "$t/update-alias.out" && cmp -s "$t/update.err" "$t/update-alias.err" && cmp -s "$t/installed.before" "$installed"'
update_run "$installed" setup >/dev/null
update_menu=$update_home/.config/omarchy/extensions/omarchy-menu.jsonc
update_hook=$update_home/.config/omarchy/hooks/post-update.d/50-omaforecast
check "self-update: hook and menu are present before updating" '[[ -x $update_hook ]] && grep -q ">>> omaforecast" "$update_menu"'
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update replaces installed copy and prints 0.2.0 → 0.2.2" '((rc == 0)) && [[ $("$installed" --version) == "omaforecast 0.2.2" ]] && grep -qF "0.2.0 → 0.2.2" "$t/update.out"'
check "self-update: hook and menu remain present" '[[ -x $update_hook ]] && grep -q ">>> omaforecast" "$update_menu"'
check "self-update: cache records installed version and update output has no notice" 'grep -qx 0.2.2 "$OF_CACHE/latest-version" && ! grep -q "is available" "$t/update.out" "$t/update.err"'
update_run "$installed" help >"$t/notice.out" 2>"$t/notice.err"
check "self-update: subsequent help has no notice" '[[ ! -s $t/notice.err ]] && no_notice'

# --no-menu does not remove an existing block; use setup's removal expression.
sed -i --follow-symlinks '/\/\/ >>> omaforecast/,/\/\/ <<< omaforecast/d' "$update_menu"
update_run "$installed" setup --no-menu >/dev/null
check "self-update: menu is absent before forced reinstall" '! grep -q ">>> omaforecast" "$update_menu" && [[ -x $update_hook ]]'
update_run "$installed" self-update --force --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: forced reinstall keeps menu absent and hook present" '((rc == 0)) && ! grep -q ">>> omaforecast" "$update_menu" && [[ -x $update_hook ]]'
update_run "$installed" setup --menu-update >/dev/null
check "self-update: update.omarchy row is present before updating" 'grep -q "\"update.omarchy\"" "$update_menu"'
update_fixture 0.2.3
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: update.omarchy row survives updating" '((rc == 0)) && grep -q "\"update.omarchy\"" "$update_menu" && [[ -x $update_hook ]]'

cp "$installed" "$t/installed.before"
update_fixture 0.1.9
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: downgrade refusal leaves installed bytes identical" '((rc != 0)) && grep -q "refusing to downgrade" "$t/update.err" && cmp -s "$t/installed.before" "$installed"'
update_run "$installed" self-update --force --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: --force installs an older fixture" '((rc == 0)) && [[ $("$installed" --version) == "omaforecast 0.1.9" ]] && cmp -s "$fixture" "$installed"'
cp "$installed" "$t/installed.before"
update_fixture 0.2.4
printf '\nif then\n' >>"$fixture"
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: syntax-error refusal leaves installed bytes identical" '((rc != 0)) && grep -q "invalid omaforecast download" "$t/update.err" && cmp -s "$t/installed.before" "$installed"'
sed '/^VERSION=/d' "$bin" >"$fixture"
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: missing-VERSION refusal leaves installed bytes identical" '((rc != 0)) && grep -q "missing or ambiguous VERSION" "$t/update.err" && cmp -s "$t/installed.before" "$installed"'
printf 'invalid download\n' >"$fixture"
update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update rejects invalid downloads without replacement" '((rc != 0)) && cmp -s "$t/installed.before" "$installed"'
update_fixture 0.2.4
if (($(id -u) != 0)); then
  chmod a-w "${installed%/*}"
  update_run "$installed" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
  chmod u+w "${installed%/*}"
  check "self-update: non-writable directory refusal leaves installed bytes identical" '((rc != 0)) && grep -q "can.t write" "$t/update.err" && cmp -s "$t/installed.before" "$installed"'
else
  echo "skip self-update non-writable directory check (root bypasses permissions)"
fi
cp "$bin" "$t/checkout.before"
update_run "$bin" self-update --yes >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: git checkout refusal leaves checkout bytes identical" '((rc != 0)) && grep -q "running from a git checkout" "$t/update.err" && cmp -s "$t/checkout.before" "$bin"'
update_run "$installed" self-update </dev/null >"$t/update.out" 2>"$t/update.err"; rc=$?
check "self-update: no --yes and no tty cancels without replacing installed bytes" '((rc != 0)) && grep -q "not a terminal; pass --yes" "$t/update.err" && grep -q "Self-update cancelled" "$t/update.out" && cmp -s "$t/installed.before" "$installed"'

id=$("$bin" snapshot before --quiet)
check "snapshot returns an id" '[[ $id == *-before ]]'
check "snapshot holds the tracked files" '[[ -f $HOME/.local/state/omaforecast/snapshots/$id/files/.config/hypr/bindings.lua ]]'

echo 'broken' >"$HOME/.config/hypr/bindings.lua"
rm "$HOME/.config/hypr/monitors.lua"
echo 'new' >"$HOME/.config/hypr/extra.lua"
check "diff lists the modified file" '"$bin" diff "$id" --stat | grep "modified  ~/.config/hypr/bindings.lua" >/dev/null'
check "diff lists the deleted file" '"$bin" diff "$id" --stat | grep "deleted   ~/.config/hypr/monitors.lua" >/dev/null'
check "dry run changes nothing" '"$bin" restore "$id" --dry-run >/dev/null && grep -q broken "$HOME/.config/hypr/bindings.lua"'

"$bin" restore "$id" ~/.config/hypr/monitors.lua --yes >/dev/null
check "single-file restore" '[[ -f $HOME/.config/hypr/monitors.lua ]] && grep -q broken "$HOME/.config/hypr/bindings.lua"'
"$bin" restore "$id" --yes >/dev/null
check "full restore" 'grep -q Joplin "$HOME/.config/hypr/bindings.lua"'
check "restore keeps files added since" '[[ -f $HOME/.config/hypr/extra.lua ]]'
"$bin" restore "$id" --delete --yes >/dev/null
check "restore --delete removes them" '[[ ! -e $HOME/.config/hypr/extra.lua ]]'
check "restore left an undo snapshot" '"$bin" list | grep pre-restore >/dev/null'

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

# A find failure while listing files counts, even if a later pass succeeds.
mkdir -p "$t/flakyfind" "$HOME/.config/hypr/sub"; echo keep >"$HOME/.config/hypr/sub/keep.conf"
cat >"$t/flakyfind/find" <<FIND
#!/bin/bash
for a in "\$@"; do
  if [[ \$a == .config/hypr && ! -e $t/flakyfind/once ]]; then
    : >"$t/flakyfind/once"; echo "find: '.config/hypr/sub': Permission denied" >&2; exit 1
  fi
done
exec $(command -v find) "\$@"
FIND
chmod +x "$t/flakyfind/find"; before=$(nsnaps)
PATH=$t/flakyfind:$PATH "$bin" snapshot flaky --quiet >"$t/flaky.out" 2>&1; rc=$?
check "H1 a find failure in the file listing fails the snapshot" '((rc != 0)) && [[ $(nsnaps) == "$before" ]] && grep -q "hypr/sub" "$t/flaky.out"'
rm -f "$t/flakyfind/once"; mkdir -p "$HOME/.config/omaforecast"; echo .config/hypr/sub >"$HOME/.config/omaforecast/exclude"
PATH=$t/flakyfind:$PATH "$bin" snapshot flaky2 --quiet >/dev/null 2>&1; rc=$?
check "H1 excluding the path that find couldn't list lets the snapshot succeed" '((rc == 0))'
rm -rf "$HOME/.config/omaforecast" "$HOME/.config/hypr/sub" "$t/flakyfind"

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
# The exclude-list check looks at the error, not at text in the path.
if (($(id -u) != 0)); then
  odd="$t/No such file or directory/locked"; mkdir -p "$odd" "$t/tree/migrations"; echo 'echo "Touch kitty"' >"$t/tree/migrations/1700000000.sh"; echo .config/hypr/secret >"$odd/exclude"; chmod 000 "$odd"
  OMAFORECAST_CONFIG=$odd "$bin" check --offline --no-snapshot --no-sim --from "$t/tree" >/dev/null 2>&1; rc=$?
  chmod 700 "$odd"
  check "an exclude list behind an odd, unsearchable path stops omaforecast" '((rc != 0))'
fi
# An unreadable folder that you excluded doesn't stop the snapshot.
if (($(id -u) != 0)); then
  mkdir -p "$HOME/.config/hypr/locked" "$HOME/.config/omaforecast"; echo x >"$HOME/.config/hypr/locked/f"; chmod 000 "$HOME/.config/hypr/locked"
  echo .config/hypr/locked >"$HOME/.config/omaforecast/exclude"
  "$bin" snapshot lockedok --quiet >"$t/lk.out" 2>&1; rc=$?
  chmod 700 "$HOME/.config/hypr/locked"; rm -rf "$HOME/.config/hypr/locked" "$HOME/.config/omaforecast"
  check "an excluded unreadable folder doesn't stop the snapshot" '((rc == 0))' || cat "$t/lk.out"
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

# A sandbox that can't be created is an error, never an empty forecast.
mkdir -p "$t/nobwrap"; printf '#!/bin/sh\necho "bwrap: No permissions to create new namespace" >&2\nexit 1\n' >"$t/nobwrap/bwrap"; chmod +x "$t/nobwrap/bwrap"
PATH=$t/nobwrap:$PATH "$bin" check --offline --no-snapshot --from "$t/tree" >"$t/nb.out" 2>&1; rc=$?
check "a sandbox that can't start fails the check (exit 5)" '((rc == 5))'
check "a sandbox that can't start says why and makes no forecast" 'grep -q "can.t create a sandbox" "$t/nb.out" && grep -q "No forecast" "$t/nb.out" && ! grep -qE "leaves your config alone|None of your customizations" "$t/nb.out"'
# A basic namespace probe can succeed even when mounting proc is forbidden.
mkdir -p "$t/noproc"
cat >"$t/noproc/bwrap" <<'BWRAP'
#!/bin/bash
for arg in "$@"; do
  if [[ $arg == --proc ]]; then
    echo "bwrap: Can't mount proc on /proc: Operation not permitted" >&2
    echo "second error line" >&2
    exit 1
  fi
done
exit 0
BWRAP
chmod +x "$t/noproc/bwrap"
check "fake bubblewrap accepts the old probe without proc" '"$t/noproc/bwrap" --ro-bind / / --unshare-all --die-with-parent true'
PATH=$t/noproc:$PATH "$bin" check --offline --no-snapshot --from "$t/tree" >"$t/noproc.out" 2>&1; rc=$?
check "proc mount failure fails the sandbox probe (exit 5) with the first error" '((rc == 5)) && grep -q "can.t create a sandbox.*bwrap: Can.t mount proc on /proc: Operation not permitted" "$t/noproc.out" && ! grep -q "second error line" "$t/noproc.out"'
OMAFORECAST_SIM_TIMEOUT=soon "$bin" check --offline --no-snapshot --from "$t/tree" >"$t/nb5.out" 2>&1; rc=$?
check "a bad dry-run timeout fails the check (exit 5)" '((rc == 5)) && grep -q "OMAFORECAST_SIM_TIMEOUT" "$t/nb5.out"'
OMAFORECAST_NO_SANDBOX=1 "$bin" check --offline --no-snapshot --from "$t/tree" >"$t/nb2.out" 2>&1; rc=$?
check "no bubblewrap also fails the check (exit 5)" '((rc == 5)) && grep -q "No forecast" "$t/nb2.out"'
PATH=$t/nobwrap:$PATH "$bin" check --offline --no-snapshot --no-sim --from "$t/tree" >"$t/nb3.out" 2>&1; rc=$?
check "--no-sim skips the dry run on purpose and says so" '((rc == 0)) && grep -q "Dry run skipped" "$t/nb3.out"'
rc=$(OMAFORECAST_SOURCED=1 bash -c '. "$1"; cmd_check() { return 5; }; omarchy-update() { echo RAN; }; cmd_update -y; echo "rc=$?"' _ "$bin" 2>&1)
check "update stops when the forecast fails" '[[ $rc == *rc=5* && $rc != *RAN* ]]'

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

# ---- short forecasts, reports and stderr progress (no network) ----
check "README names release 0.2.0" 'grep -q "0.2.0" "$here/../README.md"'
mkdir -p "$t/new/migrations" "$t/new/config/hypr" "$t/report-stock/config/hypr" "$t/report-home/.config/hypr" "$t/report-markers"
printf 'stock\n' >"$t/report-stock/config/hypr/bindings.lua"
printf 'stock\n' >"$t/report-stock/config/hypr/stock.lua"
printf 'mine\n' >"$t/report-home/.config/hypr/bindings.lua"
printf 'stock\n' >"$t/report-home/.config/hypr/stock.lua"
echo 4.0.0 >"$t/report-stock/version"
cp "$t/report-stock/config/hypr/stock.lua" "$t/new/config/hypr/stock.lua"
printf 'new default\n' >"$t/new/config/hypr/bindings.lua"
cat >"$t/new/migrations/1789325478.sh" <<'MIG'
echo 'Link routing'
cp "$HOME/.config/hypr/bindings.lua" "$HOME/.config/hypr/bindings.lua.bak.test"
sed -i 's/mine/updated/' "$HOME/.config/hypr/bindings.lua"
MIG
cat >"$t/new/migrations/1789325479.sh" <<'MIG'
echo 'Stock settings'
sed -i 's/stock/updated/' "$HOME/.config/hypr/stock.lua"
MIG
cat >"$t/new/migrations/1789325480.sh" <<'MIG'
echo 'Create settings'
echo created >"$HOME/.config/hypr/new.lua"
MIG
printf "echo 'No-op settings'\ntrue\n" >"$t/new/migrations/1789325481.sh"
printf "echo 'Neovim clipboard settings with a deliberately long description'\nexit 1\n" >"$t/new/migrations/1789325482.sh"
printf "echo 'Slow settings'\nsleep 3\n" >"$t/new/migrations/1789325483.sh"
cat >"$t/new/migrations/1789325484.sh" <<'MIG'
echo 'Package repo order'
sudo true
for n in 1 2 3 4 5 6 7 8; do systemctl "action$n"; done
systemctl 'literal ``` fence'
MIG

# Exercise the actual collector/renderers with deterministic simulation data.
# This never runs migration code outside the sandbox; it synthesizes its output.
cat >"$t/render-check" <<'RENDER'
#!/bin/bash
export OMAFORECAST_SOURCED=1
. "$SMOKE_BIN"
simulate() {
  local work=$1; shift
  progress_phase 'Preparing sandbox…'
  mkdir -p "$work/result" "$work/state.0/.config/hypr"
  cp "$HOME/.config/hypr/"* "$work/state.0/.config/hypr/"
  : >"$work/actions.log"
  local m i=0 rc started=$SECONDS
  for m in "$@"; do
    progress_migration "$i" "$#" "${m%.sh}" "$((SECONDS - started))"
    i=$((i + 1)); rc=0
    cp -a "$work/state.$((i - 1))" "$work/state.$i"
    : >"$work/result/$m.out"; : >"$work/result/$m.changes"
    case ${m%.sh} in
      1789325478)
        echo updated >"$work/state.$i/.config/hypr/bindings.lua"
        cp "$HOME/.config/hypr/bindings.lua" "$work/state.$i/.config/hypr/bindings.lua.bak.test"
        printf '%s\tM\t.config/hypr/bindings.lua\n%s\tA\t.config/hypr/bindings.lua.bak.test\n' "${m%.sh}" "${m%.sh}" >"$work/result/$m.changes" ;;
      1789325479)
        echo updated >"$work/state.$i/.config/hypr/stock.lua"
        printf '%s\tM\t.config/hypr/stock.lua\n' "${m%.sh}" >"$work/result/$m.changes" ;;
      1789325480)
        echo created >"$work/state.$i/.config/hypr/new.lua"
        printf '%s\tA\t.config/hypr/new.lua\n' "${m%.sh}" >"$work/result/$m.changes" ;;
      1789325482) rc=1 ;;
      1789325483) sleep 0.4 ;;
      1789325484)
        printf '%s\tsudo true\n' "${m%.sh}" >>"$work/actions.log"
        for n in 1 2 3 4 5 6 7 8; do printf '%s\tsystemctl action%s\n' "${m%.sh}" "$n" >>"$work/actions.log"; done
        printf '%s\tsystemctl literal ``` fence\033[31m\001\n' "${m%.sh}" >>"$work/actions.log" ;;
    esac
    if [[ ${SMOKE_FAIL_CUSTOM:-0} == 1 && $m == 1789325478.sh ]]; then rc=1; fi
    echo "$rc" >"$work/result/$m.rc"
  done
  SIM_OK=1
}
cmd_check "$@"
RENDER
chmod +x "$t/render-check"
export SMOKE_BIN=$bin SMOKE_NEW_TREE=$t/new
forecast() {
  local executable=$1; shift
  [[ $executable != "$bin" ]] || set -- check "$@"
  HOME=$t/report-home OMARCHY_PATH=$t/report-stock OMARCHY_MIGRATION_STATE=$t/report-markers \
    "$executable" "$@" --from "$t/new" --no-snapshot
}
state=$t/report-home/.local/state/omaforecast
reports=$state/reports
OMAFORECAST_NOW_UTC=261019_14_04 forecast "$t/render-check" >"$t/short.out" 2>"$t/short.err"; rc=$?
report=$reports/omarchy_update_details_261019_14_04_UTC.md
check "renderer produces the short count line" '((rc == 0)) && grep -q "7 migrations: 1 change your files · 1 stock · 1 create new files · 3 no changes · 1 dry run didn.t finish" "$t/short.out"'
check "short view lists customized, failed and sudo migrations only" 'grep -q "✗ 1789325478" "$t/short.out" && grep -q "? 1789325482" "$t/short.out" && grep -q "! 1789325484.*runs sudo" "$t/short.out" && ! grep -qE "1789325479|1789325480|1789325481|1789325483" "$t/short.out"'
check "short attention lines fit 110 columns" '(while IFS= read -r line; do [[ $line != "  "[✗?!]* ]] || ((${#line} <= 110)) || exit 1; done <"$t/short.out")'
check "short failure line truncates the description and keeps the full log suffix" 'grep -q "^  ? 1789325482  .*…: dry run exited 1 (log: ~/.local/state/omaforecast/sim-logs/1789325482.log)$" "$t/short.out"'
check "report and stable copy are identical regular files" '[[ -f $report && ! -L $state/last-forecast.md ]] && cmp -s "$report" "$state/last-forecast.md"'
check "report includes all migrations, summary and snapshot" '[[ $(grep -c "^### 178932" "$report") == 7 ]] && grep -q "^## Summary" "$report" && grep -q "^## Snapshot" "$report"'
check "report includes statuses, full actions, backups, defaults and diff" 'grep -q "Changes your files" "$report" && grep -q "Changes stock files" "$report" && grep -q "Creates new files" "$report" && grep -q "Dry run didn.t finish (exit 1)" "$report" && grep -q "systemctl action8" "$report" && grep -q "backup at" "$report" && grep -q "^## New defaults" "$report" && grep -q "Full diff:" "$report"'
check "report strips ANSI, controls and embedded backtick fences" '! LC_ALL=C grep -q "$(printf "\033")" "$report" && ! LC_ALL=C grep -q "$(printf "\001")" "$report" && ! grep -q "literal \`\`\`" "$report"'
check "reports and last copy have private modes" '[[ $(stat -c %a "$reports") == 700 && $(stat -c %a "$report") == 600 && $(stat -c %a "$state/last-forecast.md") == 600 ]]'
check "no forced progress on redirected stderr; stdout has no CR" '[[ ! -s $t/short.err ]] && ! grep -q "$(printf "\r")" "$t/short.out"'
OMAFORECAST_NOW_UTC=261019_14_04 forecast "$bin" --no-sim --quiet >"$t/quiet.out" 2>"$t/quiet.err"; rc=$?
check "same-minute reports get _2 without clobbering" '((rc == 0)) && [[ -f $reports/omarchy_update_details_261019_14_04_UTC_2.md ]] && grep -q "Changes your files" "$report"'
check "quiet writes a report with no terminal output" '[[ ! -s $t/quiet.out && ! -s $t/quiet.err ]] && grep -q "Not simulated" "$state/last-forecast.md"'
forecast "$t/render-check" --verbose --diff >"$t/verbose.out" 2>"$t/verbose.err"
check "verbose restores per-migration lines and --diff appends diffs" 'grep -q "✓ 1789325481" "$t/verbose.out" && grep -q "would modify ~/.config/hypr/stock.lua" "$t/verbose.out" && grep -q "^Diffs" "$t/verbose.out" && grep -q "^--- a/" "$t/verbose.out"'
for alias in --full -v; do
  forecast "$bin" --no-sim "$alias" >"$t/alias.out" 2>/dev/null
  check "check $alias shows full details" 'grep -q "? 1789325481" "$t/alias.out"'
done
OMAFORECAST_PROGRESS=1 forecast "$t/render-check" >"$t/progress.out" 2>"$t/progress.err"
check "forced progress includes phases, estimating and ETA on stderr" 'grep -q "Fetching incoming release" "$t/progress.err" && grep -q "Preparing sandbox" "$t/progress.err" && grep -q "Dry-running migration 1/7.*estimating…" "$t/progress.err" && grep -q "left" "$t/progress.err" && ! grep -q "$(printf "\r")" "$t/progress.out"'
check "ticker animates during a slow phase" '[[ $(grep -o "Dry-running migration 6/7" "$t/progress.err" | wc -l) -ge 2 ]]'
for option in --quiet --hook; do
  OMAFORECAST_PROGRESS=1 forecast "$bin" --no-sim "$option" >"$t/silent.out" 2>"$t/silent.err"
  check "$option suppresses forced progress" '[[ ! -s $t/silent.err ]]'
done
OMAFORECAST_PROGRESS=0 forecast "$t/render-check" >/dev/null 2>"$t/disabled.err"
check "progress override zero disables progress" '[[ ! -s $t/disabled.err ]]'
OMAFORECAST_PROGRESS=1 forecast "$bin" --no-sim >"$t/no-sim.out" 2>"$t/no-sim.err"
check "no-sim still shows fetching progress and saves full static mentions" 'grep -q "Fetching incoming release" "$t/no-sim.err" && grep -q "mentions ~/.config/hypr/bindings.lua" "$state/last-forecast.md"'

# Concurrent checks use the real --no-sim path and the exact same timestamp.
OMAFORECAST_NOW_UTC=261019_15_00 forecast "$bin" --no-sim --quiet & p1=$!
OMAFORECAST_NOW_UTC=261019_15_00 forecast "$bin" --no-sim --quiet & p2=$!
wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
check "concurrent checks atomically reserve two complete distinct reports" '((rc1 == 0 && rc2 == 0)) && [[ -f $reports/omarchy_update_details_261019_15_00_UTC.md && -f $reports/omarchy_update_details_261019_15_00_UTC_2.md ]] && grep -q "^## Summary" "$reports/omarchy_update_details_261019_15_00_UTC.md" && grep -q "^## Summary" "$reports/omarchy_update_details_261019_15_00_UTC_2.md"'
# Force a later filename clock after fetch: the check must retain start time.
HOME=$t/report-home OMARCHY_PATH=$t/report-stock OMAFORECAST_NOW_UTC=261019_15_01 OMAFORECAST_SOURCED=1 bash -c '
  . "$1"; fetch_incoming() { NEW_SHARE=$SMOKE_NEW_TREE; NEW_DESC=fixture; OMAFORECAST_NOW_UTC=261019_23_59; }; cmd_check --no-sim --no-snapshot --quiet
' _ "$bin" "$t/new"
check "filename retains the UTC time captured before fetch" '[[ -f $reports/omarchy_update_details_261019_15_01_UTC.md && ! -f $reports/omarchy_update_details_261019_23_59_UTC.md ]]'
: >"$reports/unrelated.md"
OMAFORECAST_KEEP_REPORTS=2 forecast "$bin" --no-sim --quiet
check "pruning retains only newest configured reports and leaves unrelated files" '[[ $(find "$reports" -name "omarchy_update_details_*_UTC*.md" | wc -l) == 2 && -f $reports/unrelated.md ]]'
mkdir -p "$t/empty/migrations"
HOME=$t/report-home OMARCHY_PATH=$t/report-stock "$bin" check --from "$t/empty" --no-snapshot >"$t/empty.out" 2>"$t/empty.err"
check "no pending migrations still creates a tiny complete report" 'grep -q "No pending migrations" "$t/empty.out" && grep -q "Pending migrations: 0" "$state/last-forecast.md" && grep -q "^## Summary" "$state/last-forecast.md"'

# Unit coverage of ETA formatting, ASCII fallback, and cleanup on termination.
OMAFORECAST_SOURCED=1 bash -c '
 . "$1"; printf "before\033[31mcafé\033[0m\001\033]title\007 after\n" | plain_text
' _ "$bin" >"$t/plain.out" 2>"$t/plain.err"; rc=$?
check "plain_text strips byte controls under the selected UTF-8 locale" '((rc == 0)) && [[ ! -s $t/plain.err && $(cat "$t/plain.out") == "beforecafé after" ]]'
OMAFORECAST_SOURCED=1 OMAFORECAST_PROGRESS=1 LC_ALL=C bash -c '
 . "$1"; progress_migration 2 4 test 0; progress_migration 2 4 test 45; progress_migration 2 4 test 61; progress_migration 2 4 test 3900; progress_stop
' _ "$bin" 2>"$t/eta.err"
check "ETA formats seconds, rounded minutes and hours; C locale uses ASCII" 'grep -q "~45s left" "$t/eta.err" && grep -q "~2m left" "$t/eta.err" && grep -q "~1h 5m left" "$t/eta.err" && grep -qF "| Dry-running" "$t/eta.err"'
check "sub-second migration averages show at least one second left" 'grep -q "~1s left" "$t/eta.err" && ! grep -q "~0s left" "$t/eta.err"'
OMAFORECAST_SOURCED=1 OMAFORECAST_PROGRESS=1 bash -c '
 . "$1"; progress_phase waiting; echo "$PROGRESS_PID" >"$2"; kill -TERM "$BASHPID"
' _ "$bin" "$t/ticker.pid" 2>"$t/term.err"; rc=$?
check "termination stops the ticker and clears its line" '((rc == 143)) && ! kill -0 "$(cat "$t/ticker.pid")" 2>/dev/null && [[ $(tail -c 5 "$t/term.err") == "$(printf "\r\033[2K")" ]]'

SMOKE_FAIL_CUSTOM=1 forecast "$t/render-check" >"$t/worst.out" 2>/dev/null
check "migration buckets use failure before customized-file changes" 'grep -q "7 migrations: 1 stock · 1 create new files · 3 no changes · 2 dry run didn.t finish" "$t/worst.out" && grep -q "? 1789325478.*dry run exited 1" "$t/worst.out"'
mkdir -p "$t/package-query"
cat >"$t/package-query/pacman" <<'PACMAN'
#!/bin/bash
case $1 in
  -Qq) [[ $2 == omarchy ]] ;;
  -Q) [[ $2 == omarchy ]] && echo 'omarchy 4.0.0' ;;
  -Qkk) echo 'warning: omarchy: /usr/share/omarchy/config/hypr/edited.lua (SHA256 checksum mismatch)' ;;
  *) exit 1 ;;
esac
PACMAN
chmod +x "$t/package-query/pacman"
PATH=$t/package-query:$PATH forecast "$bin" --no-sim >"$t/package.out" 2>/dev/null
check "package edit details are saved in the report and absent from short view" 'grep -q "^## Package edits" "$state/last-forecast.md" && grep -q "/usr/share/omarchy/config/hypr/edited.lua" "$state/last-forecast.md" && ! grep -q "edited.lua" "$t/package.out"'
forecast "$t/render-check" --exit-code --quiet >/dev/null 2>"$t/exitcode.err"; rc=$?
check "customized files preserve --exit-code 3 and still write report" '((rc == 3)) && grep -q "Changes your files" "$state/last-forecast.md"'
HOME=$t/report-home OMARCHY_PATH=$t/report-stock OMAFORECAST_PROGRESS=1 "$bin" check --from "$t/new" --no-sim >"$t/snapshot.out" 2>"$t/snapshot.err"; rc=$?
check "snapshot phase appears and the report includes id and restore hint" '((rc == 0)) && grep -q "Taking snapshot" "$t/snapshot.err" && grep -q "Snapshot saved: .*pre-update" "$state/last-forecast.md" && grep -q "omaforecast restore" "$state/last-forecast.md"'
HOME=$t/report-home OMARCHY_PATH=$t/report-stock PATH=$t/badtar:$PATH OMAFORECAST_PROGRESS=1 "$t/render-check" --from "$t/new" --exit-code >"$t/snapshot-fail.out" 2>"$t/snapshot-fail.err"; rc=$?
check "snapshot failure preserves exit 4 and still publishes report" '((rc == 4)) && grep -q "No snapshot was saved" "$state/last-forecast.md"'
check "snapshot errors appear after the progress line is cleared" 'grep -q "Taking snapshot" "$t/snapshot-fail.err" && grep -q "could not save snapshot" "$t/snapshot-fail.err" && ! grep -q "$(printf "\r")" "$t/snapshot-fail.out"'
OMAFORECAST_SOURCED=1 OMAFORECAST_PROGRESS=1 LC_ALL=C.UTF-8 bash -c '
 . "$1"; progress_phase waiting; echo "$PROGRESS_PID" >"$2"; kill -INT "$BASHPID"
' _ "$bin" "$t/int-ticker.pid" 2>"$t/int.err"; rc=$?
check "interrupt stops the braille ticker and clears its line" '((rc == 130)) && grep -q "⠋ waiting" "$t/int.err" && ! kill -0 "$(cat "$t/int-ticker.pid")" 2>/dev/null && [[ $(tail -c 5 "$t/int.err") == "$(printf "\r\033[2K")" ]]'
if command -v python3 >/dev/null; then
  SMOKE_HOME=$t/report-home SMOKE_STOCK=$t/report-stock SMOKE_TREE=$t/new python3 - <<'PYTTY'
import os, pty, subprocess
master, slave = pty.openpty()
env = dict(os.environ, HOME=os.environ['SMOKE_HOME'], OMARCHY_PATH=os.environ['SMOKE_STOCK'])
env.pop('OMAFORECAST_PROGRESS', None)
result = subprocess.run([env['SMOKE_BIN'], 'check', '--from', env['SMOKE_TREE'], '--no-sim', '--no-snapshot'],
                        stdout=subprocess.PIPE, stderr=slave, env=env, check=True)
os.close(slave)
data = b''
while True:
    try:
        part = os.read(master, 65536)
    except OSError:
        break
    if not part:
        break
    data += part
os.close(master)
assert b'Fetching incoming release' in data
assert b'\r' not in result.stdout
PYTTY
  rc=$?
  check "piped stdout still shows progress on terminal stderr" '((rc == 0))'
fi

# Run real migrations only inside functioning bubblewrap, never on the host.
if command -v bwrap >/dev/null && bwrap --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --unshare-all --die-with-parent true >/dev/null 2>&1; then
  OMAFORECAST_PROGRESS=1 forecast "$bin" >"$t/bwrap-short.out" 2>"$t/bwrap-progress.err"; rc=$?
  check "bwrap short summary classifies all seven migrations" '((rc == 0)) && grep -q "7 migrations: 1 change your files · 1 stock · 1 create new files · 3 no changes · 1 dry run didn.t finish" "$t/bwrap-short.out"'
  check "bwrap attention lines include only custom, failed and sudo migrations" 'grep -q "✗ 1789325478" "$t/bwrap-short.out" && grep -q "? 1789325482" "$t/bwrap-short.out" && grep -q "! 1789325484.*runs sudo" "$t/bwrap-short.out" && ! grep -qE "1789325479|1789325480|1789325481|1789325483" "$t/bwrap-short.out"'
  check "bwrap report contains every migration without escapes and latest copy matches" '[[ $(grep -c "^### 178932" "$state/last-forecast.md") == 7 ]] && ! grep -q "$(printf "\033")" "$state/last-forecast.md" && latest=$(sed -n "s/^ Full report: //p" "$t/bwrap-short.out") && cmp -s "$state/last-forecast.md" "$t/report-home/${latest#\~/}"'
  check "bwrap progress stays on stderr and includes estimating and ETA" 'grep -q "Dry-running migration 1/7.*estimating…" "$t/bwrap-progress.err" && grep -q "left" "$t/bwrap-progress.err" && ! grep -q "$(printf "\r")" "$t/bwrap-short.out"'
  forecast "$bin" --verbose >"$t/bwrap-verbose.out" 2>"$t/bwrap-no-progress.err"
  check "bwrap verbose prints no-op and stock details without redirected progress" 'grep -q "✓ 1789325481" "$t/bwrap-verbose.out" && grep -q "would modify ~/.config/hypr/stock.lua" "$t/bwrap-verbose.out" && ! grep -q "Dry-running" "$t/bwrap-no-progress.err"'
else
  echo "skip bwrap migration smoke checks (bubblewrap unavailable or namespaces blocked)"
fi
# Preserve review artifacts outside the disposable fixture only when requested.
if [[ -n ${SMOKE_ARTIFACTS:-} ]]; then
  mkdir -p "$SMOKE_ARTIFACTS"
  # Save actual renderer output with a real snapshot of the disposable home.
  HOME=$t/report-home OMARCHY_PATH=$t/report-stock OMARCHY_MIGRATION_STATE=$t/report-markers \
    OMAFORECAST_NOW_UTC=261019_14_04 "$t/render-check" --from "$t/new" >"$SMOKE_ARTIFACTS/short-summary.txt"
  cp "$state/last-forecast.md" "$SMOKE_ARTIFACTS/forecast.md"
fi

echo
((fails == 0)) && echo "smoke: all passed" || echo "smoke: $fails failed"
((fails == 0))
