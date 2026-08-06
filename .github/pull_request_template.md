## What this changes

## Why

## Testing

- macOS version:
- Tested over: SMB / AFP / neither
- [ ] `bash -n` passes on both scripts
- [ ] `shellcheck -S warning bin/*` is clean
- [ ] Initial setup path exercised
- [ ] Reboot or logout/login remount path exercised
- [ ] Uninstall path exercised

If this touches the remount helper or monitor, a reboot test is required. Say explicitly if you could not run one.

## Notes for the reviewer
