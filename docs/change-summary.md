# Chronos Change Summary

## Current version

This artifact pack is based on `chronos_refactor.sh` **v2.2.1**.

The uploaded annotated script was an older v2.1.1 teaching copy. This pack includes a refreshed annotated copy (`chronos_refactor_annotated_v2.2.1.sh`) generated from the current v2.2.1 script so comments align with the latest remount architecture.

## Major improvements in v2.2.1

### LaunchAgent-only mode

```bash
--launchagent-only
```

Updates remount helper, monitor, and LaunchAgent assets without touching the sparsebundle or Time Machine destination.

### Persistent remount monitor

The remount system now uses a two-script model:

```text
chronos-remount-monitor.sh    Long-running LaunchAgent process in the Aqua user session
chronos-remount.sh            Short-lived helper called by the monitor
```

The monitor stays alive in the Aqua session and calls the helper repeatedly on a controlled sleep loop. This replaces the older `StartInterval`-only behavior, which proved unreliable in this workflow.

### Popup suppression when off-network

The helper checks host reachability before GUI mount calls. If the host is unreachable, it logs and exits cleanly rather than triggering Finder connection dialogs.

### Other improvements

- Lock directory to avoid duplicate remount checks
- Interrupted sleep hardening for wake/signal behavior
- DiskImageMounter / Launch Services preference with `hdiutil attach -agentpass` fallback
- Clearer split between setup, monitor, and helper responsibilities

## v2.1.1 → v2.2.1 alignment note

The previous annotated file described a v2.1.1 LaunchAgent flow based on short-lived helper execution and `StartInterval`. Documentation and the annotated script have been updated to reflect the v2.2.1 persistent monitor/remount-helper model. The main script (`chronos_refactor.sh`) is the source of truth for all behavioral details.
