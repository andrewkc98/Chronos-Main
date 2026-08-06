> This is the original change documentation walkthrough comparing Chronos 1.5 to the v2.0+ refactor.
> Retained as a reference for understanding the architectural reasoning behind the refactor.
> Author: Andrew Tucker
---

How to read this walkthrough
I'm going in the order that makes the most sense for understanding:

1.  bootstrap and globals
2.  utility functions
3.  validation and context building
4.  network mount flow
5.  sparsebundle creation/copy
6.  MachineID plist
7.  sparsebundle mount logic
8.  Time Machine config
9.  LaunchAgent helper + plist
10. first backup + summary
11. how this compares architecturally to 1.5

Each section covers four parts:
- what it does
- what 1.5 did instead
- why the refactor changed it
- why that change is better in practice

---

1. Script bootstrap and global structure

Refactor: sets strict shell behavior (set -euo pipefail, IFS=$'\n\t'), then defines a large block of globals — immutable metadata (SCRIPT_NAME, VERSION), config defaults (SIZE, FILESYSTEM, DESTINATION, NETWORK_URL), feature flags (SETUP_LAUNCHAGENT, START_FIRST_BACKUP, ENABLE_ENCRYPTION), runtime state (CONSOLE_USER, BUNDLE_PATH, IMAGE_DEVICE, RUN_SUCCEEDED), and summary state.

Chronos 1.5: does strict shell setup too, then defines fewer globals and mostly populates variables as it goes. Part function-based, part top-level imperative code.

Why changed: turning this into a deployment-grade script means known defaults up front, known runtime state variables, a place to track status/results, and a cleaner separation between configuration and execution.

Why better: front-loads state so later functions can assume those variables exist. The script needs to remember who the real console user is, where the bundle should live, whether the bundle was mounted during this run, whether cleanup should detach anything, and whether the script reused or created a new bundle.

---

2. usage()

Refactor: prints a structured help block with grouped options (core options, behavior toggles, environment variable info).

Chronos 1.5: simpler usage line inside the -h option handler.

Why changed/better: the refactor introduces many more flags and long options. This moves the script closer to a real admin CLI tool.

---

3. Logging stack: timestamp(), log(), info(), warn(), error(), die()

Refactor: small logging framework — timestamp() formats log time, log(level, message) writes to log file and optionally stderr, wrappers: info, warn, error, die() logs an error and exits.

Behavior: all logs go to configured log file; warnings/errors always print; verbose/debug also prints info messages to stderr.

Chronos 1.5: one log() function writing to /tmp/chronos.log, echoes to stdout only when DEBUG=1.

Why better: severity is explicit; logs are easier to grep; die() centralizes fatal exit behavior.

---

4. Error trap and cleanup: on_error() and cleanup()

on_error(): captures exit code and line number, logs "Command failed at line X with exit code Y".

cleanup(): runs on exit and handles several states — if the script mounted a sparsebundle during this run and the run failed, try to detach it; remove temp sparsebundle; remove temp directory; unset encryption password; log success or failure.

Chronos 1.5: cleanup only removes the temp sparsebundle from /tmp and logs a generic cleanup message. ERR trap only logs that the script exited with error.

Why better: real production improvement. In 1.5, if attach succeeds and something later fails, the image may stay mounted. The refactor tries to unwind the mount if it was created during the failed run.

---

5. Privilege/session wrappers: run_as_root() and run_in_console_user_context()

run_as_root(): runs the command directly if already root, else via sudo.

run_in_console_user_context(): runs in the logged-in GUI user's context when needed. If root is running the script, uses launchctl asuser and sudo -u to execute as the actual console user.

Chronos 1.5: mostly uses sudo inline and sets USERNAME="${SUDO_USER:-$(whoami)}". Workable, but not precise about the GUI session owner.

Why better: macOS-specific best practice. Some actions need privilege; some actions need the actual logged-in user session. Critical for SMB mounting via Finder/open, LaunchAgent install/load, and anything depending on Aqua session behavior.

---

6. General utility helpers: retry(), is_mountpoint(), wait_for_mountpoint(), confirm_action()

retry(attempts, delay, cmd...): retries a command multiple times with delay and warning logs.
is_mountpoint(target): uses mount | awk to determine if a path is mounted.
wait_for_mountpoint(target, timeout): polls until the mountpoint exists or timeout expires.
confirm_action(prompt): interactive confirmation unless --yes is set; returns failure if no TTY.

Chronos 1.5: behaviors implemented ad hoc — explicit while loops for waiting, direct mount | grep, no general retry, no confirm function.

Why better: when the same script waits for share mount, waits for sparsebundle mount, and retries after flaky network behavior, a reusable retry/wait pattern keeps behavior consistent.

---

7. Argument parser: parse_args()

Refactor: parses both short and long options. Adds --no-launchagent, --launch-interval, --no-start-backup, --force-clean-partial, --password-env, --log-file, --debug.

Chronos 1.5: uses getopts "s:d:f:u:e:n:h" with short flags only.

Why better: lets you use the same tool for initial setup, quiet reruns, debugging, automation, and partial recovery.

---

8. Validation subsystem: require_command(), validate_*(), validate_setup()

require_command(): verifies binaries exist in PATH.
validate_size(): allows unit-suffixed values like 500g or 2t, rejects malformed sizes.
validate_filesystem(): whitelists supported filesystem strings.
validate_destination(): rejects dangerous or invalid targets (not absolute, /, /Volumes).
validate_launch_interval(): ensures positive integer.
validate_url(): ensures smb:// or afp:// shape, extracts host, determines port.
validate_setup(): calls all above and checks log directory is writable.

Chronos 1.5: required command loop, size format validation (g suffix only), no destination safety validation, no URL parsing.

Why better: prevents avoidable operational mistakes. Rejecting /Volumes as a destination is exactly the kind of guardrail IT would appreciate.

---

9. prepare_context()

Refactor: builds the runtime identity and path model — actual console user from /dev/console, UID/group/home, computer name, hardware UUID, primary MAC from en0 or en1, normalized bundle name/path, MachineID plist path, staging bundle path, LaunchAgent label/path, helper script path, log directory, expected mounted image path, unique temp dir via mktemp -d.

Chronos 1.5: get_system_info() gathers a subset; uses fixed temp path /tmp/$BUNDLE_NAME.

Why better: centralizes all environment-derived variables before any stateful operations. Upgrades temp handling from a fixed path to a unique temp workspace, reducing collision/stale-state bugs.

---

10. Network mount preparation: warn_if_host_unreachable()

Refactor: before trying to mount, checks whether the share host/port is reachable with nc. If not, warns but does not hard-fail.

Chronos 1.5: no preflight reachability check before open "$URL".

Why better: good operator UX — early warning that the NAS may not be reachable, while still allowing a mount attempt.

---

11. Network mount logic: path_is_accessible(), mount_network_share_once(), mount_network_share()

path_is_accessible(): checks that a path exists and can be listed with ls -ld.

mount_network_share_once(): handles three cases — already mounted and accessible (success), mountpoint exists but not truly reachable (warn and reconnect), not mounted (request mount via open in console user context, wait, verify accessibility).

mount_network_share(): runs preflight host warning, then retries 3 times with delay.

Chronos 1.5: checks mount | grep, uses open "$URL", waits, either succeeds or fails once.

Why better: distinguishes "mounted" from "usable" for SMB shares. The mountpoint may exist but the SMB path may not actually be usable. The refactor distinguishes those states.

---

12. Encryption password path: get_encryption_password()

Refactor: checks ENCRYPTION_PASSWORD, else checks the configured environment variable, else prompts interactively if a TTY exists, requires confirmation, stores the chosen password in runtime state.

Chronos 1.5: handle_encryption() only does interactive prompting.

Why better: supports noninteractive use. More enterprise-friendly because you can drive the setup without being physically present at the prompt.

---

13. Sparsebundle validation helpers: validate_local_sparsebundle_image(), validate_sparsebundle_structure()

validate_local_sparsebundle_image(): uses hdiutil imageinfo; if encrypted, can pass the password via stdin.

validate_sparsebundle_structure(): checks that path is a directory, Info.plist/bands/token structure is present, warns for missing pieces but allows mount step to be the final validation.

Chronos 1.5: mainly verifies bundle creation by checking whether the temp bundle directory exists after hdiutil create.

Why better: "directory exists" is a much weaker signal than "this looks like a usable sparsebundle image."

---

14. Partial-state handling: handle_partial_state() and copy_bundle_to_share()

handle_partial_state(): if a staging bundle already exists at .${BUNDLE_NAME}.partial — warn, remove automatically if forced, or prompt, or abort safely.

copy_bundle_to_share(): (1) handle existing partial bundle, (2) copy local temp bundle to staging path, (3) validate staging structure, (4) promote staging path to final path with mv, (5) if move status is ambiguous, re-check filesystem state and retry if needed, (6) validate final path, (7) clean any leftover staging path.

Chronos 1.5: directly uses sudo mv "$TMP_BUNDLE" "$DEST_PATH", applies chown/chmod, waits, checks whether destination exists.

Why better: the staging/promote pattern means the final production bundle path is not exposed until copy is mostly complete, and partial/incomplete data is isolated in a hidden "partial" path that reruns can detect and clean.

---

15. Sparsebundle creation: create_sparsebundle()

Refactor: checks if final bundle already exists — if yes, validates structure, marks summary as reused, skips creation. If no, creates locally in temp workspace, validates local image, copies to share using staging flow, cleans temp bundle, marks summary as created-new.

Chronos 1.5: checks if final bundle exists and skips if yes; otherwise creates in /tmp; checks directory exists.

Why better: genuinely idempotent and safer on network storage.

---

16. Machine identity plist: write_machine_id_plist()

Refactor: creates a new temporary plist via heredoc, copies it into the sparsebundle as com.apple.TimeMachine.MachineID.plist, verifies it exists, sets mode 0644.

Chronos 1.5: uses PlistBuddy to delete and re-add the keys in place.

Why better: generating the desired content is cleaner than mutating it for a tiny, deterministic file. Fewer mutation steps, less brittle logic, easier to audit.

---

17. Existing mount detection: get_existing_mount_for_image(), device_for_mount_point(), detach_image_mount()

get_existing_mount_for_image(): parses hdiutil info -plist to determine whether this exact sparsebundle is already attached and where it is mounted.

Chronos 1.5: only cares whether the expected mountpoint appears under /Volumes/$NAME.

Why better: disk images may already be attached in ways that do not perfectly match the expected mount path. This avoids duplicate attach attempts and improves recovery behavior.

---

18. Sparsebundle mount path: mount_sparsebundle_once() and mount_image()

mount_sparsebundle_once(): checks (1) expected mount point already present, (2) same image already attached elsewhere, (3) otherwise requests mount using open "$BUNDLE_PATH" in the console user's session, (4) waits for expected or actual mountpoint, (5) records device and marks that this run mounted the image.

mount_image(): verifies bundle path exists, then retries mount_sparsebundle_once() up to 3 times. If encrypted, error message reminds operator about Keychain/password prompt state.

Chronos 1.5: uses open "$BUNDLE_PATH", a wait loop, success/fail based on expected mountpoint presence.

Why better: if the image is already mounted, the refactor treats that as valid state instead of trying to remount blindly.

---

19. Time Machine config: tm_destination_info(), tm_destination_matches_path(), tm_destination_matches_name(), configure_tm()

configure_tm(): if exact path already registered, do nothing; if same name exists but different path, warn; else run tmutil setdestination -a; verify the path now appears in destinationinfo.

Chronos 1.5: checks destination info for the mount point and sets the destination if missing.

Why better: more careful and more clearly idempotent.

---

20. Atomic file install: write_file_atomically()

Refactor: writes content to a temp file in the temp workspace, then installs it into place with the specified mode via install -m.

Chronos 1.5: writes helper files directly with heredocs.

Why better: avoids half-written helper files or plists if the run is interrupted. Mature automation technique especially good for LaunchAgent and helper script files.

---

21. LaunchAgent install: setup_launchagent()

Refactor: respects --no-launchagent, escapes strings for AppleScript, creates helper and log directories with correct ownership/mode, writes a shell helper script, writes a LaunchAgent plist, sets ownership, performs launchctl bootout/bootstrap/kickstart in the actual console user GUI domain, updates summary status.

Chronos 1.5: creates /usr/local/lib/chronos, writes an AppleScript helper, writes a LaunchAgent plist, unloads/bootstrap/kickstarts the plist.

Why better: shell helper scripts are easier to debug than pure .scpt; atomic install and ownership handling are safer; using gui/${CONSOLE_UID} is more correct than relying on current shell UID.

---

22. The embedded remount helper script

What it does: the refactor writes a helper shell script that the LaunchAgent runs periodically. That helper logs to a dedicated Chronos log directory, checks if the share path is mounted and reachable, verifies the sparsebundle path exists and looks sane, checks if the volume is already mounted, checks if the bundle is already attached, attempts mount using multiple methods (DiskImageMounter via Launch Services → plain open fallback → hdiutil attach fallback), retries several times, confirms final mount state or logs a useful warning.

How 1.5 did this: an AppleScript that checked the host with nc, mounted the SMB volume, waited, and attached the sparsebundle with hdiutil attach if present.

Why better: substantial improvement in maintainability and troubleshooting. Structured logs, multiple fallback paths, better distinction between "share unavailable," "bundle path unavailable," and "image not attaching."

---

23. The new LaunchAgent plist itself

Refactor plist: Label, ProgramArguments calling /bin/bash on the helper, RunAtLoad, LimitLoadToSessionType = Aqua, StartInterval, StartOnMount, stdout/stderr log paths.

Chronos 1.5 plist: ProgramArguments calling /usr/bin/osascript, RunAtLoad, KeepAlive with NetworkState, StartInterval, stdout/stderr paths.

Why better: LimitLoadToSessionType Aqua makes the user-session intent explicit. StartOnMount is useful for reacting to mount-related changes. The helper itself now handles network/share/path conditions rather than depending on KeepAlive semantics alone.

---

24. start_first_backup()

Refactor: optionally starts the first backup automatically, marks summary state as started/already-running/skipped, treats "backup already in progress" as nonfatal.

Chronos 1.5: tells the user to start the first backup manually.

Why better: operational polish. Closes the loop.

---

25. print_summary()

Refactor: structured final summary — sparsebundle path, whether it was reused or created, image mount point, LaunchAgent status, backup start status, log file path, encryption note if relevant.

Chronos 1.5: no structured end summary.

Why better: very useful for admin validation, documentation screenshots, ticket notes, and future troubleshooting.

---

26. main()

Refactor: the orchestrator — parse args, verify log dir/write access, initialize log, validate setup, prepare context, log key runtime facts, run the workflow, print summary, mark run success.

Chronos 1.5: main() only covers the earlier phase, then the remainder of the script continues in global scope.

Why better: cleaner software structure. main() now tells the whole story.

---

27. The biggest mindset shift from 1.5 to the refactor

1.5 was written as: "perform the setup steps successfully."

The refactor is written as: "perform the setup safely, repeatedly, and recoverably under imperfect real-world conditions."

Most of the new complexity handles more states: mounted vs reachable, existing vs partial bundle, attached vs mounted image, root vs console user, interactive vs noninteractive password input, initial install vs rerun, successful run vs failed run cleanup.

---

28. Design lessons from this refactor

1. Validate before mutating — reject bad inputs before touching disks, network mounts, or LaunchAgents.
2. Build context once — determine user, UID, paths, and machine identity up front.
3. Make reruns safe — idempotent scripts are much more valuable than one-shot scripts.
4. Stage before promote — never write complex artifacts directly into their final network location if partial copy is possible.
5. Separate privilege from session context — on macOS especially, root and GUI user are not interchangeable.
6. Treat detection as more than existence — a mounted path is not always an accessible path.
7. Write helpers atomically — partially written plists and helper scripts are a common source of weird failures.
8. Track state for cleanup — you can only clean up correctly if you know what the current run actually changed.
