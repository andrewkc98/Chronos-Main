# Chronos Troubleshooting Guide

## Fast triage

```bash
cat /tmp/chronos.log
ls -la ~/Library/Logs/Chronos
cat ~/Library/Logs/Chronos/chronos-remount-monitor.log
cat ~/Library/Logs/Chronos/chronos-remount.log
tmutil destinationinfo
launchctl print gui/$(id -u)/com.$USER.chronos
```

## Symptom: Finder popup says there was a problem connecting to the server

Likely cause: a GUI mount request was attempted while the network host was offline or unreachable.

**v2.2.1 mitigation:** the remount helper checks host reachability with `nc` before calling GUI/Finder mount methods. If the host is unreachable, it logs a warning and skips GUI mount requests.

Checks:

```bash
nc -z -w 2 backup-server.example.local 445
grep -i "not reachable" ~/Library/Logs/Chronos/chronos-remount.log
```

Fix:

```bash
bash chronos_refactor.sh --launchagent-only --verbose
```

## Symptom: LaunchAgent is installed but remount does not happen

Checks:

```bash
launchctl print gui/$(id -u)/com.$USER.chronos
cat ~/Library/Logs/Chronos/chronos-monitor.err
cat ~/Library/Logs/Chronos/chronos-remount-monitor.log
```

Likely causes:

- LaunchAgent not loaded in the GUI user session.
- Helper path ownership or permissions are incorrect.
- Monitor exited because of a script error.
- User is not in an Aqua session.

Fix:

```bash
bash chronos_refactor.sh --launchagent-only --verbose
launchctl kickstart -k gui/$(id -u)/com.$USER.chronos
```

## Symptom: Sparsebundle exists but will not mount

Checks:

```bash
ls -la /Volumes/TimeMachine
hdiutil imageinfo "/Volumes/TimeMachine/<COMPUTER>_<MAC>.sparsebundle"
hdiutil info | grep -A3 -B3 sparsebundle
```

Likely causes:

- encrypted image password was not provided or not stored in Keychain
- sparsebundle copy is incomplete or corrupted
- SMB share is mounted but stale/unusable
- DiskImageMounter has user-session permission issues

## Symptom: Time Machine destination is missing after setup

Checks:

```bash
tmutil destinationinfo
mount | grep "Time Machine"
cat /tmp/chronos.log | grep -i "destination"
```

Manual remediation:

```bash
sudo tmutil setdestination -a "/Volumes/Time Machine Backups"
tmutil destinationinfo
```

## Symptom: Script fails during sparsebundle copy

Likely causes:

- SMB xattr behavior returned a non-zero `cp` or `mv` status
- network interruption
- permissions issue
- partial staging bundle remains

Checks:

```bash
ls -la /Volumes/TimeMachine | grep partial
cat /tmp/chronos.log | grep -i staging
```

Controlled cleanup:

```bash
bash chronos_refactor.sh --force-clean-partial --verbose
```

## Common mistakes

- Running everything as root and expecting GUI/Keychain behavior to work normally.
- Publishing real server/share names in GitHub docs.
- Assuming encryption prevents accidental or malicious sparsebundle deletion.
- Treating `mount` output as proof that a stale SMB share is usable.
- Ignoring `~/Library/Logs/Chronos` and looking only at `/tmp/chronos.log`.
