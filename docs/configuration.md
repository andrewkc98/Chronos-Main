# Configuration reference

Every setting can come from a command-line flag, and most can also come from a config file. Precedence, highest first:

1. Command-line flag
2. Environment variable (only for the password and the config path)
3. Config file
4. Built-in default

## Config file

Search order, first match wins:

1. `--config PATH`
2. `$CHRONOS_GN_CONFIG`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/chronos-gn/config`
4. `/etc/chronos-gn/config`

Format is `KEY=value`, one per line. Blank lines and `#` comments are ignored. Surrounding single or double quotes are stripped. Booleans accept `true/false`, `yes/no`, `on/off`, `1/0`.

The file is **parsed, not sourced**. It may be read while running under `sudo`, so sourcing it would turn a config file into arbitrary root code execution. Consequences:

- No shell expansion, command substitution, or variable references. `SIZE=$MYSIZE` sets the literal string `$MYSIZE`.
- Unknown keys are a hard error, so a typo fails loudly instead of being silently ignored.
- `ENCRYPTION_PASSWORD` is rejected outright.

`chmod 600` your config file. `chronos-gn` warns if it is group- or world-writable.

See [`examples/chronos-gn.conf.example`](../examples/chronos-gn.conf.example) for an annotated template.

## Settings

| Config key | Flag | Default | Meaning |
|---|---|---|---|
| `NETWORK_URL` | `-u`, `--url` | *(required)* | `smb://host/share` or `afp://host/share` |
| `DESTINATION` | `-d`, `--destination` | `/Volumes/TimeMachine` | Local mount point of the share |
| `SIZE` | `-s`, `--size` | `2000g` | Sparsebundle ceiling; accepts `b k m g t p e` |
| `FILESYSTEM` | `-f`, `--filesystem` | `APFS` | `APFS`, `Case-sensitive APFS`, `Journaled HFS+`, `Case-sensitive Journaled HFS+` |
| `VOLUME_NAME` | `-n`, `--name` | `Time Machine Backups` | Volume name inside the image; also sets `/Volumes/<name>` |
| `ENABLE_ENCRYPTION` | `--no-encryption` | `true` | AES-256 encryption of the sparsebundle |
| `PASSWORD_ENV_VAR` | `--password-env` | `CHRONOS_GN_ENCRYPTION_PASSWORD` | Env var holding the encryption password |
| `LABEL_PREFIX` | `--label-prefix` | `io.github.andrewkc98` | Reverse-DNS prefix; full label is `<prefix>.chronos-gn` |
| `HELPER_DIR` | `--helper-dir` | `/usr/local/lib/chronos-gn` | Where the generated helper and monitor live |
| `LOG_FILE` | `--log-file` | `~/Library/Logs/chronos-gn/chronos-gn.log` | Main setup log |
| `LAUNCH_INTERVAL` | `--launch-interval` | `300` | Seconds between remount checks |
| `GUI_MOUNT_COOLDOWN` | `--gui-mount-cooldown` | `1800` | After an unanswered disk image password prompt, seconds to wait before asking again. `0` disables the cooldown. |
| `BACKUP_ALERT_DAYS` | `--backup-alert-days` | `7` | Alert when the newest Time Machine backup is older than this many days. `0` disables the check. |
| `START_FIRST_BACKUP` | `--no-start-backup` | `true` | Start a backup after setup |

## Flags with no config equivalent

These are per-run decisions, so they are deliberately not settable in a file:

| Flag | Effect |
|---|---|
| `-c`, `--config PATH` | Use this config file |
| `--launchagent-only` | Update only helper/monitor/LaunchAgent assets; skip all sparsebundle and Time Machine changes |
| `--no-launchagent` | Skip LaunchAgent setup entirely |
| `--force-clean-partial` | Delete a leftover `.partial` staging bundle without asking |
| `--no-migrate` | Do not migrate a detected pre-3.0 `chronos` install |
| `-y`, `--yes` | Auto-confirm destructive prompts |
| `-v`, `--verbose` | Also print INFO/WARN to stderr |
| `--debug` | Verbose plus debug logging; retains the early-run log on failure |
| `-h`, `--help` | Usage |

## Environment variables

| Variable | Purpose |
|---|---|
| `CHRONOS_GN_ENCRYPTION_PASSWORD` | Encryption password when encryption is enabled |
| `CHRONOS_GN_CONFIG` | Path to a config file |
| `CHRONOS_ENCRYPTION_PASSWORD` | Deprecated pre-3.0 name; still honored, warns |

Prefer the interactive prompt for the password. Use the environment variable only for controlled automation, and never export it from a shell profile.

## Notes on specific settings

**`LABEL_PREFIX`** — change this if you fork the project, or if you want two independent installs on one machine. It must be a valid reverse-DNS-ish string (`[A-Za-z0-9][A-Za-z0-9._-]*`). Changing it after install orphans the old LaunchAgent; uninstall with the old prefix first.

**`LOG_FILE`** — the default lives in the console user's home. Setting this explicitly counts as an override and relaxes the check that refuses a default log path inside a world-writable directory, so pick a directory only you can write to. A log path that is a symlink is refused either way.

**`SIZE`** — a sparsebundle only consumes what it uses, but Time Machine treats this as the disk size and will prune backups against it. Sizing it near your share quota is normal; sizing it larger than the share can hold means Time Machine will not prune until the share itself fills.

**`GUI_MOUNT_COOLDOWN`** — this exists because an unanswered password dialog is invisible to every state check the remount helper makes: the volume is not mounted and the image is not attached, so without a cooldown each pass concludes "mount it" and stacks another dialog behind the first. Lower it if you want faster recovery after dismissing a prompt; raise it if you are often away from the machine. Setting it to `0` restores the pre-3.0 behavior, which is not recommended.

**`BACKUP_ALERT_DAYS`** — the persistent monitor checks `tmutil latestbackup` at most once an hour and compares its date against this threshold. When the newest backup is older than `BACKUP_ALERT_DAYS`, it logs an ERROR and posts a macOS user notification, so a share that silently stopped accepting backups (permissions changed, quota hit, share unmounted for good) does not go unnoticed for weeks. Both the log line and the notification are throttled to once per 24h. Setting it to `0` disables the check entirely.

**`VOLUME_NAME`** — two machines can share one `VOLUME_NAME` safely; the sparsebundle name is derived from computer name plus MAC address, so each machine gets its own image. But the mount point `/Volumes/<VOLUME_NAME>` is per-machine, so this only matters locally.
