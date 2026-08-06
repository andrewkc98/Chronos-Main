# Chronos: macOS Time Machine Sparsebundle Automation

Chronos is a Bash-based macOS administration tool that automates Time Machine backup setup to a network-hosted sparsebundle. It creates or reuses a per-machine sparsebundle on an SMB/AFP share, writes Time Machine machine metadata, mounts the sparsebundle, registers it with Time Machine, and installs a LaunchAgent-backed persistent remount monitor.



---

## What it demonstrates

- macOS administration with `launchd`, LaunchAgents, `tmutil`, `hdiutil`, DiskImageMounter, and Launch Services
- Network backup automation over SMB/AFP
- Bash scripting with strict mode, validation, retries, cleanup, and structured logging
- Operational awareness around GUI session context vs root context
- Security thinking around encrypted backups, SMB credentials, Keychain behavior, and NAS-side deletion protection

---

## Documentation

| File | Description |
|---|---|
| [[docs/architecture]] | System design, component map, v2.2.1 remount model |
| [[docs/deployment-guide]] | Prerequisites, deployment commands, verification steps |
| [[docs/troubleshooting]] | Symptom-based triage, common mistakes |
| [[docs/security-considerations]] | Assets, encryption, credential handling, LaunchAgent risks |
| [[docs/uninstall-guide]] | Clean removal with preserve options |
| [[docs/change-summary]] | What changed from v2.1.1 → v2.2.1 |
| [[docs/publication-sanitization-checklist]] | Pre-publish sanitization checklist |

---

## Source

Scripts and original documentation are stored in [[source/]]. See the source folder note for sanitization requirements before any public release.

---

## High-level behavior (v2.2.1)

1. Validates commands, CLI arguments, filesystem, destination path, URL, and launch interval.
2. Discovers the active macOS console user, home directory, computer name, hardware UUID, and primary MAC address.
3. Builds a unique sparsebundle name using the computer name and MAC address.
4. Mounts the configured network share.
5. Creates or reuses the sparsebundle.
6. Writes `com.apple.TimeMachine.MachineID.plist` into the sparsebundle.
7. Mounts the sparsebundle volume.
8. Registers the mounted volume as a Time Machine destination.
9. Installs a LaunchAgent, remount helper, and **persistent monitor** (v2.2.1 model).
10. Optionally starts the first Time Machine backup.

---

## Default paths and values

| Setting | Default |
|---|---|
| Sparsebundle size | `2000g` |
| Filesystem | `APFS` |
| Network URL | `smb://backup-server.example.local/TimeMachine` |
| Mounted share path | `/Volumes/TimeMachine` |
| Sparsebundle volume name | `Time Machine Backups` |
| Helper directory | `/usr/local/lib/chronos` |
| Main log | `/tmp/chronos.log` |
| LaunchAgent logs | `~/Library/Logs/Chronos` |

---

## Basic usage

```bash
bash chronos_refactor.sh --verbose
```

Custom values:

```bash
bash chronos_refactor.sh \
  --url "smb://backup-server.example.local/TimeMachine" \
  --destination "/Volumes/TimeMachine" \
  --size 2000g \
  --filesystem APFS \
  --name "Time Machine Backups" \
  --verbose
```

Update only remount assets:

```bash
bash chronos_refactor.sh --launchagent-only --verbose
```

---
