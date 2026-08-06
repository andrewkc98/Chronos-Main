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

### Fixed
- **Stacked disk image password prompts after going off-network.** Three compounding causes: `share_path_ready` trusted cached metadata, so a stale SMB mountpoint looked healthy; `refresh_share_access` short-circuited on that state before reaching the `network_host_reachable` guard, bypassing the popup suppression added in 2.2.1; and the mount retry loop re-issued a GUI mount request up to three times per run even though `open` returns immediately and the previous dialog was still waiting for input. At the default 300s interval an unattended machine accumulated roughly three dozen dialogs an hour. Reachability is now a precondition of share readiness, exactly one GUI mount request is made per run, a new `GUI_MOUNT_COOLDOWN` (default 1800s) suppresses requests after an unanswered prompt, and `pgrep -x DiskImageMounter` blocks a request while a dialog is on screen.
- **Predictable log path in a world-writable directory.** `/tmp/chronos.log` was truncated by a script that then escalates via `sudo`, making it a symlink-swap target for any local user. The default now lives in the console user's home with a `0700` directory; symlinked log paths are refused, and a default path inside a world-writable directory is refused unless `--log-file` is passed explicitly.
- The uninstaller did not remove `chronos-remount-monitor.sh`, and looked for LaunchAgent logs named `launchagent.out`/`launchagent.err`, which the installer stopped producing in 2.2.1. Both left files behind on uninstall.
- The uninstaller reported version `1.0.0` while shipping alongside a `2.2.1` installer. Both scripts now carry the project version.
- Log initialization no longer requires the log directory to be writable before argument parsing finishes; early output is buffered and flushed once the final path is known.

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
