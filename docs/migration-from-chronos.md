# Migrating from `chronos` (pre-3.0)

`chronos-gn` 3.0.0 is the generalized release of a personal tool called Chronos. If you ran `chronos_refactor.sh` v2.x, this page covers what changes and what happens to your existing backups.

## Short version

Your sparsebundle and your backup history are safe. Nothing in this migration touches them.

What gets replaced is the LaunchAgent, the two helper scripts, and the log directory — the parts that were named after your username instead of the project.

## What changed

| Pre-3.0 | 3.0.0 |
|---|---|
| `chronos_refactor.sh` | `bin/chronos-gn` |
| `chronos_uninstall.sh` | `bin/chronos-gn-uninstall` |
| LaunchAgent `com.<user>.chronos` | `<label-prefix>.chronos-gn`, default `io.github.andrewkc98.chronos-gn` |
| `/usr/local/lib/chronos/` | `/usr/local/lib/chronos-gn/` |
| `chronos-remount.sh`, `chronos-remount-monitor.sh` | `chronos-gn-remount.sh`, `chronos-gn-remount-monitor.sh` |
| `/tmp/chronos.log` | `~/Library/Logs/chronos-gn/chronos-gn.log` |
| `~/Library/Logs/Chronos/` | `~/Library/Logs/chronos-gn/` |
| `CHRONOS_ENCRYPTION_PASSWORD` | `CHRONOS_GN_ENCRYPTION_PASSWORD` (old name still works, warns) |
| `NETWORK_URL` defaulted to `smb://server.local/TimeMachine` | `--url` is required |
| No config file | `~/.config/chronos-gn/config` |

## Running the migration

Run `chronos-gn` normally. It detects the old install and asks before doing anything:

```bash
bash bin/chronos-gn --url "smb://nas.example.com/TimeMachine" --verbose
```

You will see the detected assets listed, then a confirmation prompt. Answer yes, or pass `-y` to auto-confirm. In a non-interactive shell without `-y`, it refuses to proceed rather than silently modifying your install.

The confirmation happens up front, but the removal itself runs later — after the sparsebundle is mounted and the Time Machine destination is confirmed. If setup fails partway, your old install is still in place and still working.

### What migration does

1. `launchctl bootout` the old `com.<user>.chronos` agent
2. Delete `~/Library/LaunchAgents/com.<user>.chronos.plist`
3. Delete `/usr/local/lib/chronos/`
4. Move `~/Library/Logs/Chronos/` to `~/Library/Logs/chronos-gn/legacy-chronos/` — archived, not deleted

### What migration does not do

- It does not touch the sparsebundle.
- It does not remove or re-create the Time Machine destination. `chronos-gn` registers the same mounted volume path, and `tmutil setdestination -a` is idempotent, so the destination and its history carry through unchanged.
- It does not touch Keychain. Your saved sparsebundle password still works.

## Keeping both installed

Pass `--no-migrate` to leave the old install alone. Be aware of what that means: two monitors will run against the same sparsebundle, both calling Finder-backed mount APIs on the same image. They will not corrupt anything, but you will get duplicated log noise and occasional redundant mount attempts.

If you genuinely want two independent installs, give the second one its own `--label-prefix` and `--helper-dir`, and point it at a different share.

## Removing the old install by hand

If you would rather do it yourself before running `chronos-gn`, use the old uninstaller from `legacy/`, or:

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.$USER.chronos.plist
rm -f ~/Library/LaunchAgents/com.$USER.chronos.plist
sudo rm -rf /usr/local/lib/chronos
rm -rf ~/Library/Logs/Chronos
```

Then run `chronos-gn` with `--no-migrate` or just normally — with nothing left to detect, it proceeds straight to setup.

## Rebuilding your invocation as a config file

A pre-3.0 command like:

```bash
bash chronos_refactor.sh -u smb://nas.example.com/TimeMachine -d /Volumes/TimeMachine -s 2000g -n "Time Machine Backups" -v
```

becomes `~/.config/chronos-gn/config`:

```ini
NETWORK_URL=smb://nas.example.com/TimeMachine
DESTINATION=/Volumes/TimeMachine
SIZE=2000g
VOLUME_NAME=Time Machine Backups
```

plus `bash bin/chronos-gn --verbose`.
