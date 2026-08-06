# Legacy reference material

**Nothing in this folder is maintained, and nothing here should be run.**

These files are the pre-3.0 `chronos` project, kept because they document how the current design was arrived at. They describe an install layout that `chronos-gn` no longer uses: the `com.<user>.chronos` LaunchAgent, `/usr/local/lib/chronos`, and `/tmp/chronos.log`.

If you are upgrading from that install, read [../docs/migration-from-chronos.md](../docs/migration-from-chronos.md) instead. `chronos-gn` detects a legacy install and offers to migrate it.

| File | What it is |
|---|---|
| `chronos_refactor_annotated_v2.2.1.sh` | Heavily commented teaching copy of the v2.2.1 installer. Functionally equivalent to the v2.2.1 script apart from a commented-out default. Useful for understanding the design; **not** a maintained script. |
| `original-readme-notes.md` | The original project README, written for a single machine on a single LAN. |
| `original-change-documentation.md` | Notes recorded during the v2.x refactor. |
| `change-summary-v2.2.1.md` | The v2.1.1 → v2.2.1 change summary, superseded by [../CHANGELOG.md](../CHANGELOG.md). |

Running the annotated script would install the old `com.<user>.chronos` LaunchAgent alongside `chronos-gn` and leave two remount monitors fighting over the same sparsebundle. Don't.
