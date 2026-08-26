# chronos-gn Uninstall Guide

## Dry run first

```bash
bash bin/chronos-gn-uninstall --dry-run --verbose
```

## Standard uninstall

```bash
bash bin/chronos-gn-uninstall --verbose
```

Default behavior removes matching Time Machine destination entries, helper assets, LaunchAgent plist, and chronos-gn logs.

## Preserve Time Machine destination

```bash
bash bin/chronos-gn-uninstall --keep-tm-destination --verbose
```

## Preserve helper assets

```bash
bash bin/chronos-gn-uninstall --keep-helper-assets --verbose
```

## Preserve logs

```bash
bash bin/chronos-gn-uninstall --keep-logs --verbose
```

## Non-default install locations

If you installed with a custom `--label-prefix` or `--helper-dir`, pass the same values to the uninstaller, or point both at the same config file:

```bash
bash bin/chronos-gn-uninstall --config ~/.config/chronos-gn/config --dry-run --verbose
```

Without them the uninstaller looks for the defaults, reports nothing present, and leaves your install untouched.

## Finder mount-window preference

If the installer suppressed the Finder window that opens when the backup volume mounts, it recorded the previous values of `auto-open-rw-root` and `auto-open-ro-root` in `<HELPER_DIR>/chronos-gn-mount-window.state`. The uninstaller restores exactly the keys listed there — a key it never changed is absent from the file and is left alone, so a value you set yourself survives.

The record is removed along with the rest of the helper assets, so `--keep-helper-assets` also keeps the preference as-is.

## Legacy chronos assets

The uninstaller removes `chronos-gn` assets only. If it finds a pre-3.0 `chronos` install it reports it and leaves it alone; see [migration-from-chronos.md](migration-from-chronos.md) for removing that.

## Verification

```bash
launchctl print gui/$(id -u)/io.github.andrewkc98.chronos-gn
ls -la ~/Library/LaunchAgents | grep chronos
ls -la /usr/local/lib/chronos-gn
tmutil destinationinfo
ls -la ~/Library/Logs/chronos-gn
```

> The uninstall process does not delete the sparsebundle itself. Deleting a sparsebundle is destructive and should be handled separately with a confirmed backup retention decision.
