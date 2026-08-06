
---

Chronos - Time Machine Sparsebundle Automation
Target platform: Apple Inc. macOS (11 / Big Sur+)

Overview
Chronos is a production-ready Bash automation script that creates, configures, and manages a Time Machine-compatible sparsebundle on an SMB network share. It registers the mounted sparsebundle as a Time Machine destination and installs a user LaunchAgent-based remount system that keeps the share and sparsebundle available after login and later reconnect events.

Logs can be found in:
/tmp/chronos.log
~/Library/Logs/Chronos

As of v2.2.1, Chronos uses a conservative two-part remount design:
Production-grade shell orchestration for validation, retries, cleanup, and logging
A persistent Aqua-session monitor under launchd that runs the remount helper immediately at login and then on a controlled sleep loop
macOS-native mounting behavior for SMB shares and sparsebundles, preferring Launch Services and DiskImageMounter before falling back to hdiutil

This design avoids relying on an observed-unreliable LaunchAgent StartInterval timer while preserving unattended remount behavior for Time Machine over SMB.

Key problems this script solves:
Automates creation and naming of a per-machine sparsebundle to prevent backup collisions
Ensures Time Machine metadata is correctly set with HardwareUUID and MachineName
Uses macOS-native mounting behavior for Time Machine compatibility over SMB
Automates remounting after login and reconnect windows without manual launchctl kickstart
Supports AES-256 encryption enabled by default
Provides structured logging, validation, retry handling, and cleanup
Supports idempotent re-runs and safe reuse of an existing sparsebundle

Quick safety summary:
Encryption protects backup contents, not deletion of the sparsebundle
Deletion protection must be implemented at the NAS level with ACLs or snapshots
Encryption is enabled by default and can be disabled with --no-encryption
macOS Keychain prompts on first SMB or encrypted image access are expected and recommended
The remount helper is idempotent and avoids destructive action when the share or sparsebundle is already mounted

Prerequisites:
macOS 11+
Admin privileges
A reachable SMB share with write permissions

What the script does (step-by-step):
Validates environment and required tools
Mounts the SMB share using macOS-native open
Gathers system identifiers such as ComputerName, MAC address, and hardware UUID
Constructs a unique sparsebundle name
Prompts for an encryption password if encryption is enabled and no environment-provided password is available
Creates the sparsebundle locally in temporary staging
Stages and promotes the sparsebundle to the SMB share
Writes com.apple.TimeMachine.MachineID.plist metadata
Mounts the sparsebundle using native macOS behavior
Detects the mounted image under /Volumes
Registers the mounted image as a Time Machine destination via tmutil
Installs the remount helper, persistent monitor, and LaunchAgent
Initiates the first backup unless disabled
Logs actions to /tmp/chronos.log and remount activity to ~/Library/Logs/Chronos

LaunchAgent and remount architecture (v2.2.1):
Earlier versions used a short-lived LaunchAgent job with RunAtLoad, StartInterval, and GUI-oriented mount calls. In testing, the helper itself proved healthy, but repeated automatic invocation on the LaunchAgent timer was not dependable in the active user session.

Chronos now installs:
/usr/local/lib/chronos/chronos-remount.sh
/usr/local/lib/chronos/chronos-remount-monitor.sh
~/Library/LaunchAgents/com.USER.chronos.plist

How the new remount flow works:
launchd starts one persistent monitor in the logged-in Aqua session at login
The monitor runs the helper immediately, then sleeps for the configured interval and runs it again
The helper remains one-shot and idempotent
If the SMB share is already mounted and reachable, nothing destructive happens
If the sparsebundle volume is already mounted, nothing happens
If the share is disconnected, the helper requests a remount
If the share is mounted but the sparsebundle is not, the helper attempts to mount the sparsebundle
A lock directory prevents overlapping helper runs

Mount method order for automatic remounts:
DiskImageMounter via Launch Services
plain open fallback
hdiutil attach fallback

Finder automation is intentionally no longer used for the background remount path because it can produce permission or automation-context failures when triggered from a background LaunchAgent.

Design principle:
Automate orchestration, not macOS internals.

Usage:
bash chronos_refactor.sh (options)

Options
-s, --size SIZE
Sparsebundle size, for example 1000g or 2t

-d, --destination PATH
Expected mounted network share path
Default: /Volumes/TimeMachine

-f, --filesystem FS
Filesystem inside the sparsebundle
Supported values:
APFS
Case-sensitive APFS
Journaled HFS+
Case-sensitive Journaled HFS+

-u, --url URL
SMB or AFP URL used to mount the share
Default: smb://server.local/TimeMachine 

-n, --name NAME
Mounted backup volume name
Default: Time Machine Backups

--no-encryption
Create the sparsebundle without AES-256 encryption

--password-env VAR
Environment variable containing the encryption password
Default: CHRONOS_ENCRYPTION_PASSWORD

--no-launchagent
Skip LaunchAgent, helper, and monitor installation

--launchagent-only
Update only the LaunchAgent, remount helper, and monitor assets

--launch-interval SECONDS
Remount recheck interval used by the persistent monitor
Default: 300

--no-start-backup
Skip starting the first backup after setup

--force-clean-partial
Remove known partial sparsebundle state without prompting

-y, --yes
Auto-confirm destructive cleanup prompts

-v, --verbose
Print INFO and WARN logs to stdout

--debug
Enable debug logging

--log-file PATH
Override the main setup log file path

-h, --help
Show help

Examples
Create a 1 TB encrypted bundle:
bash chronos_refactor.sh -s 1000g

Use a custom SMB share and custom volume name:
bash chronos_refactor.sh -u "smb://nas.example.com/Backups" -d /Volumes/Backups -n "Time Machine Backups"

Update only the LaunchAgent, helper, and monitor:
bash chronos_refactor.sh --launchagent-only -d /Volumes/TimeMachine -u smb://server.local/TimeMachine -n "Time Machine Backups" -v

Use an environment variable for the encryption password:
CHRONOS_ENCRYPTION_PASSWORD='example-password' bash chronos_refactor.sh

Installation / Deployment notes
Installs helper files in: /usr/local/lib/chronos
Installs LaunchAgent: ~/Library/LaunchAgents/com.USER.chronos.plist
Designed to run as the logged-in user for Keychain and Aqua-session compatibility

Security considerations:
Do not embed credentials in SMB URLs
Prefer Keychain storage via native macOS prompts
Encryption passwords are cleared from memory after use in the main setup flow
NAS-level protection is still required for deletion safety
Encrypted sparsebundles may require the password to be stored in Keychain for unattended remounts

Changelog
v1.0 - Initial automation prototype
v1.2 - Cleanup, logging, and debug functions added. Script no longer hardcoded. Options for sparsebundle size, file system, destination, and share location added.
v1.3 - Adjusted logging checks so proper logging persisted. Confirmation output improved. Sparsebundle move verification added.
v1.4 - Updated plist and AppleScript so network changes no longer created constant popups. Added recurring trigger behavior and logging for the remount path.
v1.5 - Added initial share mount at the beginning of the script, removing the need to mount before running the script. Encryption enabled by default. Expanded logging for easier debugging and failure detection.
v2.0 - Full refactor with production structure for logging, validation, and retries
v2.1.0 - Restored Time Machine compatibility over SMB, replaced forced hdiutil attach with native open mount, improved sparsebundle handling and validation, and stabilized the full backup workflow
v2.2.0 - Replaced the unreliable timer-driven short-lived LaunchAgent with a persistent Aqua-session monitor, added the launchagent-only update mode, added helper locking to prevent overlap, and changed automatic sparsebundle remounts to prefer DiskImageMounter and Launch Services over Finder automation

Contact

