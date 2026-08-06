# chronos-gn Security Considerations

## Security objective

chronos-gn improves backup setup reliability, but it is not a complete backup security control by itself. It should be paired with NAS/server-side protections, credential hygiene, monitoring, and recovery testing.

## Assets

| Asset | Why it matters |
|---|---|
| Sparsebundle contents | Contains user backup data |
| Encryption password | Protects backup confidentiality |
| SMB/AFP credentials | Grants access to backup share |
| MachineID metadata | Associates backup with device identity |
| LaunchAgent/helper scripts | Persistent user-session automation |
| Logs | May reveal hostnames, paths, and failure states |

## Encryption

chronos-gn enables AES-256 sparsebundle encryption by default.

Encryption protects backup confidentiality if the sparsebundle is copied or accessed without the password.

Encryption does **not** protect against deletion of the sparsebundle, ransomware corrupting accessible backups, compromise of the logged-in user session, or compromise of saved Keychain credentials.

## Credential handling

Recommendations:

- Prefer Keychain over hardcoded credentials.
- Do not store real passwords in scripts or Git repositories. The config-file parser rejects an `ENCRYPTION_PASSWORD` key outright for this reason.
- Avoid exporting `CHRONOS_GN_ENCRYPTION_PASSWORD` permanently in shell profiles.
- Use environment-variable password injection only for controlled automation/testing.
- Review logs before sharing.

## LaunchAgent persistence risk

chronos-gn installs persistent user-session automation under:

```text
~/Library/LaunchAgents/<label-prefix>.chronos-gn.plist
/usr/local/lib/chronos-gn/chronos-gn-remount.sh
/usr/local/lib/chronos-gn/chronos-gn-remount-monitor.sh
```

The LaunchAgent runs whatever is at those paths, in your GUI session, at every login. Anyone who can write to `HELPER_DIR` or to your `~/Library/LaunchAgents` can therefore run code as you. `HELPER_DIR` is created `0750` and owned by the console user, which is the strongest guarantee a per-user LaunchAgent can offer.

Controls:

- Restrict helper directory permissions.
- Ensure helper scripts are owned by the intended user/group.
- Keep helper content readable and documented.
- Provide a clean uninstall script.
- Avoid running arbitrary downloaded versions without review.

## Config file handling

The config file is parsed by a hand-rolled `KEY=value` reader, never sourced. This matters because `chronos-gn` escalates to root during install: sourcing a config file under `sudo` would make anything writable to that file equivalent to root code execution. Keys are allowlisted, values are never expanded, and a group- or world-writable config file produces a warning.

`chmod 600` your config file, and keep it out of version control — the shipped `.gitignore` excludes `config` and `chronos-gn.conf`.

## Log file handling

The main log defaults to `~/Library/Logs/chronos-gn/chronos-gn.log`, in a `0700` directory. Earlier versions used `/tmp/chronos.log`: a predictable path in a world-writable directory, truncated by a script that then calls `sudo`, which any local user could pre-create as a symlink. `chronos-gn` now refuses a log path that is a symlink, and refuses a *default* log path inside a world-writable directory unless `--log-file` is passed explicitly.

Logs contain hostnames, share paths, computer names, and MAC-derived sparsebundle names. They never contain the encryption password. Review before sharing.

## Backup deletion protection

Recommended controls:

- NAS snapshots
- immutable snapshot retention where available
- separate backup-only service account
- least-privilege share permissions
- restricted delete rights if operationally possible
- recycle bin/versioning on the share
- periodic restore tests
- monitoring for sparsebundle deletion or rapid band-file modification

## Security review checklist

- [ ] No credentials hardcoded in scripts.
- [ ] Internal hostnames sanitized before public sharing.
- [ ] Config file is `chmod 600` and not committed.
- [ ] Encryption enabled unless documented exception exists.
- [ ] NAS/server-side deletion protection configured.
- [ ] LaunchAgent path and helper ownership verified.
- [ ] Logs reviewed before sharing.
- [ ] Restore test completed.
- [ ] Uninstall process tested.
