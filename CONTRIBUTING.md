# Contributing to chronos-gn

Thanks for taking a look. This is a small Bash project with an unusually hostile test environment — it needs a real Mac, a real network share, and a logged-in GUI session — so the bar for review is a bit higher than the line count suggests.

## Before you open a PR

Run the static checks:

```bash
bash -n bin/chronos-gn && bash -n bin/chronos-gn-uninstall
shellcheck -S warning bin/chronos-gn bin/chronos-gn-uninstall tests/*.sh
bash tests/check-generated-assets.sh
```

All three must be clean. CI runs the same checks plus argument- and config-validation smoke tests that need no share.

`tests/check-generated-assets.sh` matters more than it looks: the remount helper, the monitor, and the LaunchAgent plist are all written from heredocs inside `bin/chronos-gn`, so a syntax error in one of them would otherwise stay invisible until someone ran a real install. If you change a heredoc, run it.

## Style

- `#!/bin/bash`, `set -euo pipefail`, `IFS=$'\n\t'` at the top of every script.
- 4-space indent, no tabs. See `.editorconfig`.
- Quote every expansion. `"$var"`, not `$var`.
- Functions are `lower_snake_case`; globals are `UPPER_SNAKE_CASE`.
- Prefer `local var; var="$(cmd)"` over `local var="$(cmd)"` when the exit code matters — the single-line form masks it.
- Comment *why*, not *what*. The existing comments about Finder-vs-`hdiutil` mounting and interrupted `sleep` are the model: they record a decision that looks wrong without the context.

## Testing safely

Never test against a share holding backups you care about. Set up a scratch share and use a small image:

```bash
bash bin/chronos-gn \
  --url "smb://scratch.example.com/test" \
  --destination /Volumes/test \
  --size 10g \
  --name "Test Backups" \
  --label-prefix local.test \
  --helper-dir /usr/local/lib/chronos-gn-test \
  --no-start-backup \
  --verbose
```

The distinct `--label-prefix` and `--helper-dir` keep the test install from colliding with a real one. Clean up with the matching uninstaller flags:

```bash
bash bin/chronos-gn-uninstall \
  --name "Test Backups" \
  --label-prefix local.test \
  --helper-dir /usr/local/lib/chronos-gn-test \
  --dry-run --verbose
```

Then remove the test sparsebundle by hand — the uninstaller never deletes it.

## What to include in a PR

- What you changed and why.
- Which macOS version you tested on, and whether you tested over SMB, AFP, or neither.
- Whether you exercised the reboot/reconnect path, or only the initial setup path. Both matter; say which one you did.

Changes to the remount helper or monitor need a reboot test. That code exists because the obvious implementations did not survive one.

## Reporting bugs

Include the relevant logs, with hostnames and share paths redacted:

- `~/Library/Logs/chronos-gn/chronos-gn.log`
- `~/Library/Logs/chronos-gn/chronos-gn-remount.log`
- `~/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log`

...plus `sw_vers`, your `chronos-gn` version, and `tmutil destinationinfo` output.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
