# Chronos Security Considerations

## Security objective

Chronos improves backup setup reliability, but it is not a complete backup security control by itself. It should be paired with NAS/server-side protections, credential hygiene, monitoring, and recovery testing.

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

Chronos enables AES-256 sparsebundle encryption by default.

Encryption protects backup confidentiality if the sparsebundle is copied or accessed without the password.

Encryption does **not** protect against deletion of the sparsebundle, ransomware corrupting accessible backups, compromise of the logged-in user session, or compromise of saved Keychain credentials.

## Credential handling

Recommendations:

- Prefer Keychain over hardcoded credentials.
- Do not store real passwords in scripts or Git repositories.
- Avoid exporting `CHRONOS_ENCRYPTION_PASSWORD` permanently in shell profiles.
- Use environment-variable password injection only for controlled automation/testing.
- Review logs before sharing.

## LaunchAgent persistence risk

Chronos installs persistent user-session automation under:

```text
~/Library/LaunchAgents/com.<user>.chronos.plist
/usr/local/lib/chronos/chronos-remount.sh
/usr/local/lib/chronos/chronos-remount-monitor.sh
```

Controls:

- Restrict helper directory permissions.
- Ensure helper scripts are owned by the intended user/group.
- Keep helper content readable and documented.
- Provide a clean uninstall script.
- Avoid running arbitrary downloaded versions without review.

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
- [ ] Encryption enabled unless documented exception exists.
- [ ] NAS/server-side deletion protection configured.
- [ ] LaunchAgent path and helper ownership verified.
- [ ] Logs reviewed before sharing.
- [ ] Restore test completed.
- [ ] Uninstall process tested.
