#!/bin/bash
# Typed terminal session for the README demo. Runs as the test user inside
# the e2e container, after v2 has been published.
export PATH=$HOME/.local/bin:/usr/bin TERM=xterm-256color
prompt() { printf '\e[1;34m~\e[0m \e[1;32m❯\e[0m '; }
type_cmd() {
  prompt; local i
  for ((i = 0; i < ${#1}; i++)); do printf '%s' "${1:i:1}"; sleep 0.035; done
  sleep 0.5; echo
}
pause() { sleep "${1:-2.5}"; }

clear
type_cmd "omaforecast check"
script -qfec "omaforecast check" /dev/null
pause 6
clear
type_cmd "omarchy update        # simulated here: pacman -Syu, then migrations"
sudo pacman -Syu --noconfirm >/dev/null 2>&1
omarchy-migrate >/dev/null 2>&1
script -qfec "omarchy-hook post-update" /dev/null
pause 4
type_cmd "omaforecast restore --delete --yes"
script -qfec "omaforecast restore --delete --yes" /dev/null
pause 2
type_cmd "grep remote_control ~/.config/kitty/kitty.conf"
grep --color=always remote_control ~/.config/kitty/kitty.conf
pause 3
