# Contributing

Bug reports, wrong forecasts, and pull requests are welcome.

## Reporting a wrong forecast

A forecast is wrong when `omaforecast check` predicted different file changes than `omaforecast report` showed after the update. Open an issue with the output of both commands, the matching `~/.local/state/omaforecast/reports/omarchy_update_details_*_UTC*.diff`, and any logs in `~/.local/state/omaforecast/sim-logs/`. Check those files for anything private before you attach them.

## Development

omaforecast is one bash script, `bin/omaforecast`. It needs bash, coreutils, find, tar, and diff or git. The dry run also needs bubblewrap.

Run the checks before you open a pull request:

```bash
shellcheck -S warning bin/omaforecast install.sh test/*.sh
test/smoke.sh       # a few seconds, no root, no Docker
test/run-e2e.sh     # about 4 minutes, needs Docker
```

`test/run-e2e.sh` builds two pacman packages from a pinned Omarchy commit (`OMARCHY_REF` in `test/run-e2e.sh`). It installs the older one in an Arch container, customizes a user's config, and checks that the forecast matches what the real update changes. To test against a newer Omarchy, set `OMARCHY_REF`. If the migrations listed in `test/build-fixtures.sh` no longer exist at that commit, update the list too.

`test/record-demo.sh` re-records `assets/omaforecast.cast` and renders `assets/omaforecast.gif`.

## Guidelines

- Keep it one script with no dependencies beyond what a stock Omarchy install has.
- Nothing may write outside `~/.local/state/omaforecast`, `~/.cache/omaforecast`, and the files `setup` installs, unless the user runs `restore`.
- A new behavior gets a check in `test/smoke.sh` or `test/e2e-inside.sh`.
- Add a line to `CHANGELOG.md` under an "Unreleased" heading.

## License

By contributing, you agree that your contributions are licensed under the MIT License.
