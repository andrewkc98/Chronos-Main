# chronos-gn

Automated macOS Time Machine backups to a network share, with a sparsebundle that actually stays mounted.

`chronos-gn` creates (or reuses) a per-machine encrypted sparsebundle on an SMB/AFP share, writes the Time Machine machine metadata, mounts it, registers it as a Time Machine destination, and installs a LaunchAgent-backed monitor that keeps re-establishing the share and image mount after reboots, logouts, sleep, and network drops.

It is the generalized, publicly usable version of a personal tool called Chronos. If you are coming from that, read [docs/migration-from-chronos.md](docs/migration-from-chronos.md).

> Not affiliated with or endorsed by Apple. Time Machine over a network share is not an Apple-supported configuration for arbitrary SMB targets. Test your restores.

## Why this exists

macOS can back up to a network Time Machine destination, but on a generic SMB/AFP share it needs a sparsebundle created and registered by hand, and the mount does not reliably survive a reboot. The parts that make this hard are all macOS-specific: sparsebundle mounting behaves differently under `hdiutil` than under Finder, encrypted images need Keychain access from a GUI session, and a `launchd` job that runs outside the Aqua session cannot do either. `chronos-gn` handles that split.

## Requirements

- macOS 11 Big Sur or newer
- Local administrator privileges (the script uses `sudo` for helper install and `tmutil`)
- A reachable SMB or AFP share you can write to
- Time Machine permitted by local policy/MDM
- Enough quota on the share for the sparsebundle you ask for

## Quickstart

```bash
git clone https://github.com/andrewkc98/chronos-gn.git
cd chronos-gn
bash bin/chronos-gn --url "smb://nas.example.com/TimeMachine" --verbose
```

You will be prompted for an encryption password (encryption is on by default) and, if the share is not already mounted, for share credentials by Finder. Save the sparsebundle password to Keychain when macOS offers — unattended remounts need it.

That single command creates the sparsebundle, registers the destination, installs the remount monitor, and kicks off the first backup.

## Configuration file

Repeating flags gets old. Drop a config file in place instead:

```bash
mkdir -p ~/.config/chronos-gn
cp examples/chronos-gn.conf.example ~/.config/chronos-gn/config
chmod 600 ~/.config/chronos-gn/config
$EDITOR ~/.config/chronos-gn/config
bash bin/chronos-gn --verbose
```

Search order (first match wins): `--config PATH`, `$CHRONOS_GN_CONFIG`, `${XDG_CONFIG_HOME:-$HOME/.config}/chronos-gn/config`, `/etc/chronos-gn/config`. Command-line flags always override the file.

The file is parsed, never sourced — no shell expansion, and unknown keys are a hard error rather than a silent typo. Passwords are rejected outright; use `CHRONOS_GN_ENCRYPTION_PASSWORD` or the interactive prompt.

Full option reference: [docs/configuration.md](docs/configuration.md).

## What gets installed

| Path | What it is |
|---|---|
| `<share>/<ComputerName>_<MAC>.sparsebundle` | The backup image (never removed by the uninstaller) |
| `~/Library/LaunchAgents/<label-prefix>.chronos-gn.plist` | LaunchAgent that starts the monitor in the GUI session |
| `/usr/local/lib/chronos-gn/chronos-gn-remount-monitor.sh` | Long-running monitor |
| `/usr/local/lib/chronos-gn/chronos-gn-remount.sh` | Short-lived remount helper the monitor calls |
| `~/Library/Logs/chronos-gn/` | All logs |

## Common commands

Update only the helper, monitor, and LaunchAgent, leaving the sparsebundle and destination alone:

```bash
bash bin/chronos-gn --launchagent-only --verbose
```

Set up without encryption, and without starting a backup:

```bash
bash bin/chronos-gn --url "smb://nas.example.com/TimeMachine" --no-encryption --no-start-backup --verbose
```

Check on it:

```bash
tmutil destinationinfo
launchctl print "gui/$(id -u)/io.github.andrewkc98.chronos-gn"
tail -f ~/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log
```

Remove it (dry run first — the sparsebundle is never deleted):

```bash
bash bin/chronos-gn-uninstall --dry-run --verbose
bash bin/chronos-gn-uninstall --verbose
```

## Documentation

| Document | Contents |
|---|---|
| [docs/configuration.md](docs/configuration.md) | Every flag and config key |
| [docs/deployment-guide.md](docs/deployment-guide.md) | Prerequisites, deployment, verification |
| [docs/architecture.md](docs/architecture.md) | Design, component map, remount model |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-based triage |
| [docs/security-considerations.md](docs/security-considerations.md) | Threat model, encryption, credentials |
| [docs/uninstall-guide.md](docs/uninstall-guide.md) | Clean removal with preserve options |
| [docs/migration-from-chronos.md](docs/migration-from-chronos.md) | Upgrading from the pre-3.0 `chronos` tool |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); code must be `shellcheck`-clean and pass `tests/check-generated-assets.sh`. Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
