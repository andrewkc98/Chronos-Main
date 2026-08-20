# chronos-gn Deployment Guide

## Purpose

Deploy chronos-gn on a macOS device that should back up to a Time Machine sparsebundle stored on a network share.

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
6. Confirm whether the first encrypted image password should be saved in Keychain. Unattended remounts need it there.
7. Decide whether to use a config file rather than flags. See [configuration.md](configuration.md).
8. If a pre-3.0 `chronos` install exists on this machine, read [migration-from-chronos.md](migration-from-chronos.md) first.

## Example deployment command

```bash
bash bin/chronos-gn \
  --url "smb://nas.example.com/TimeMachine" \
  --destination "/Volumes/TimeMachine" \
  --size 2000g \
  --filesystem APFS \
  --name "Time Machine Backups" \
  --verbose
```

## Config-file deployment

For repeat deployments, put the settings in a file instead:

```bash
mkdir -p ~/.config/chronos-gn
cp examples/chronos-gn.conf.example ~/.config/chronos-gn/config
chmod 600 ~/.config/chronos-gn/config
$EDITOR ~/.config/chronos-gn/config
bash bin/chronos-gn --verbose
```

## Unattended / automated re-runs

A run that gets interrupted after the sparsebundle copy to the share has started (network drop, script killed, machine slept) leaves a partial bundle staged at `<destination>/.<bundle-name>.partial`. By design, the next run stops and asks before touching it — an unattended retry that silently deleted or overwrote a partial copy could just as easily be deleting an in-progress legitimate copy from a different run.

For automation (CI, MDM post-install scripts, scheduled retries) that needs to proceed without a human at the prompt, pass `--force-clean-partial` (or `-y`, which also auto-confirms the legacy-migration prompt) so a leftover `.partial` bundle is removed without asking:

```bash
bash bin/chronos-gn --url "smb://nas.example.com/TimeMachine" --force-clean-partial --verbose
```

Without one of these flags, a non-interactive re-run (no TTY on stdin) fails closed rather than guessing — `confirm_action` returns false when it cannot prompt, so the run aborts with the partial-bundle error instead of proceeding either way.

## LaunchAgent-only update

```bash
bash bin/chronos-gn --launchagent-only --verbose
```

This mode updates the helper, monitor, LaunchAgent plist, and launchctl state while skipping sparsebundle and Time Machine destination changes.

## Verification steps

```bash
cat ~/Library/Logs/chronos-gn/chronos-gn.log
tmutil destinationinfo
mount | grep "Time Machine Backups"
launchctl print gui/$(id -u)/io.github.andrewkc98.chronos-gn
ls -la ~/Library/Logs/chronos-gn
cat ~/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log
cat ~/Library/Logs/chronos-gn/chronos-gn-remount.log
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
10. Confirm a restore actually works. A backup you have never restored from is a hypothesis, not a backup.

## Rollback

```bash
bash bin/chronos-gn-uninstall --dry-run --verbose
bash bin/chronos-gn-uninstall --verbose
```

Preserve Time Machine destination:

```bash
bash bin/chronos-gn-uninstall --keep-tm-destination --verbose
```
