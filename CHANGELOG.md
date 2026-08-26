# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] — Unreleased

First public release. The project was renamed from `chronos` to `chronos-gn` and generalized so it can be installed by anyone, not just its author. See [docs/migration-from-chronos.md](docs/migration-from-chronos.md) for the upgrade path.

### Breaking

- `--url` is now **required**. It previously defaulted to `smb://server.local/TimeMachine`, which silently targeted a host that only existed on one LAN.
- Scripts renamed: `chronos_refactor.sh` → `bin/chronos-gn`, `chronos_uninstall.sh` → `bin/chronos-gn-uninstall`.
- LaunchAgent label changed from `com.<user>.chronos` to `<label-prefix>.chronos-gn`, default `io.github.andrewkc98.chronos-gn`. The old form was not a valid reverse-DNS namespace.
- Helper directory moved from `/usr/local/lib/chronos` to `/usr/local/lib/chronos-gn`; helper scripts renamed to `chronos-gn-remount.sh` and `chronos-gn-remount-monitor.sh`.
- Log locations moved: main log from `/tmp/chronos.log` to `~/Library/Logs/chronos-gn/chronos-gn.log`, and the LaunchAgent log directory from `~/Library/Logs/Chronos/` to `~/Library/Logs/chronos-gn/`.
- Encryption password environment variable renamed to `CHRONOS_GN_ENCRYPTION_PASSWORD`. The old `CHRONOS_ENCRYPTION_PASSWORD` is still honored with a warning.

### Added
- Config file support with a documented search order (`--config`, `$CHRONOS_GN_CONFIG`, `~/.config/chronos-gn/config`, `/etc/chronos-gn/config`) and an annotated template in `examples/`. Files are parsed rather than sourced, keys are allowlisted, and `ENCRYPTION_PASSWORD` is rejected.
- `--gui-mount-cooldown` / `GUI_MOUNT_COOLDOWN` to control how long to wait after an unanswered password prompt before requesting a mount again.
- `--label-prefix` and `--helper-dir` so the install location and LaunchAgent namespace are no longer hardcoded.
- Automatic detection and migration of a pre-3.0 `chronos` install. Consent is requested up front; removal runs only after the new install is confirmed working. The sparsebundle, the Time Machine destination, and Keychain are never touched. `--no-migrate` opts out.
- `--log-file` in the uninstaller, plus `--config` and `--label-prefix` so it can clean up a customized install.
- Project documentation: `docs/configuration.md`, `docs/migration-from-chronos.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`.
- CI running `bash -n`, `shellcheck`, and no-NAS smoke tests.
- `--backup-alert-days` / `BACKUP_ALERT_DAYS` (default 7, 0 disables). The persistent monitor checks `tmutil latestbackup` at most once an hour and, when the newest backup is older than the threshold, logs an ERROR and posts a macOS user notification — both throttled to once per 24h — so a share that silently stopped accepting backups does not go unnoticed for weeks.
- `--keep-mount-window` / `SUPPRESS_MOUNT_WINDOW`. macOS opens a Finder window for the backup volume every time it mounts, interrupting whatever you are doing on every reconnect. The installer now sets `auto-open-rw-root` and `auto-open-ro-root` to `0` in `com.apple.frameworks.diskimages` for the console user by default. Because that preference domain is not ours, the previous values are read, logged, and recorded in `<HELPER_DIR>/chronos-gn-mount-window.state`; only keys that were not already `0` are changed, and `chronos-gn-uninstall` restores exactly those. `--keep-mount-window` opts out. The share mount request also uses `open -g` so reconnecting no longer fronts a Finder window.
- `tests/check-remount-helper.sh`, covering the generated remount helper directly: the pipefail/SIGPIPE hazard against both large and small `hdiutil` output, the password-prompt guards in `mounted_state_healthy`, and class-level assertions that no `cmd | grep -q` pipeline and no use-before-definition reappears in either generated script. Extraction logic is shared with `tests/check-generated-assets.sh` via `tests/lib-extract.sh`.
- Installer-level lock (`acquire_installer_lock`, mirroring the generated helper's own `mkdir`-based lock) so two concurrent `chronos-gn` runs cannot race the same sparsebundle, share mount, or Time Machine destination; a lock left behind by a dead process is detected and reaped automatically.

### Fixed
- **A healthy Time Machine volume is no longer detached on every check.** `mounted_state_healthy` probed the mounted volume with `ls -la` and treated failure as a stale mount. macOS denies directory listing on a Time Machine destination to any process without Full Disk Access, which the LaunchAgent helper does not have and should not need, so a perfectly healthy backup volume failed that probe instantly on every run and was detached. `probe_path_detail` now keeps the probe's stderr, and a denial (`Operation not permitted` / `Permission denied`) is read as healthy. A timeout or an I/O error still means stale, so a genuinely hung mount is still reconciled.
- **An attached-but-unmounted sparsebundle is now mounted instead of detached.** macOS routinely attaches a sparsebundle on a network share -- password accepted, contents decrypted -- without mounting the APFS volume inside it. The helper had no step for that state: it read "attached, volume not mounted" as a stale attachment, detached it, and asked DiskImageMounter to open the image again, which raised a fresh password dialog. On the default 300s interval that is a dialog every cycle, and it never converged, because re-opening does not fix a volume that simply did not auto-mount. `mount_attached_volume` now runs `diskutil mount` against the image's existing dev-entries first; it needs no password, since the attachment in hand is already decrypted. Detaching is the fallback, not the first move.
- **A bare attachment is no longer reported as a confirmed mount.** The helper's final check treated `bundle_is_attached` as success, logging "Final mount confirmed for attached bundle" while `/Volumes/<VOLUME_NAME>` was absent and Time Machine had nothing to write to. It now reports that state as a failure.
- **Correct sparsebundle password rejected with "Could not open".** `bundle_is_attached` was `hdiutil info | grep -Fq "$BUNDLE_PATH"` in a helper that runs under `set -o pipefail`: `grep -q` exits at its first match, `hdiutil` dies of SIGPIPE, and pipefail promotes that 141 to the pipeline's status, so a successful match reported "not attached". It misfired only when `hdiutil`'s output outran the pipe buffer, which made it intermittent and long-lived. The consequence was that the helper never saw the attachment DiskImageMounter creates while waiting for a password, so it never reconciled it; the orphaned attachment outlived the dialog and every later attempt tried to attach an already-attached image. Both this and the equivalent `printf | grep -qi` in `start_first_backup` now match in-shell instead of across a pipe, and a regression test asserts no `cmd | grep -q` pipeline exists in either generated script.
- **A pending password dialog is no longer detached out from under the user.** With `bundle_is_attached` repaired, `mounted_state_healthy` would have treated the in-flight attachment behind an open dialog as stale and detached it, so the password typed seconds later landed on a detached image. It now checks `gui_mount_prompt_pending` before detaching in both its stale branches and waits instead.
- **An unanswered prompt no longer wedges the helper silently.** The time a prompt has been outstanding is tracked in `chronos-gn-gui-prompt.state`; past twice `GUI_MOUNT_COOLDOWN` the helper logs a warning and posts one macOS notification. It never dismisses a dialog or kills DiskImageMounter — recovery stays a human decision.
- **The remount monitor died at load time when `LAUNCH_INTERVAL` was under 180s.** The helper-timeout clamp called `log()` before `log()` was defined, which under `set -e` exited the monitor immediately. The clamp now sits below the definition.
- The uninstaller left `chronos-gn-gui-prompt.state` and `chronos-gn-backup-alert.state` behind.
- **Stacked disk image password prompts after going off-network.** Three compounding causes: `share_path_ready` trusted cached metadata, so a stale SMB mountpoint looked healthy; `refresh_share_access` short-circuited on that state before reaching the `network_host_reachable` guard, bypassing the popup suppression added in 2.2.1; and the mount retry loop re-issued a GUI mount request up to three times per run even though `open` returns immediately and the previous dialog was still waiting for input. At the default 300s interval an unattended machine accumulated roughly three dozen dialogs an hour. Reachability is now a precondition of share readiness, exactly one GUI mount request is made per run, a new `GUI_MOUNT_COOLDOWN` (default 1800s) suppresses requests after an unanswered prompt, and `pgrep -x DiskImageMounter` blocks a request while a dialog is on screen.
- **Predictable log path in a world-writable directory.** `/tmp/chronos.log` was truncated by a script that then escalates via `sudo`, making it a symlink-swap target for any local user. The default now lives in the console user's home with a `0700` directory; symlinked log paths are refused, and a default path inside a world-writable directory is refused unless `--log-file` is passed explicitly.
- The uninstaller did not remove `chronos-remount-monitor.sh`, and looked for LaunchAgent logs named `launchagent.out`/`launchagent.err`, which the installer stopped producing in 2.2.1. Both left files behind on uninstall.
- The uninstaller reported version `1.0.0` while shipping alongside a `2.2.1` installer. Both scripts now carry the project version.
- Log initialization no longer requires the log directory to be writable before argument parsing finishes; early output is buffered and flushed once the final path is known.
- **Stale SMB-backed attachments reported as healthy.** The helper and installer now probe a mounted or attached sparsebundle with a timeout-guarded read (not just `stat`/`mount` metadata, which macOS keeps answering from cache after the link drops) before trusting it, and force-detach a stale attachment so a remount can proceed instead of a dead mount blocking backups indefinitely.
- Mount-point and `tmutil destinationinfo` matching now compares exact values instead of substrings, so a duplicate " 1"-suffixed mount left behind by macOS after a stale unmount no longer falsely matches the expected mount point or destination name.
- Sparsebundle staging copies are now verified against the local original (file count, band file count, total byte size, and an `Info.plist` comparison) before being promoted into place; a `cp` failure during staging is fatal after one retry instead of silently promoting a possibly truncated copy.
- `hdiutil create` and `tmutil setdestination` failures now include the captured stderr in the error message and log, instead of a bare non-zero exit with no explanation.
- The installer now checks the login Keychain for a saved disk-image password on encrypted bundles and reports the result (`found`/`missing`) in the run summary, so a missing password is visible at install time instead of being discovered during the first unattended remount.
- The installer now pauses (`launchctl bootout`) an already-running remount agent before touching the share mount, sparsebundle, or Time Machine destination, and holds an installer-level lock for the run's duration, so the live agent can no longer race a run that is mid-mount, mid-copy, or mid-detach.
- The installer now waits for an in-flight `DiskImageMounter` password dialog instead of requesting a second mount on top of it, and the GUI mount cooldown only begins once a dialog is confirmed pending rather than on every unconfirmed mount attempt.
- Fixed unescaped backticks in comments inside the generated helper script's heredoc; they were interpreted as command substitution at install time and corrupted the generated script.
- The remount helper's `chmod` on files written to the SMB share is now a warning instead of a fatal error, since some SMB servers reject POSIX mode changes entirely.
- The remount helper's stale-lock reaping now leaves a lock alone for its first 30 seconds, so a lock caught between `mkdir` and its pid file being written is never mistaken for stale and removed out from under the process that just created it.
- `chronos-gn-uninstall` now waits up to 30s for a live remount helper holding the lock directory to finish before removing it, instead of deleting the lock (and files the helper may still have open under it) out from under a running process.

### Removed
- `chronos_refactor_annotated_v2.2.1.sh`, the original README notes, and the original change documentation moved to `legacy/` as unmaintained historical reference.
- The empty publication-sanitization checklist, which this release completes.

## [2.2.1] — Pre-release (private)

### Added
- `--launchagent-only` to update the remount helper, monitor, and LaunchAgent without touching the sparsebundle or the Time Machine destination.
- Persistent remount monitor. The monitor is a long-running process in the Aqua session that calls a short-lived helper on a sleep loop, replacing the `StartInterval`-only model that proved unreliable.
- Lock directory to prevent duplicate concurrent remount checks.
- `hdiutil attach -agentpass` as a third fallback after DiskImageMounter and Launch Services `open`.

### Fixed
- Finder connection dialogs appear less often when off-network; the helper checks host reachability before making a GUI mount call. This turned out to be incomplete — the guard was bypassed whenever a stale SMB mount still looked healthy locally. See the 3.0.0 entry.
- Interrupted `sleep` after wake or signal delivery no longer terminates the helper or monitor under `set -e`.

## [2.1.1] — Pre-release (private)

Short-lived helper executed by `launchd` on `StartInterval`. Superseded by 2.2.1.
