# chronos-gn Troubleshooting Guide

## Fast triage

```bash
cat ~/Library/Logs/chronos-gn/chronos-gn.log
ls -la ~/Library/Logs/chronos-gn
cat ~/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log
cat ~/Library/Logs/chronos-gn/chronos-gn-remount.log
tmutil destinationinfo
launchctl print gui/$(id -u)/io.github.andrewkc98.chronos-gn
```

## Symptom: Finder popup says there was a problem connecting to the server

Likely cause: a GUI mount request was attempted while the network host was offline or unreachable.

**Built-in mitigation:** the remount helper checks host reachability with `nc` before calling GUI/Finder mount methods. If the host is unreachable, it logs a warning and skips GUI mount requests.

Checks:

```bash
nc -z -w 2 nas.example.com 445
grep -i "not reachable" ~/Library/Logs/chronos-gn/chronos-gn-remount.log
```

Fix:

```bash
bash bin/chronos-gn --launchagent-only --verbose
```

## Symptom: LaunchAgent is installed but remount does not happen

Checks:

```bash
launchctl print gui/$(id -u)/io.github.andrewkc98.chronos-gn
cat ~/Library/Logs/chronos-gn/chronos-gn-monitor.err
cat ~/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log
```

Likely causes:

- LaunchAgent not loaded in the GUI user session.
- Helper path ownership or permissions are incorrect.
- Monitor exited because of a script error.
- User is not in an Aqua session.

Fix:

```bash
bash bin/chronos-gn --launchagent-only --verbose
launchctl kickstart -k gui/$(id -u)/io.github.andrewkc98.chronos-gn
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
cat ~/Library/Logs/chronos-gn/chronos-gn.log | grep -i "destination"
```

Manual remediation:

```bash
sudo tmutil setdestination -a "/Volumes/Time Machine Backups"
tmutil destinationinfo
```

## Symptom: "unsupported configuration key" on startup

The config parser allowlists keys and rejects anything else rather than silently ignoring a typo. Check the reported line against [configuration.md](configuration.md).

Note that shell syntax does not work in a config file — it is parsed, not sourced. `SIZE=$MYSIZE` sets the literal string `$MYSIZE`, and `SIZE=$(cmd)` is not executed.

## Symptom: "Refusing to use the default log path inside world-writable directory"

The default log location resolved to something like `/tmp`, which is a symlink-attack surface for a script that escalates to root. This usually means the console user's home directory could not be resolved. Either fix that, or choose a log path deliberately with `--log-file /path/you/own/chronos-gn.log`.

## Symptom: Two remount monitors running

You have both a pre-3.0 `chronos` install and `chronos-gn`. Check:

```bash
ls ~/Library/LaunchAgents | grep -i chronos
```

See [migration-from-chronos.md](migration-from-chronos.md). Re-run `chronos-gn` and accept the migration prompt, or remove the old install by hand.

## Symptom: Script fails during sparsebundle copy

Likely causes:

- SMB xattr behavior returned a non-zero `cp` or `mv` status
- network interruption
- permissions issue
- partial staging bundle remains

Checks:

```bash
ls -la /Volumes/TimeMachine | grep partial
cat ~/Library/Logs/chronos-gn/chronos-gn.log | grep -i staging
```

Controlled cleanup:

```bash
bash bin/chronos-gn --force-clean-partial --verbose
```

## Common mistakes

- Running everything as root and expecting GUI/Keychain behavior to work normally.
- Publishing real server/share names when filing an issue.
- Assuming encryption prevents accidental or malicious sparsebundle deletion.
- Treating `mount` output as proof that a stale SMB share is usable.
- Reading only the setup log and ignoring the remount and monitor logs next to it — after the initial install, the interesting failures are all in those.
- Editing the generated helper or monitor in `/usr/local/lib/chronos-gn` directly. Those files are regenerated; change the config or flags and re-run with `--launchagent-only`.
