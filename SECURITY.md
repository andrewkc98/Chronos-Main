# Security policy

## Reporting a vulnerability

Report privately through GitHub's security advisory flow: open the **Security** tab on this repository and choose **Report a vulnerability**. Please do not open a public issue for a security problem.

Include what you can: affected version, macOS version, reproduction steps, and impact. Expect an initial response within a couple of weeks — this is a personal project, not a staffed one.

## Supported versions

Only the latest release receives fixes.

## What this tool does that you should know about

`chronos-gn` is a privileged installer. Being clear about that is more useful than claiming a small footprint:

- **It uses `sudo`** to write helper scripts into `/usr/local/lib/chronos-gn`, to set ownership on files in your home directory, to load a LaunchAgent, and to run `tmutil setdestination`.
- **It installs a long-running process** in your GUI session that stays alive across logins and periodically calls Finder-backed mount APIs.
- **It handles an encryption password.** The password is read from a TTY prompt or an environment variable, passed to `hdiutil` on stdin, and unset on exit. It is never written to disk or into a log by this tool. macOS may store it in your Keychain if you accept that prompt — which is what makes unattended remounts work.
- **It reads a config file, but never sources it.** The parser is a hand-rolled `KEY=value` reader with an allowlist, specifically because the file may be read under `sudo` and sourcing it would be arbitrary root code execution.
- **It never deletes your sparsebundle.** Not on uninstall, not on migration, not on failure.

## Known limitations

These are design constraints, not bugs — but you should know them before deploying:

- **The helper scripts are executable by the console user.** `HELPER_DIR` is `0750` and owned by that user, and the LaunchAgent runs whatever is at those paths. Anyone who can write to your home directory or that directory can therefore run code in your session. This is inherent to a per-user LaunchAgent.
- **Time Machine over generic SMB is not an Apple-supported configuration.** Apple supports Time Machine to macOS Server, Time Capsule, and vendor-certified NAS devices. A hand-built sparsebundle on an arbitrary share works, and works well, but you are outside the supported path. Test restores.
- **Deletion protection is the server's job.** Anyone who can write to the share can delete the sparsebundle, and with it every backup in it. Use snapshots, ACLs, or a recycle bin on the server side. `chronos-gn` cannot protect against this.
- **Encryption protects the image at rest, not the mounted volume.** While mounted, the backup volume is readable by anyone with access to your session.

See [docs/security-considerations.md](docs/security-considerations.md) for the fuller treatment.
