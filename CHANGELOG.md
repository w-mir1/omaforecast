# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-19

### Added

- `check` now prints a short migration summary and attention lines, with complete private Markdown reports in `reports/omarchy_update_details_<YYMMDD>_<HH>_<MM>_UTC.md` and an atomic `last-forecast.md` copy. Names use the check's start time in UTC, reserve collision suffixes atomically, and retain the newest 20 reports (`OMAFORECAST_KEEP_REPORTS`). `--verbose`, `--full`, and `-v` restore full terminal details; `--quiet` still saves a report.
- Animated progress on stderr covers fetching, sandbox preparation, migrations with an ETA, and snapshots. `OMAFORECAST_PROGRESS=0` disables it and `=1` forces it for scripts or tests.
- `self-update` (also `upgrade` and `update --self`) validates and atomically updates omaforecast, with check-only, force and yes options, while preserving hook and menu choices.
- Interactive commands show an update-available notice from a daily cache refreshed in the background. `OMAFORECAST_NO_UPDATE_CHECK=1` disables it.

### Fixed

- Report rendering no longer fails under UTF-8 locales such as `en_US.UTF-8` (GNU sed rejected the byte ranges used to strip terminal escapes; they now run with `LC_ALL=C`).
- The sandbox self-test now uses the same `/proc`, `/dev` and `/tmp` mounts as the real dry runs, so a host where bubblewrap can't mount `/proc` gets a clear "can't create a sandbox" error (exit 5) instead of every migration showing as "dry run didn't finish".
- `check` now falls back to the newest `omacom/omarchy` release tag (or the `quattro` branch tip if no tag resolves) when git and package lookup find no incoming release. It identifies the source version, reports failed package database syncs, and respects `--offline`.
- Installed version detection now checks the edge and settings packages and ignores development placeholder version files.

## [0.1.1] - 2026-10-18

### Fixed

- `check` no longer prints an empty forecast when bubblewrap is missing or can't create a sandbox (for example when the system blocks user namespaces). It says why, exits with code 5, and `omaforecast update` stops. `--no-sim` still skips the dry run on purpose.
- A folder that `find` couldn't list while building the file list now stops the snapshot, even when a later pass could list it, so a snapshot can't be published with files silently missing.
- Excluding an unreadable folder now lets the snapshot go ahead, as documented. Before, `find`'s error messages in a non-English locale weren't recognized, and the symlink pass failed on the folder regardless.
- The exclude-list check now reads the error reason only, so a config path that happens to contain words such as "No such file or directory" can't make an unsearchable exclude list look absent.
- The sandbox no longer sees all of `/var/lib`, only pacman's database in `/var/lib/pacman`.
- A migration can no longer replace the dry run's action log with a symlink to make omaforecast print one of your files in the report.

### Changed

- CI allows unprivileged user namespaces on the Ubuntu runner so the end-to-end test can create its sandbox, and the end-to-end test now stops early with a clear message when it can't.

## [0.1.0] - 2026-10-17

First release.

### Added

- `omaforecast check` finds the Omarchy release the next update would install and dry-runs each pending migration against a copy of your config in a bubblewrap sandbox. It lists the files each migration would change, marks the ones you customized, and saves the diffs.
- The check also reports package files you edited by hand and new upstream defaults for files you customized.
- A static fallback lists the files each migration names when bubblewrap isn't available.
- `omaforecast snapshot`, `list`, `diff`, and `restore` work on plain-directory snapshots of your Omarchy config. A restore saves a snapshot first, so it can be undone.
- `omaforecast report` shows what an update changed, plus new `.bak` and `.pacnew` files. It runs from Omarchy's post-update hook.
- `omaforecast update` runs the check, asks before continuing if your customized files are affected, then runs `omarchy update`.
- `omaforecast setup` installs the post-update hook and two menu rows. `--pacman-hook` adds a pacman hook that snapshots before every Omarchy upgrade.
- `omaforecast uninstall` removes everything setup added.
- Snapshots are published only after every file is copied, compared with the original, and checksummed. `restore` refuses damaged snapshots, saves a pre-restore copy of every file it will change, and replaces files atomically.
- `restore --delete` removes only files the snapshot proves were absent. `restore` never writes through a new or retargeted symlink and never deletes through one.
- A package with a bad signature, a signature from a key pacman wouldn't trust, or no signature when `pacman.conf` requires one, stops `check` before any migration runs. Migration files with unexpected names are skipped. `--allow-unsigned` overrides this.
- State, snapshots, forecast diffs, and logs are private to your user.
- A snapshot fails, and nothing is pruned, when a tracked folder, a symlink's target, or the include list can't be read.
- The dry run copies only your tracked, non-excluded config (plus shell and git rc files) into the sandbox, so a migration can't read files such as `~/.ssh` and put them in the forecast diff.
- The sandbox mounts only the host's system folders (`/usr`, `/etc`, `/var/lib`), and an incoming release whose `bin/` or migrations link outside it is refused.
- An exclude list that can't be read, or sits in a folder that can't be searched, stops omaforecast instead of being ignored. Excludes also apply to the Omarchy state copied into the sandbox.
- An end-to-end test builds real pacman packages from Omarchy source and checks the forecast against the real update. A smoke test runs without root or Docker.

[0.2.0]: https://github.com/w-mir1/omaforecast/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/w-mir1/omaforecast/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/w-mir1/omaforecast/releases/tag/v0.1.0
