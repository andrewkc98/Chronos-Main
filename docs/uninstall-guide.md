# Chronos Uninstall Guide

## Dry run first

```bash
bash chronos_uninstall.sh --dry-run --verbose
```

## Standard uninstall

```bash
bash chronos_uninstall.sh --verbose
```

Default behavior removes matching Time Machine destination entries, helper assets, LaunchAgent plist, and Chronos logs.

## Preserve Time Machine destination

```bash
bash chronos_uninstall.sh --keep-tm-destination --verbose
```

## Preserve helper assets

```bash
bash chronos_uninstall.sh --keep-helper-assets --verbose
```

## Preserve logs

```bash
bash chronos_uninstall.sh --keep-logs --verbose
```

## Verification

```bash
launchctl print gui/$(id -u)/com.$USER.chronos
ls -la ~/Library/LaunchAgents | grep chronos
ls -la /usr/local/lib/chronos
tmutil destinationinfo
ls -la ~/Library/Logs/Chronos
```

> The uninstall process does not delete the sparsebundle itself. Deleting a sparsebundle is destructive and should be handled separately with a confirmed backup retention decision.
