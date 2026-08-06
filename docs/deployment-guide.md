# Chronos Deployment Guide

## Purpose

Deploy Chronos on a macOS device that should back up to a Time Machine sparsebundle stored on a network share.

## Prerequisites

- macOS 11 Big Sur or newer
- Local administrator privileges
- Reachable SMB or AFP network share
- Write access to the backup share
- Time Machine allowed by local policy/MDM
- Enough storage quota for the sparsebundle size

## Pre-deployment checklist

1. Confirm the share can be mounted manually in Finder.
2. Confirm the user can create and delete a test file on the share.
3. Decide sparsebundle size, filesystem, and volume name.
4. Decide whether encryption should be enabled. Default is enabled.
5. Confirm NAS/server-side deletion protection, snapshots, or recycle-bin behavior.
6. Confirm whether the first encrypted image password should be saved in Keychain.

## Example deployment command

```bash
bash chronos_refactor.sh \
  --url "smb://backup-server.example.local/TimeMachine" \
  --destination "/Volumes/TimeMachine" \
  --size 2000g \
  --filesystem APFS \
  --name "Time Machine Backups" \
  --verbose
```

## LaunchAgent-only update

```bash
bash chronos_refactor.sh --launchagent-only --verbose
```

This mode updates the helper, monitor, LaunchAgent plist, and launchctl state while skipping sparsebundle and Time Machine destination changes.

## Verification steps

```bash
cat /tmp/chronos.log
tmutil destinationinfo
mount | grep "Time Machine Backups"
launchctl print gui/$(id -u)/com.$USER.chronos
ls -la ~/Library/Logs/Chronos
cat ~/Library/Logs/Chronos/chronos-remount-monitor.log
cat ~/Library/Logs/Chronos/chronos-remount.log
```

## Operational test

1. Run setup successfully.
2. Confirm Time Machine destination.
3. Reboot or log out/in.
4. Wait one monitor interval (Default: 5 minutes).
5. Confirm share and sparsebundle remount.
6. Disconnect from the network.
7. Confirm no repeating Finder popup appears while offline.
8. Reconnect to the network.
9. Confirm the monitor eventually restores access.

## Rollback

```bash
bash chronos_uninstall.sh --dry-run --verbose
bash chronos_uninstall.sh --verbose
```

Preserve Time Machine destination:

```bash
bash chronos_uninstall.sh --keep-tm-destination --verbose
```
