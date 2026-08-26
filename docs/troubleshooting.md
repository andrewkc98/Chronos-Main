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

## Symptom: password prompts for the sparsebundle pile up after going off-network

This was a real bug through v2.2.1, fixed in 3.0.0. If you are still on the old build, this is the one you are hitting.

Three things combined:

1. When the link drops, macOS leaves the SMB mountpoint in `mount` output and answers `ls`/`stat` from cached metadata. The old `share_path_ready` only checked those, so a dead share looked healthy.
2. `refresh_share_access` short-circuited on that healthy-looking state and returned success **before** reaching the `network_host_reachable` guard. The popup suppression added in 2.2.1 only covered the path where the checks fail, so a stale mount walked straight past it.
3. The image itself was force-ejected when the link dropped, so the helper saw "share fine, bundle there, image not mounted" and asked DiskImageMounter to open a sparsebundle whose backing store was gone. macOS responds to that with the password dialog.

The pile-up came from the retry loop. `open` hands off to Launch Services and returns 0 immediately, so the mount "succeeded" as far as the script knew; the 45-second wait then timed out against your unanswered dialog, and the loop tried again — up to three dialogs per run, every `LAUNCH_INTERVAL` seconds. Walk away for an hour on the default 300s interval and you come back to roughly three dozen.

3.0.0 fixes all three:

- `share_path_ready` requires host reachability, so a stale mount can no longer pass.
- One GUI mount request per run, never a retry on top of a pending dialog.
- If a request does not produce a mount within 45s, a cooldown (`GUI_MOUNT_COOLDOWN`, default 30 minutes) suppresses further requests, and `pgrep -x DiskImageMounter` blocks a new request while a dialog is on screen.

Check it is working:

```bash
grep -E "cooldown|prompt is already open|not reachable" ~/Library/Logs/chronos-gn/chronos-gn-remount.log
ls -la ~/Library/Logs/chronos-gn/chronos-gn-gui-mount.state
```

The state file holds the epoch seconds of the last unanswered prompt and is removed as soon as a mount succeeds. Deleting it manually ends the cooldown early.

Separately: saving the sparsebundle password to Keychain stops most of these prompts appearing at all, because DiskImageMounter can then unlock without asking.

## Symptom: the correct password is rejected with "Could not open <bundle>"

A dialog asks for the sparsebundle password; you type the right one, tick "Remember password in my keychain", and get "Could not open …" whichever button you press. A saved Keychain entry does not help, and more dialogs appear over the following hours.

Fixed in 3.0.0. Two defects compounded:

1. `bundle_is_attached` was written as `hdiutil info | grep -Fq "$BUNDLE_PATH"` while the helper runs under `set -o pipefail`. `grep -q` exits at its first match, `hdiutil` is killed by SIGPIPE, and pipefail promotes that 141 to the pipeline's status — so a **successful** match reported "not attached". Whether it misfired depended on whether `hdiutil`'s output outran the pipe buffer, which is why it struck at random.
2. Because of (1) the helper never saw the attachment that DiskImageMounter creates while it waits for a password, so it never reconciled it. That attachment outlived the dialog, and every later attempt tried to attach an image that was already attached — which is what macOS reports as "could not open".

Once (1) was fixed, `mounted_state_healthy` would have detached the image out from under a dialog you were part-way through answering. So it now checks for a pending prompt first and waits instead of detaching.

If a prompt is left unanswered for longer than twice `GUI_MOUNT_COOLDOWN`, the helper logs a warning and posts one macOS notification rather than sitting silent. It never dismisses a dialog for you.

If you are on an older build and stuck right now, clear the wreckage by hand:

```bash
hdiutil info | grep -A2 image-path
```

Dismiss every open dialog, `hdiutil detach` any device listed for your sparsebundle, then let the next helper cycle mount it cleanly.

Confirm the fix is in your installed helper:

```bash
grep -A3 "^bundle_is_attached" /usr/local/lib/chronos-gn/chronos-gn-remount.sh
```

It should capture `hdiutil info` into a variable, not pipe it into `grep -q`.

## Symptom: the volume is detached and remounted every few minutes

The log shows this pair on every cycle while the volume is plainly mounted and working:

```
[WARN] Mounted volume at /Volumes/... is stale (share is reachable but the volume does not answer reads); detaching for remount
[WARN] Detaching stale sparsebundle attachment for ...
```

Fixed in 3.0.0. The health probe listed the volume's contents with `ls -la`, and macOS denies that on a Time Machine destination to any process without Full Disk Access — which the LaunchAgent helper does not have and should not need. The denial is instantaneous, so a healthy volume failed the probe on every run and was torn down. Check it for yourself:

```bash
ls -la "/Volumes/Time Machine Backups"
```

`Operation not permitted` from a Terminal without Full Disk Access is the expected, healthy answer. The helper now distinguishes that denial from a timeout or an I/O error; only the latter two mean the mount is stale.

Granting Full Disk Access is **not** required and does not help — the fix is to stop treating the denial as a fault.

## Symptom: a Finder window opens every time the backup volume mounts

macOS opens a window for a disk image's volume whenever it mounts, so reconnecting to the network interrupts whatever you are doing. Since 3.0.0 the installer turns this off by default — see `SUPPRESS_MOUNT_WINDOW` in [configuration.md](configuration.md). To check the current state:

```bash
defaults read com.apple.frameworks.diskimages auto-open-rw-root
```

`0` means suppressed. If the key does not exist, macOS uses its default of opening the window. Reinstalling with `--keep-mount-window` leaves the preference domain untouched.

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
