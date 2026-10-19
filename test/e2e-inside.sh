#!/bin/bash
# Runs inside the archlinux container. See run-e2e.sh.
set -uo pipefail
FX=/work/fixtures
PASS=0 FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }
as_dev() { runuser -u dev -- env -C /home/dev HOME=/home/dev USER=dev OMARCHY_PATH=/usr/share/omarchy PATH=/home/dev/.local/bin:/usr/local/bin:/usr/bin bash -c "$*"; }

step "Install tools"
pacman -Q bubblewrap git jq python >/dev/null || pacman -Sy --noconfirm --needed base-devel bubblewrap git jq pacman-contrib sudo python gum >/tmp/pacman.log 2>&1 || { tail -20 /tmp/pacman.log; exit 1; }

step "Build fake Omarchy packages v1 (4.0.3) and v2 (4.0.4) from real Omarchy source"
useradd -m builder
mkdir -p /repo /build && chown builder /repo /build
for v in v1:4.0.3 v2:4.0.4; do
  name=${v%%:*} ver=${v#*:}
  mkdir -p /build/$name
  cat >/build/$name/PKGBUILD <<PKG
pkgname=omarchy
pkgver=$ver
pkgrel=1
pkgdesc="Omarchy test fixture ($name)"
arch=(any)
license=(MIT)
options=(!strip !debug)
package() {
  cp -a $FX/$name/. "\$pkgdir/"
  # Demo pacing only: slow v2 migrations inside the dry-run sandbox.
  if [[ "$name" == v2 && "${MODE:-}" == demo ]]; then
    local migration pacing='[[ -z \${OMAFORECAST_SIM:-} ]] || sleep 1.2  # demo pacing: real migrations take seconds'
    for migration in "\$pkgdir"/usr/share/omarchy/migrations/*.sh; do
      if [[ \$(head -c 2 "\$migration") == '#!' ]]; then
        sed -i "1a \$pacing" "\$migration"
      else
        sed -i "1i \$pacing" "\$migration"
      fi
    done
  fi
}
PKG
  chown -R builder /build/$name
  runuser -u builder -- bash -c "cd /build/$name && PKGEXT=.pkg.tar makepkg -f >/tmp/makepkg-$name.log 2>&1" || { tail /tmp/makepkg-$name.log; exit 1; }
done
cp /build/v1/omarchy-4.0.3-1-any.pkg.tar /repo/
runuser -u builder -- repo-add -q /repo/omarchy.db.tar.gz /repo/omarchy-4.0.3-1-any.pkg.tar
sed -i '/^\[core\]/i [omarchy]\nSigLevel = Optional TrustAll\nServer = file:///repo\n' /etc/pacman.conf
pacman -Sy --noconfirm omarchy >/dev/null && ok "installed omarchy 4.0.3"

step "Create user (gets Omarchy's /etc/skel) and customize their config"
useradd -m -G wheel dev
# The forecast needs an unprivileged user namespace. Say so plainly if the host blocks it.
if ! as_dev 'bwrap --ro-bind / / --unshare-all --die-with-parent true' 2>/work/bwrap-preflight.txt; then
  echo "bubblewrap can't create a sandbox in this container: $(head -1 /work/bwrap-preflight.txt)" >&2
  echo "On Ubuntu 24.04 hosts run: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" >&2
  exit 2
fi
echo 'dev ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/dev
install -Dm755 /omaforecast/bin/omaforecast /home/dev/.local/bin/omaforecast
chown -R dev:dev /home/dev/.local
echo 'export PATH=$HOME/.local/bin:$PATH' >>/home/dev/.bashrc
as_dev '
  set -e
  # 1. a personal keybinding (no migration touches this; must stay untouched)
  echo "o.bind(\"SUPER + SHIFT + J\", \"Joplin\", \"joplin-desktop\")" >> ~/.config/hypr/bindings.lua
  # 2. kitty remote control turned on (a real migration comments this out)
  printf "\n# my scripts drive kitty\nallow_remote_control yes\n" >> ~/.config/kitty/kitty.conf
  # 3. a reworked bar: clock pinned with workspaces either side (real migrations rewrite this layout)
  jq ".bar.layout.center = [\"omarchy.workspaces\", \"omarchy.clock\", \"omarchy.tray\"] | .bar.centerAnchor = \"omarchy.clock\"" ~/.config/omarchy/shell.json > /tmp/s && cat /tmp/s > ~/.config/omarchy/shell.json
  # 4. a user menu file with an entry of their own
  cat > ~/.config/omarchy/extensions/omarchy-menu.jsonc <<J
{
  // mine
  "personal": {"icon":"x","label":"Personal"},
  "personal.notes": {"icon":"y","label":"Notes","action":"nvim ~/notes"}
}
J
'
# 5. nvim config kept in a dotfiles repo and stowed into place
as_dev '
  set -e
  mkdir -p ~/dotfiles/nvim/lua
  if [[ -d ~/.config/nvim && ! -L ~/.config/nvim ]]; then cp -a ~/.config/nvim/. ~/dotfiles/nvim/; rm -rf ~/.config/nvim; fi
  echo "vim.o.number = true" >> ~/dotfiles/nvim/init.lua
  ln -s ~/dotfiles/nvim ~/.config/nvim
'
# A hand edit inside the package (should be reported as overwritten by the update)
echo "# local hack" >> /usr/share/omarchy/default/hypr/bindings/tiling.lua 2>/dev/null || echo "# local hack" >> "$(ls /usr/share/omarchy/default/hypr/*.lua | head -1)"
as_dev 'cp -a ~/.config /tmp/config-before-update'

step "omaforecast setup (hook + menu + pacman hook)"
as_dev 'omaforecast setup --pacman-hook' && ok "setup ran"
[[ -x /home/dev/.config/omarchy/hooks/post-update.d/50-omaforecast ]] && ok "post-update hook installed" || bad "hook missing"
[[ -f /etc/pacman.d/hooks/90-omaforecast-snapshot.hook ]] && ok "pacman hook installed" || bad "pacman hook missing"
python3 - <<'PY' && ok "menu JSONC still parses the way Omarchy parses it" || bad "menu JSONC broken"
import re, json
raw = open('/home/dev/.config/omarchy/extensions/omarchy-menu.jsonc').read()
s = re.sub(r'^\s*//[^\n]*(\n|$)', '', raw, flags=re.M)
s = re.sub(r',(\s*[}\]])', r'\1', s)
d = json.loads(s)
assert 'update.forecast' in d and 'personal.notes' in d, d.keys()
PY

step "Publish v2 to the repo (the update is now available)"
cp /build/v2/omarchy-4.0.4-1-any.pkg.tar /repo/
runuser -u builder -- repo-add -q /repo/omarchy.db.tar.gz /repo/omarchy-4.0.4-1-any.pkg.tar

if [[ ${MODE:-} != demo ]]; then
  step "Package signatures"
  # A stand-in for pacman's keyring: one fully trusted packager key.
  export GNUPGHOME=/tmp/gnupg-test; rm -rf "$GNUPGHOME"; mkdir -m700 "$GNUPGHOME"
  gpg --batch -q --pinentry-mode loopback --passphrase '' --quick-gen-key 'packager <packager@example.invalid>' ed25519 sign never 2>/dev/null
  chmod 755 "$GNUPGHOME"; chmod 644 "$GNUPGHOME"/pubring.* "$GNUPGHOME"/trustdb.gpg
  K='OMAFORECAST_GNUPG_HOME=/tmp/gnupg-test'
  pkg=/repo/omarchy-4.0.4-1-any.pkg.tar
  echo 'not a signature' >"$pkg.sig"
  as_dev "$K omaforecast check --no-snapshot" >/work/sig-bad.txt 2>&1; rc=$?
  ((rc != 0)) && grep -q 'does not verify' /work/sig-bad.txt && ! grep -q 'Pending migrations' /work/sig-bad.txt && ok "bad signature stops the forecast before any migration runs" || { cat /work/sig-bad.txt; bad "bad signature accepted"; }
  as_dev "$K omaforecast check --no-snapshot --allow-unsigned" >/work/sig-allow.txt 2>&1
  grep -q 'BAD signature, used anyway' /work/sig-allow.txt && grep -q 'Pending migrations' /work/sig-allow.txt && ok "--allow-unsigned overrides it" || bad "--allow-unsigned"
  gpg --batch -q --yes --detach-sign -o "$pkg.sig" "$pkg"
  as_dev "$K omaforecast check --no-snapshot" >/work/sig-good.txt 2>&1
  grep -q 'signature verified' /work/sig-good.txt && ok "good signature verified" || { cat /work/sig-good.txt; bad "good signature not verified"; }
  # A key that is in the keyring but that nobody vouched for.
  G2=/tmp/gnupg-other; rm -rf $G2; mkdir -m700 $G2
  GNUPGHOME=$G2 gpg --batch -q --pinentry-mode loopback --passphrase '' --quick-gen-key 'stranger <x@example.invalid>' ed25519 sign never 2>/dev/null
  GNUPGHOME=$G2 gpg --batch -q --export | gpg --batch -q --import 2>/dev/null
  chmod 644 "$GNUPGHOME"/pubring.* "$GNUPGHOME"/trustdb.gpg
  GNUPGHOME=$G2 gpg --batch -q --yes --detach-sign -o "$pkg.sig" "$pkg"
  sed -i '/^\[omarchy\]/,/^Server/ s/^SigLevel = .*/SigLevel = PackageRequired PackageTrustedOnly DatabaseOptional/' /etc/pacman.conf
  as_dev "$K omaforecast check --no-snapshot" >/work/sig-untrusted.txt 2>&1; rc=$?
  ((rc != 0)) && grep -q "doesn't trust" /work/sig-untrusted.txt && ok "signature from an untrusted key stops the forecast" || { cat /work/sig-untrusted.txt; bad "untrusted key accepted"; }
  # The trusted key, revoked: rejected even when the repo says TrustAll.
  sed -i '/^\[omarchy\]/,/^Server/ s/^SigLevel = .*/SigLevel = PackageRequired PackageTrustAll DatabaseOptional/' /etc/pacman.conf
  gpg --batch -q --yes --detach-sign -o "$pkg.sig" "$pkg"
  sed 's/^:-----/-----/' "$GNUPGHOME"/openpgp-revocs.d/*.rev | gpg --batch -q --import 2>/dev/null
  chmod 644 "$GNUPGHOME"/pubring.* "$GNUPGHOME"/trustdb.gpg
  as_dev "$K omaforecast check --no-snapshot" >/work/sig-revoked.txt 2>&1; rc=$?
  ((rc != 0)) && grep -q 'does not verify' /work/sig-revoked.txt && ok "signature from a revoked key stops the forecast" || { cat /work/sig-revoked.txt; bad "revoked key accepted"; }
  rm -f "$pkg.sig"
  sed -i '/^\[omarchy\]/,/^Server/ s/^SigLevel = .*/SigLevel = PackageRequired DatabaseOptional/' /etc/pacman.conf
  as_dev 'omaforecast check --no-snapshot' >/work/sig-required.txt 2>&1; rc=$?
  ((rc != 0)) && grep -q 'requires signed packages' /work/sig-required.txt && ok "unsigned package stops the forecast when pacman.conf requires signatures" || { cat /work/sig-required.txt; bad "SigLevel Required ignored"; }
  sed -i '/^\[omarchy\]/,/^Server/ s/^SigLevel = .*/SigLevel = Optional TrustAll/' /etc/pacman.conf
  unset GNUPGHOME
fi

if [[ ${MODE:-} == demo ]]; then
  step "Record demo"
  pacman -S --noconfirm --needed asciinema ttf-dejavu >/dev/null 2>&1
  runuser -u dev -- env -C /home/dev HOME=/home/dev USER=dev OMARCHY_PATH=/usr/share/omarchy \
    asciinema rec --headless --overwrite --window-size 104x46 --idle-time-limit 6 -c /omaforecast/test/demo-session.sh /tmp/omaforecast.cast
  cp /tmp/omaforecast.cast /work/omaforecast.cast
  exit $?
fi

step "omaforecast check (the forecast)"
as_dev 'COLUMNS=100 omaforecast check' | tee /work/forecast.txt
as_dev 'diff=$(find ~/.local/state/omaforecast/reports -maxdepth 1 -type f -name "omarchy_update_details_*_UTC*.diff" -printf "%T@ %p\n" | sort -rn | head -1 | cut -d" " -f2-); cat -- "$diff"' > /work/forecast.diff
grep -q 'omarchy 4.0.3-1 → 4.0.4-1' /work/forecast.txt && ok "found incoming release from the repo" || bad "incoming release not found"
grep -q 'Pending migrations: .*6' /work/forecast.txt && ok "6 pending migrations" || bad "pending count"
grep -q 'kitty/kitty.conf.*customized' /work/forecast.txt && ok "warns: kitty.conf (customized) will change" || bad "kitty warning"
grep -q 'omarchy/shell.json.*customized' /work/forecast.txt && ok "warns: shell.json (customized) will change" || bad "shell.json warning"
grep -q 'bindings.lua' /work/forecast.txt && bad "bindings.lua wrongly flagged" || ok "bindings.lua not flagged"
grep -q 'Package files you edited' /work/forecast.txt && ok "reports hand-edited package file" || bad "package edit not reported"
as_dev 'ls ~/.local/state/omaforecast/snapshots' | grep -q pre-update && ok "pre-update snapshot taken" || bad "no snapshot"
# Nothing real changed during the forecast:
as_dev 'diff -r /tmp/config-before-update ~/.config -x omarchy-menu.jsonc -x 50-omaforecast' >/dev/null && ok "forecast changed nothing on disk" || bad "forecast modified real config"
pacman -Q omarchy | grep -q 4.0.3 && ok "system packages untouched by forecast" || bad "package changed"

st=/home/dev/.local/state/omaforecast
forecast_diff=$(find "$st/reports" -maxdepth 1 -type f -name 'omarchy_update_details_*_UTC*.diff' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
[[ $(stat -c %a $st) == 700 && $(stat -c %a $st/snapshots) == 700 && $(stat -c %a "$forecast_diff") == 600 ]] && ! find $st/sim-logs -perm /077 | grep -q . && ok "state, snapshots, diffs and logs are private" || { ls -la $st $st/sim-logs; bad "state permissions"; }

step "Hostile migration file name (sandboxed dry run)"
mkdir -p /tmp/evtree/migrations /tmp/evcwd && chmod 777 /tmp/evcwd
printf 'echo "Write pwn"\nmkdir -p "$HOME/.config/hypr"; echo hi > "$HOME/.config/hypr/pwn.conf"\n' >'/tmp/evtree/migrations/x#;e touch PWNED;#.sh'
chmod -R a+rX /tmp/evtree
as_dev 'cd /tmp/evcwd && omaforecast check --offline --no-snapshot --from /tmp/evtree' >/work/hostile.txt 2>&1
[[ ! -e /tmp/evcwd/PWNED && ! -e /home/dev/PWNED ]] && grep -q 'unexpected file name' /work/hostile.txt && ok "migration name can't run commands on the host" || { cat /work/hostile.txt; bad "hostile migration name"; }

step "A migration can't pull private files into the sandbox"
mkdir -p /tmp/leaktree/migrations
printf 'echo "Leak a key"\n# $HOME/.config/hypr\nmkdir -p "$HOME/.config/hypr"\ncat "$HOME/.ssh/id_rsa" > "$HOME/.config/hypr/leaked-key" || true\ncat "$HOME/.config/hypr/secrets.env" >> "$HOME/.config/hypr/leaked-key" || true\ncat /tmp/of/newbin/omarchy-leak >> "$HOME/.config/hypr/leaked-key" || true\ncat /srv/dotfiles-test/secret.env >> "$HOME/.config/hypr/leaked-key" || true\ncat /opt/dotfiles-test/secret.env /var/lib/dotfiles-test/secret.env "$HOME/.local/state/omarchy/toggles/secret.env" >> "$HOME/.config/hypr/leaked-key" || true\n' >/tmp/leaktree/migrations/1799999999.sh
# This one swaps the action log for a symlink to a file only the host can see.
printf 'echo "Swap the log"\nrm -f /tmp/of/log/actions.log\nln -s /home/dev/.netrc-test /tmp/of/log/actions.log\n' >/tmp/leaktree/migrations/1799999998.sh
mkdir -p /var/lib/dotfiles-test && echo OUTSIDE-HOME-SECRET >/var/lib/dotfiles-test/secret.env && chmod -R a+rX /var/lib/dotfiles-test
mkdir -p /srv/dotfiles-test && echo OUTSIDE-HOME-SECRET >/srv/dotfiles-test/secret.env && chmod -R a+rX /srv/dotfiles-test
mkdir -p /opt/dotfiles-test && echo OUTSIDE-HOME-SECRET >/opt/dotfiles-test/secret.env && chmod -R a+rX /opt/dotfiles-test
mkdir -p /tmp/leaktree/bin && ln -sfn /home/dev/.ssh/id_rsa /tmp/leaktree/bin/omarchy-leak
chmod -R a+rX /tmp/leaktree
as_dev 'mkdir -p -m700 ~/.ssh && echo SECRET-KEY-MATERIAL > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa'
as_dev 'printf "1799999998\\tNETRC-SECRET\\n1799999999\\tNETRC-SECRET\\n" > ~/.netrc-test && chmod 600 ~/.netrc-test'
as_dev 'echo EXCLUDED-SECRET > ~/.config/hypr/secrets.env && mkdir -p ~/.config/omaforecast ~/.local/state/omarchy/toggles && echo EXCLUDED-SECRET > ~/.local/state/omarchy/toggles/secret.env && printf "%s\n" .config/hypr/secrets.env .local/state/omarchy/toggles/secret.env > ~/.config/omaforecast/exclude'
as_dev 'omaforecast check --offline --no-snapshot --diff --from /tmp/leaktree' >/work/leak.txt 2>&1
as_dev 'diff=$(find ~/.local/state/omaforecast/reports -maxdepth 1 -type f -name "omarchy_update_details_*_UTC*.diff" -printf "%T@ %p\n" | sort -rn | head -1 | cut -d" " -f2-); cat -- "$diff"; cat ~/.local/state/omaforecast/sim-logs/* 2>/dev/null' >>/work/leak.txt
grep -q 'Leak a key' /work/leak.txt && ! grep -qE 'SECRET-KEY-MATERIAL|EXCLUDED-SECRET|OUTSIDE-HOME-SECRET|NETRC-SECRET' /work/leak.txt && ok "private keys, excluded files and files outside home never reach the sandbox" || { cat /work/leak.txt; bad "private file reached the forecast"; }
as_dev 'rm -rf ~/.netrc-test ~/.ssh ~/.config/omaforecast ~/.config/hypr/secrets.env ~/.local/state/omarchy/toggles/secret.env'

step "Static fallback without bubblewrap"
rc=0; as_dev 'OMAFORECAST_NO_SANDBOX=1 omaforecast check --offline --no-snapshot --from /work/fixtures/v2' >/work/static.txt 2>&1 || rc=$?
grep -q 'mentions ~/.config/kitty/kitty.conf' /work/static.txt && ok "static mode names kitty.conf" || bad "static mode"
((rc == 5)) && grep -q 'No forecast' /work/static.txt && ! grep -q 'leaves your config alone' /work/static.txt && ok "no sandbox: exit 5 and no forecast claimed" || bad "no sandbox must fail loudly (rc=$rc)"

cp -r /home/dev/.local/state/omaforecast/sim-logs /work/ 2>/dev/null
# Predicted set of changed user files (excluding Omarchy state)
grep -oE 'would (modify|create|delete) ~/[^ ]+' /work/forecast.txt | awk '{print $3}' | sort -u >/work/predicted.txt
grep -q 'keeps a backup at ~/.config/kitty/kitty.conf.bak' /work/forecast.txt && ok "notes the .bak the kitty migration writes" || bad "bak note missing"
grep -q "2 file(s) you changed would be rewritten" /work/forecast.txt && ok "summary counts 2 distinct customized files" || bad "summary count"

step "Run the real update: pacman -Syu + omarchy-migrate + post-update hook"
sleep 1
pacman -Syu --noconfirm 2>&1 | tee /work/pacman-update.log | grep -E 'omaforecast|upgrading omarchy' || true
grep -q 'omaforecast: snapshotting' /work/pacman-update.log && ok "pacman hook ran before the upgrade" || bad "pacman hook did not run"
as_dev 'omarchy-migrate' >/work/migrate.log 2>&1; echo "omarchy-migrate exit: $?" | tee -a /work/migrate.log
as_dev 'omarchy-hook post-update' | tee /work/report.txt

# Actual changed set: diff the pre-update snapshot against now
# shellcheck disable=SC2088  # matching the literal ~/ in the output
as_dev 'omaforecast diff pre-update --stat' | grep -oE '~/[^ ]+' | sort -u >/work/actual.txt
echo "predicted:"; cat /work/predicted.txt; echo "actual:"; cat /work/actual.txt
if diff -u /work/predicted.txt /work/actual.txt; then ok "forecast matched what the update actually changed"
else bad "forecast differed from the real update (see diff above)"; fi
grep -q '^allow_remote_control yes' /home/dev/.config/kitty/kitty.conf && bad "update did not change kitty.conf?" || ok "update did rewrite kitty.conf (as forecast)"

step "omaforecast restore (one command rollback)"
# A plugin added to the dotfiles repo after the snapshot, seen through the stowed link
as_dev 'echo "return {}" > ~/dotfiles/nvim/lua/new-plugin.lua'
as_dev 'omaforecast restore --delete --yes' | tee /work/restore.txt
[[ -f /home/dev/dotfiles/nvim/lua/new-plugin.lua && -L /home/dev/.config/nvim ]] && grep -q 'vim.o.number' /home/dev/dotfiles/nvim/init.lua && ok "restore --delete never deletes through the stowed nvim link" || bad "restore --delete deleted a dotfile"
grep -q 'never deletes through a symlink' /work/restore.txt && ok "and says why it kept it" || bad "no reason given for keeping the dotfile"
rm -f /home/dev/dotfiles/nvim/lua/new-plugin.lua
as_dev 'diff -r /tmp/config-before-update ~/.config -x omarchy-menu.jsonc -x 50-omaforecast -x "*.bak.*"' && ok "config is byte-identical to before the update" || bad "restore incomplete"
grep -q '^allow_remote_control yes' /home/dev/.config/kitty/kitty.conf && ok "kitty setting back" || bad "kitty not restored"

step "Undo the restore"
undo=$(grep -oE 'restore [0-9]{8}-[0-9]{6}-pre-restore[-0-9]*' /work/restore.txt | awk '{print $2}')
as_dev "omaforecast restore $undo --yes" >/dev/null && ! grep -q '^allow_remote_control yes' /home/dev/.config/kitty/kitty.conf && ok "restore is undoable" || bad "undo failed"

step "Single-file restore"
as_dev 'omaforecast restore pre-update ~/.config/kitty/kitty.conf --yes' >/dev/null
grep -q '^allow_remote_control yes' /home/dev/.config/kitty/kitty.conf && ok "single file restored" || bad "single file"
as_dev 'omaforecast diff pre-update --stat' | grep -q kitty && bad "kitty still differs" || ok "only that file changed back"

step "Uninstall"
as_dev 'omaforecast uninstall --purge' && [[ ! -e /home/dev/.config/omarchy/hooks/post-update.d/50-omaforecast ]] && ! grep -q omaforecast /home/dev/.config/omarchy/extensions/omarchy-menu.jsonc && [[ ! -e /etc/pacman.d/hooks/90-omaforecast-snapshot.hook ]] && grep -q personal.notes /home/dev/.config/omarchy/extensions/omarchy-menu.jsonc && ok "uninstall clean, user menu entries kept" || bad "uninstall"

echo; echo "RESULT: $PASS passed, $FAIL failed"
((FAIL == 0))
