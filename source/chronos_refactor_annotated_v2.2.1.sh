#!/bin/bash
# =================================================================================================
# Chronos Refactor 2.2.1 - Annotated Review Copy
# Author: Andrew Tucker
# Description: Automated Time Machine Setup including sparsebundle creation, configuration, and autoconnection
# Usage: bash chronos_refactor.sh [-h HELP]
# -------------------------------------------------------------------------------------------------
#
# This annotated copy should not be used for deployment. Please use chronos_refactor.sh as source.
# This annotated copy is generated from the current chronos_refactor.sh source.
# The logic is intentionally preserved; added comments explain purpose, risk,
# and operational behavior for handoff, review, and portfolio documentation.
# Primary source of truth: chronos_refactor.sh v2.2.1.

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.2.1"

# -----------------------------------------------
# Script Metadata & Defaults
# -----------------------------------------------
DEBUG=0
VERBOSE=0
ASSUME_YES=0
SETUP_LAUNCHAGENT=1
LAUNCHAGENT_ONLY=0
START_FIRST_BACKUP=1
ENABLE_ENCRYPTION=1
FORCE_CLEAN_PARTIAL=0
LAUNCH_INTERVAL=300
SIZE="2000g"
FILESYSTEM="APFS"
DESTINATION="/Volumes/TimeMachine"
# NETWORK_URL="smb://server.local/TimeMachine"
VOLUME_NAME="Time Machine Backups"
HELPER_DIR="/usr/local/lib/chronos"
LOG_FILE="/tmp/chronos.log"
PASSWORD_ENV_VAR="CHRONOS_ENCRYPTION_PASSWORD"
ENCRYPTION_PASSWORD=""

CONSOLE_USER=""
CONSOLE_UID=""
CONSOLE_GROUP=""
CONSOLE_HOME=""
COMPUTER_NAME=""
HARDWARE_UUID=""
PRIMARY_MAC=""
BUNDLE_NAME=""
BUNDLE_PATH=""
TMP_DIR=""
TMP_BUNDLE=""
STAGING_BUNDLE=""
MACHINE_ID_PLIST=""
LAUNCH_AGENT_LABEL=""
LAUNCH_AGENT_PATH=""
HELPER_SCRIPT_PATH=""
MONITOR_SCRIPT_PATH=""
LAUNCH_LOG_DIR=""
SHARE_HOST=""
SHARE_PORT=""
IMAGE_DEVICE=""
IMAGE_MOUNT_POINT=""
EXPECTED_IMAGE_MOUNT_POINT=""
EXISTING_IMAGE_MOUNT=0
MOUNTED_IMAGE_IN_RUN=0
TEMP_BUNDLE_CREATED=0
RUN_SUCCEEDED=0
SUMMARY_BACKUP_STATUS="not-requested"
SUMMARY_LAUNCHAGENT_STATUS="not-requested"
SUMMARY_BUNDLE_STATUS="unknown"

# -----------------------------------------------
# Usage
# -----------------------------------------------
# -----------------------------------------------------------------------------
# usage()
# Prints grouped CLI help for installation, behavior toggles, logging, and encryption environment variables.
# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: chronos_refactor.sh [options]

Core options:
  -s, --size SIZE                 Sparsebundle size, e.g. 2000g
  -d, --destination PATH          Mounted network share path, e.g. /Volumes/TimeMachine
  -f, --filesystem FS             APFS, Case-sensitive APFS, Journaled HFS+, or Case-sensitive Journaled HFS+
  -u, --url URL                   smb:// or afp:// URL used to mount the share
  -n, --name NAME                 Backup volume name inside the sparsebundle
      --no-encryption             Create the sparsebundle without AES-256 encryption
      --password-env VAR          Environment variable containing the encryption password

Behavior:
      --no-launchagent            Skip LaunchAgent helper setup
      --launchagent-only          Update only the LaunchAgent, helper, and monitor assets
      --launch-interval SECONDS   Remount recheck interval for the persistent monitor (default: 300)
      --no-start-backup           Skip starting the first backup
      --force-clean-partial       Remove known partial bundles without prompting
  -y, --yes                       Auto-confirm destructive cleanup prompts
  -v, --verbose                   Print INFO/WARN logs to stdout
      --debug                     Enable debug logging
      --log-file PATH             Override log file path
  -h, --help                      Show this help

Environment:
  CHRONOS_ENCRYPTION_PASSWORD     Password used when encryption is enabled
EOF
}
# -----------------------------------------------
# Helpers
# -----------------------------------------------
# -----------------------------------------------------------------------------
# timestamp()
# Centralized timestamp helper used by the main script and generated helper scripts.
# -----------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# -----------------------------------------------------------------------------
# escape_for_applescript()
# Escapes dynamic values before embedding them in AppleScript blocks used by macOS mount workflows.
# -----------------------------------------------------------------------------
escape_for_applescript() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# -----------------------------------------------------------------------------
# log()
# Writes structured log entries to the configured log file and optionally to stderr for verbose/debug/operator-facing messages.
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >>"$LOG_FILE"

    if [[ "$DEBUG" -eq 1 || "$VERBOSE" -eq 1 || "$level" == "ERROR" || "$level" == "WARN" ]]; then
        printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >&2
    fi
}

# -----------------------------------------------------------------------------
# info()
# INFO-level logging wrapper.
# -----------------------------------------------------------------------------
info() {
    log "INFO" "$*"
}

# -----------------------------------------------------------------------------
# warn()
# WARN-level logging wrapper.
# -----------------------------------------------------------------------------
warn() {
    log "WARN" "$*"
}

# -----------------------------------------------------------------------------
# error()
# ERROR-level logging wrapper.
# -----------------------------------------------------------------------------
error() {
    log "ERROR" "$*"
}

# -----------------------------------------------------------------------------
# die()
# Fatal error helper: log the failure and exit.
# -----------------------------------------------------------------------------
die() {
    error "$*"
    exit 1
}

# -----------------------------------------------------------------------------
# on_error()
# ERR trap callback that records failing line number and exit code.
# -----------------------------------------------------------------------------
on_error() {
    local exit_code="$1"
    local line_no="$2"
    error "Command failed at line ${line_no} with exit code ${exit_code}."
    exit "$exit_code"
}

# -----------------------------------------------
# Cleanup
# -----------------------------------------------
# -----------------------------------------------------------------------------
# cleanup()
# EXIT trap callback. Cleans temporary sparsebundles, detaches images created during failed runs, clears password variables, and logs final status.
# -----------------------------------------------------------------------------
cleanup() {
    local exit_code="$?"

    if [[ "$MOUNTED_IMAGE_IN_RUN" -eq 1 && "$RUN_SUCCEEDED" -ne 1 ]]; then
        if [[ -n "${IMAGE_MOUNT_POINT:-}" ]] && is_mountpoint "$IMAGE_MOUNT_POINT"; then
            info "Detaching sparsebundle mounted at ${IMAGE_MOUNT_POINT}."
            detach_image_mount "$IMAGE_MOUNT_POINT" || warn "Unable to detach ${IMAGE_MOUNT_POINT}; detach manually if needed."
        elif [[ -n "${IMAGE_DEVICE:-}" ]]; then
            info "Detaching sparsebundle device ${IMAGE_DEVICE}."
            hdiutil detach "$IMAGE_DEVICE" -quiet >/dev/null 2>&1 || warn "Unable to detach ${IMAGE_DEVICE}; detach manually if needed."
        fi
    fi

    if [[ -n "${TMP_BUNDLE:-}" && -d "${TMP_BUNDLE}" ]]; then
        info "Removing temporary sparsebundle ${TMP_BUNDLE}."
        rm -rf "$TMP_BUNDLE" || warn "Unable to remove temporary sparsebundle ${TMP_BUNDLE}."
    fi

    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
        rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
    fi

    unset ENCRYPTION_PASSWORD || true

    if [[ "$exit_code" -eq 0 ]]; then
        info "Chronos completed successfully."
    else
        error "Chronos exited with failure status ${exit_code}."
    fi
}

trap 'on_error $? $LINENO' ERR
trap cleanup EXIT

# -----------------------------------------------------------------------------
# run_as_root()
# Runs a command with root privileges only when required, centralizing privilege escalation.
# -----------------------------------------------------------------------------
run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# -----------------------------------------------------------------------------
# run_in_console_user_context()
# Runs GUI-sensitive commands in the logged-in macOS console user session, important for Finder/open, LaunchAgent, and Aqua behavior.
# -----------------------------------------------------------------------------
run_in_console_user_context() {
    if [[ "$(id -u)" -eq "$CONSOLE_UID" ]]; then
        "$@"
    elif [[ "$(id -u)" -eq 0 ]]; then
        launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
    else
        "$@"
    fi
}
# -----------------------------------------------------------------------------
# retry()
# Generic retry wrapper for transient network and mount operations.
# -----------------------------------------------------------------------------
retry() {
    local attempts="$1"
    local delay_seconds="$2"
    shift 2

    local attempt=1
    until "$@"; do
        if [[ "$attempt" -ge "$attempts" ]]; then
            return 1
        fi
        warn "Attempt ${attempt}/${attempts} failed for: $*. Retrying in ${delay_seconds}s."
        sleep "$delay_seconds"
        attempt=$((attempt + 1))
    done
}

# -----------------------------------------------------------------------------
# is_mountpoint()
# Checks whether a path is currently mounted by scanning mount output.
# -----------------------------------------------------------------------------
is_mountpoint() {
    local target="$1"
    mount | awk -v target="on ${target} " 'index($0, target) { found=1 } END { exit found ? 0 : 1 }'
}

# -----------------------------------------------------------------------------
# wait_for_mountpoint()
# Polls until a mountpoint appears or a timeout is reached.
# -----------------------------------------------------------------------------
wait_for_mountpoint() {
    local target="$1"
    local timeout="$2"
    local elapsed=0

    while [[ "$elapsed" -lt "$timeout" ]]; do
        if is_mountpoint "$target"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

# -----------------------------------------------------------------------------
# confirm_action()
# Interactive confirmation helper for destructive cleanup, bypassed by --yes.
# -----------------------------------------------------------------------------
confirm_action() {
    local prompt="$1"

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        info "Auto-confirmed: ${prompt}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        return 1
    fi

    read -r -p "${prompt} [y/N]: " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# -----------------------------------------------------------------------------
# parse_args()
# Parses CLI flags, including v2.2.1 launchagent-only mode and monitor interval behavior.
# -----------------------------------------------------------------------------
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -s|--size)
                SIZE="${2:?Missing value for $1}"
                shift 2
                ;;
            -d|--destination)
                DESTINATION="${2:?Missing value for $1}"
                shift 2
                ;;
            -f|--filesystem)
                FILESYSTEM="${2:?Missing value for $1}"
                shift 2
                ;;
            -u|--url)
                NETWORK_URL="${2:?Missing value for $1}"
                shift 2
                ;;
            -n|--name)
                VOLUME_NAME="${2:?Missing value for $1}"
                shift 2
                ;;
            --no-encryption)
                ENABLE_ENCRYPTION=0
                shift
                ;;
            --password-env)
                PASSWORD_ENV_VAR="${2:?Missing value for $1}"
                shift 2
                ;;
            --no-launchagent)
                SETUP_LAUNCHAGENT=0
                shift
                ;;
            --launchagent-only)
                LAUNCHAGENT_ONLY=1
                START_FIRST_BACKUP=0
                shift
                ;;
            --launch-interval)
                LAUNCH_INTERVAL="${2:?Missing value for $1}"
                shift 2
                ;;
            --no-start-backup)
                START_FIRST_BACKUP=0
                shift
                ;;
            --force-clean-partial)
                FORCE_CLEAN_PARTIAL=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --debug)
                DEBUG=1
                VERBOSE=1
                shift
                ;;
            --log-file)
                LOG_FILE="${2:?Missing value for $1}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}
# -----------------------------------------------
# Validation
# -----------------------------------------------
# -----------------------------------------------------------------------------
# require_command()
# Validates required platform commands are present before mutating system state.
# -----------------------------------------------------------------------------
require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

# -----------------------------------------------------------------------------
# validate_size()
# Validates sparsebundle size syntax such as 500g or 2t.
# -----------------------------------------------------------------------------
validate_size() {
    [[ "$SIZE" =~ ^[1-9][0-9]*[bBkKmMgGtTpPeE]$ ]] || die "Invalid size '${SIZE}'. Use values like 500g or 2t."
    SIZE="$(printf '%s' "$SIZE" | tr '[:upper:]' '[:lower:]')"
}

# -----------------------------------------------------------------------------
# validate_filesystem()
# Limits filesystem choices to supported APFS/HFS+ variants.
# -----------------------------------------------------------------------------
validate_filesystem() {
    case "$FILESYSTEM" in
        "APFS"|"Case-sensitive APFS"|"Journaled HFS+"|"Case-sensitive Journaled HFS+")
            ;;
        *)
            die "Unsupported filesystem '${FILESYSTEM}'."
            ;;
    esac
}

# -----------------------------------------------------------------------------
# validate_destination()
# Prevents unsafe destination paths such as / or /Volumes.
# -----------------------------------------------------------------------------
validate_destination() {
    [[ "$DESTINATION" = /* ]] || die "Destination must be an absolute path."
    [[ "$DESTINATION" != "/" ]] || die "Destination '/' is not allowed."
    [[ "$DESTINATION" != "/Volumes" ]] || die "Destination '/Volumes' is too broad and is not allowed."
}

# -----------------------------------------------------------------------------
# validate_launch_interval()
# Ensures the remount monitor interval is a positive integer.
# -----------------------------------------------------------------------------
validate_launch_interval() {
    [[ "$LAUNCH_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "Launch interval must be a positive integer."
}

# -----------------------------------------------------------------------------
# validate_url()
# Validates SMB/AFP URL format and derives host/port for reachability checks.
# -----------------------------------------------------------------------------
validate_url() {
    [[ "$NETWORK_URL" =~ ^(smb|afp)://[^/]+/.+ ]] || die "Network URL must look like smb://host/share or afp://host/share."

    SHARE_HOST="$(printf '%s' "$NETWORK_URL" | sed -E 's#^[a-z]+://([^/@]+@)?([^/]+)/.*#\2#')"
    [[ -n "$SHARE_HOST" ]] || die "Unable to determine share host from URL '${NETWORK_URL}'."

    case "$NETWORK_URL" in
        smb://*) SHARE_PORT=445 ;;
        afp://*) SHARE_PORT=548 ;;
        *) die "Unsupported network URL scheme in '${NETWORK_URL}'." ;;
    esac
}
# -----------------------------------------------
# Gather Data
# -----------------------------------------------
# -----------------------------------------------------------------------------
# prepare_context()
# Discovers the logged-in console user, computer identity, MAC-derived bundle name, sparsebundle paths, LaunchAgent paths, and temp workspace.
# -----------------------------------------------------------------------------
prepare_context() {
    CONSOLE_USER="$(stat -f '%Su' /dev/console)"
    [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]] || die "Unable to determine the logged-in console user."

    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    CONSOLE_GROUP="$(id -gn "$CONSOLE_USER")"
    CONSOLE_HOME="$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory | awk '{print $2}')"
    [[ -n "$CONSOLE_HOME" ]] || die "Unable to determine home directory for ${CONSOLE_USER}."

    COMPUTER_NAME="$(scutil --get ComputerName)"
    HARDWARE_UUID="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F '"' '/IOPlatformUUID/ { print $4; exit }')"
    [[ -n "$HARDWARE_UUID" ]] || die "Unable to determine hardware UUID."

    PRIMARY_MAC="$(ifconfig en0 2>/dev/null | awk '/ether/ { print $2; exit }' || true)"
    if [[ -z "$PRIMARY_MAC" ]]; then
        PRIMARY_MAC="$(ifconfig en1 2>/dev/null | awk '/ether/ { print $2; exit }' || true)"
    fi
    [[ -n "$PRIMARY_MAC" ]] || die "Unable to determine a primary MAC address from en0 or en1."
    PRIMARY_MAC="$(printf '%s' "$PRIMARY_MAC" | tr -d ':' | tr '[:lower:]' '[:upper:]')"

    BUNDLE_NAME="${COMPUTER_NAME}_${PRIMARY_MAC}.sparsebundle"
    BUNDLE_PATH="${DESTINATION}/${BUNDLE_NAME}"
    MACHINE_ID_PLIST="${BUNDLE_PATH}/com.apple.TimeMachine.MachineID.plist"
    STAGING_BUNDLE="${DESTINATION}/.${BUNDLE_NAME}.partial"
    LAUNCH_AGENT_LABEL="com.${CONSOLE_USER}.chronos"
    LAUNCH_AGENT_PATH="${CONSOLE_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
    HELPER_SCRIPT_PATH="${HELPER_DIR}/chronos-remount.sh"
    MONITOR_SCRIPT_PATH="${HELPER_DIR}/chronos-remount-monitor.sh"
    LAUNCH_LOG_DIR="${CONSOLE_HOME}/Library/Logs/Chronos"
    EXPECTED_IMAGE_MOUNT_POINT="/Volumes/${VOLUME_NAME}"

    TMP_DIR="$(mktemp -d /tmp/chronos.XXXXXX)"
    TMP_BUNDLE="${TMP_DIR}/${BUNDLE_NAME}"
}

# -----------------------------------------------------------------------------
# validate_setup()
# Runs all command/input validation before any stateful operation. Also prevents incompatible launchagent-only options.
# -----------------------------------------------------------------------------
validate_setup() {
    require_command awk
    require_command cp
    require_command date
    require_command diskutil
    require_command dscl
    require_command find
    require_command hdiutil
    require_command ioreg
    require_command launchctl
    require_command mv
    require_command nc
    require_command open
    require_command osascript
    require_command plutil
    require_command scutil
    require_command stat
    require_command tmutil
    require_command /usr/libexec/PlistBuddy

    validate_size
    validate_filesystem
    validate_destination
    validate_url
    validate_launch_interval

    if [[ "$LAUNCHAGENT_ONLY" -eq 1 && "$SETUP_LAUNCHAGENT" -ne 1 ]]; then
        die "--launchagent-only cannot be combined with --no-launchagent."
    fi

    [[ -w "$(dirname "$LOG_FILE")" ]] || die "Log directory is not writable: $(dirname "$LOG_FILE")"
}
# -----------------------------------------------
# Network Mount
# -----------------------------------------------
# -----------------------------------------------------------------------------
# warn_if_host_unreachable()
# Non-fatal preflight warning when the SMB/AFP host is not reachable.
# -----------------------------------------------------------------------------
warn_if_host_unreachable() {
    if ! nc -z -w 2 "$SHARE_HOST" "$SHARE_PORT" >/dev/null 2>&1; then
        warn "Unable to reach ${SHARE_HOST}:${SHARE_PORT} before mounting. The share may still prompt and mount if it becomes available."
    fi
}

# -----------------------------------------------------------------------------
# mount_network_share_once()
# Single attempt to ensure the network share is mounted and reachable.
# -----------------------------------------------------------------------------
mount_network_share_once() {
    if is_mountpoint "$DESTINATION"; then
        if path_is_accessible "$DESTINATION"; then
            info "Network share already mounted and reachable at ${DESTINATION}."
            return 0
        fi

        warn "Network share mountpoint ${DESTINATION} exists but is not reachable; requesting reconnect."
    fi

    info "Requesting mount for ${NETWORK_URL}."
    run_in_console_user_context open "$NETWORK_URL" >/dev/null 2>&1 || return 1
    wait_for_mountpoint "$DESTINATION" 30 || return 1
    path_is_accessible "$DESTINATION"
}

# -----------------------------------------------------------------------------
# mount_network_share()
# Retry wrapper around network share mounting.
# -----------------------------------------------------------------------------
mount_network_share() {
    warn_if_host_unreachable
    retry 3 5 mount_network_share_once || die "Failed to mount network share ${NETWORK_URL} at ${DESTINATION}."
    info "Network share mounted at ${DESTINATION}."
}

# -----------------------------------------------------------------------------
# get_encryption_password()
# Obtains encryption password from runtime state, environment variable, or interactive prompt with confirmation.
# -----------------------------------------------------------------------------
get_encryption_password() {
    local password="${ENCRYPTION_PASSWORD:-${!PASSWORD_ENV_VAR:-}}"

    if [[ -n "$password" ]]; then
        ENCRYPTION_PASSWORD="$password"
        printf '%s' "$password"
        return 0
    fi

    [[ -t 0 ]] || die "Encryption is enabled but ${PASSWORD_ENV_VAR} is not set and no TTY is available for prompting."

    local first=""
    local second=""
    while true; do
        read -r -s -p "Enter encryption password: " first
        printf '\n'
        read -r -s -p "Confirm encryption password: " second
        printf '\n'

        [[ -n "$first" ]] || { warn "Password cannot be empty."; continue; }
        [[ "$first" == "$second" ]] || { warn "Passwords do not match."; continue; }

        ENCRYPTION_PASSWORD="$first"
        printf '%s' "$first"
        return 0
    done
}

# -----------------------------------------------------------------------------
# validate_local_sparsebundle_image()
# Uses hdiutil imageinfo to validate a newly created sparsebundle.
# -----------------------------------------------------------------------------
validate_local_sparsebundle_image() {
    local image_path="$1"

    if [[ "$ENABLE_ENCRYPTION" -eq 1 ]]; then
        local validation_password="${ENCRYPTION_PASSWORD:-${!PASSWORD_ENV_VAR:-}}"

        if [[ -n "$validation_password" ]]; then
            printf '%s' "$validation_password" | hdiutil imageinfo -stdinpass "$image_path" >/dev/null 2>&1
        else
            hdiutil imageinfo "$image_path" >/dev/null 2>&1
        fi
    else
        hdiutil imageinfo "$image_path" >/dev/null 2>&1
    fi
}

# -----------------------------------------------------------------------------
# path_is_accessible()
# Confirms a path exists and can be listed, useful for stale network mounts.
# -----------------------------------------------------------------------------
path_is_accessible() {
    local target="$1"

    [[ -e "$target" ]] || return 1
    /bin/ls -ld "$target" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# validate_sparsebundle_structure()
# Lightweight sparsebundle directory sanity check before stronger attach validation.
# -----------------------------------------------------------------------------
validate_sparsebundle_structure() {
    local image_path="$1"

    [[ -d "$image_path" ]] || return 1
    if [[ ! -f "${image_path}/Info.plist" && ! -d "${image_path}/bands" && ! -f "${image_path}/token" ]]; then
        return 1
    fi

    if [[ ! -f "${image_path}/Info.plist" ]]; then
        warn "Sparsebundle at ${image_path} is missing Info.plist; continuing because the mount step is the real validation."
    fi

    if [[ ! -d "${image_path}/bands" ]]; then
        warn "Sparsebundle at ${image_path} is missing bands/; continuing because the mount step is the real validation."
    fi

    return 0
}

# -----------------------------------------------------------------------------
# handle_partial_state()
# Handles leftover hidden staging bundles from interrupted runs.
# -----------------------------------------------------------------------------
handle_partial_state() {
    if [[ -d "$STAGING_BUNDLE" ]]; then
        warn "Found partial sparsebundle state at ${STAGING_BUNDLE}."
        if [[ "$FORCE_CLEAN_PARTIAL" -eq 1 ]] || confirm_action "Delete partial sparsebundle ${STAGING_BUNDLE}?"; then
            rm -rf "$STAGING_BUNDLE" || run_as_root rm -rf "$STAGING_BUNDLE"
            info "Removed partial sparsebundle ${STAGING_BUNDLE}."
        else
            die "Partial sparsebundle exists at ${STAGING_BUNDLE}; aborting to avoid unsafe overwrite."
        fi
    fi
}

# -----------------------------------------------------------------------------
# copy_bundle_to_share()
# Copies locally created sparsebundle to a hidden staging path and promotes it to final destination.
# -----------------------------------------------------------------------------
copy_bundle_to_share() {
    handle_partial_state

    info "Copying sparsebundle to staging path ${STAGING_BUNDLE}."
    if ! cp -R -X "$TMP_BUNDLE" "$STAGING_BUNDLE"; then
        warn "cp returned non-zero status while copying to SMB share; checking whether the staged bundle is usable anyway."
    fi

    validate_sparsebundle_structure "$STAGING_BUNDLE" || die "Sparsebundle staging copy failed and ${STAGING_BUNDLE} is not usable."

    info "Promoting staged sparsebundle to ${BUNDLE_PATH}."
    if ! mv "$STAGING_BUNDLE" "$BUNDLE_PATH"; then
        warn "mv returned non-zero status while promoting the sparsebundle; checking whether the final bundle exists anyway."
    fi

    if [[ ! -d "$BUNDLE_PATH" && -d "$STAGING_BUNDLE" ]]; then
        warn "Final bundle path is missing after promote; retrying direct move once."
        mv "$STAGING_BUNDLE" "$BUNDLE_PATH" || true
    fi

    [[ -d "$BUNDLE_PATH" ]] || die "Sparsebundle copy failed and ${BUNDLE_PATH} is missing."
    validate_sparsebundle_structure "$BUNDLE_PATH" || die "Sparsebundle exists at ${BUNDLE_PATH} but does not look usable."

    if [[ -d "$STAGING_BUNDLE" ]]; then
        warn "Removing leftover staging bundle ${STAGING_BUNDLE}."
        rm -rf "$STAGING_BUNDLE" || warn "Unable to remove leftover staging bundle ${STAGING_BUNDLE}."
    fi
}
# -----------------------------------------------
# Sparsebundle Creation
# -----------------------------------------------
# -----------------------------------------------------------------------------
# create_sparsebundle()
# Creates a new sparsebundle when needed or safely reuses an existing one.
# -----------------------------------------------------------------------------
create_sparsebundle() {
    if [[ -d "$BUNDLE_PATH" ]]; then
        validate_sparsebundle_structure "$BUNDLE_PATH" || die "Existing sparsebundle at ${BUNDLE_PATH} does not look usable."
        info "Sparsebundle already exists at ${BUNDLE_PATH}; deferring final validation to the mount step."
        SUMMARY_BUNDLE_STATUS="reused-existing"
        return 0
    fi

    info "Creating sparsebundle ${TMP_BUNDLE} (${SIZE}, ${FILESYSTEM})."

    if [[ "$ENABLE_ENCRYPTION" -eq 1 ]]; then
        local encryption_password
        encryption_password="$(get_encryption_password)"
        printf '%s' "$encryption_password" | hdiutil create \
            -size "$SIZE" \
            -fs "$FILESYSTEM" \
            -type SPARSEBUNDLE \
            -volname "$VOLUME_NAME" \
            -encryption AES-256 \
            -stdinpass \
            "$TMP_BUNDLE" \
            >/dev/null
        unset encryption_password
    else
        hdiutil create \
            -size "$SIZE" \
            -fs "$FILESYSTEM" \
            -type SPARSEBUNDLE \
            -volname "$VOLUME_NAME" \
            "$TMP_BUNDLE" \
            >/dev/null
    fi

    [[ -d "$TMP_BUNDLE" ]] || die "Sparsebundle creation reported success but ${TMP_BUNDLE} was not created."
    validate_local_sparsebundle_image "$TMP_BUNDLE" || die "New sparsebundle ${TMP_BUNDLE} is invalid."
    TEMP_BUNDLE_CREATED=1

    copy_bundle_to_share

    rm -rf "$TMP_BUNDLE"
    TEMP_BUNDLE_CREATED=0
    SUMMARY_BUNDLE_STATUS="created-new"
}

# -----------------------------------------------------------------------------
# write_machine_id_plist()
# Writes Time Machine metadata containing HardwareUUID and MachineName.
# -----------------------------------------------------------------------------
write_machine_id_plist() {
    info "Writing MachineID metadata to ${MACHINE_ID_PLIST}."

    [[ -d "$BUNDLE_PATH" ]] || die "Sparsebundle path does not exist: ${BUNDLE_PATH}"
    local temp_plist="${TMP_DIR}/com.apple.TimeMachine.MachineID.plist"

    cat >"$temp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>HardwareUUID</key>
    <string>${HARDWARE_UUID}</string>
    <key>MachineName</key>
    <string>${COMPUTER_NAME}</string>
</dict>
</plist>
EOF

    if ! cp -X "$temp_plist" "$MACHINE_ID_PLIST"; then
        warn "MachineID plist copy returned non-zero status; checking whether the destination file exists anyway."
    fi
    [[ -f "$MACHINE_ID_PLIST" ]] || die "Failed to write MachineID plist to ${MACHINE_ID_PLIST}."
    chmod 0644 "$MACHINE_ID_PLIST"
}

# -----------------------------------------------------------------------------
# get_existing_mount_for_image()
# Finds an existing attachment for the exact sparsebundle path via hdiutil/diskutil state.
# -----------------------------------------------------------------------------
get_existing_mount_for_image() {
    local info_plist_file=""
    local image_index=0
    local entity_index=0
    local current_path=""
    local mount_point=""
    local dev_entry=""
    local disk_info_file=""

    info_plist_file="$(mktemp "${TMP_DIR}/hdiutil-info.XXXXXX.plist")" || return 1
    hdiutil info -plist >"$info_plist_file" 2>/dev/null || return 1
    plutil -lint "$info_plist_file" >/dev/null 2>&1 || return 1

    while true; do
        current_path="$(/usr/libexec/PlistBuddy -c "Print :images:${image_index}:image-path" "$info_plist_file" 2>/dev/null || true)"
        [[ -n "$current_path" ]] || break

        if [[ "$current_path" == "$BUNDLE_PATH" ]]; then
            entity_index=0
            while true; do
                mount_point="$(/usr/libexec/PlistBuddy -c "Print :images:${image_index}:system-entities:${entity_index}:mount-point" "$info_plist_file" 2>/dev/null || true)"
                if [[ -n "$mount_point" ]]; then
                    printf '%s\n' "$mount_point"
                    return 0
                fi

                dev_entry="$(/usr/libexec/PlistBuddy -c "Print :images:${image_index}:system-entities:${entity_index}:dev-entry" "$info_plist_file" 2>/dev/null || true)"
                [[ -n "$dev_entry" ]] || break

                disk_info_file="${TMP_DIR}/diskutil-info-${image_index}-${entity_index}.plist"
                if diskutil info -plist "$dev_entry" >"$disk_info_file" 2>/dev/null && plutil -lint "$disk_info_file" >/dev/null 2>&1; then
                    mount_point="$(/usr/libexec/PlistBuddy -c "Print :MountPoint" "$disk_info_file" 2>/dev/null || true)"
                    if [[ -n "$mount_point" ]]; then
                        printf '%s\n' "$mount_point"
                        return 0
                    fi
                fi

                entity_index=$((entity_index + 1))
            done

            break
        fi

        image_index=$((image_index + 1))
    done

    return 1
}

# -----------------------------------------------------------------------------
# device_for_mount_point()
# Maps a mounted volume path to its backing device node.
# -----------------------------------------------------------------------------
device_for_mount_point() {
    local mount_point="$1"
    diskutil info "$mount_point" 2>/dev/null | awk -F': *' '/Device Node/ { print $2; exit }'
}

# -----------------------------------------------------------------------------
# detach_image_mount()
# Detaches a mounted sparsebundle using its device node when available.
# -----------------------------------------------------------------------------
detach_image_mount() {
    local mount_point="$1"
    local device

    device="$(device_for_mount_point "$mount_point" || true)"
    if [[ -n "$device" ]]; then
        hdiutil detach "$device" -quiet >/dev/null 2>&1
    else
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1
    fi
}

# -----------------------------------------------------------------------------
# mount_sparsebundle_once()
# Single sparsebundle mount attempt using existing state, DiskImageMounter/Launch Services compatibility, and hdiutil fallback.
# -----------------------------------------------------------------------------
mount_sparsebundle_once() {
    if is_mountpoint "$EXPECTED_IMAGE_MOUNT_POINT"; then
        IMAGE_MOUNT_POINT="$EXPECTED_IMAGE_MOUNT_POINT"
        IMAGE_DEVICE="$(device_for_mount_point "$IMAGE_MOUNT_POINT" || true)"
        EXISTING_IMAGE_MOUNT=1
        info "Sparsebundle already mounted at ${IMAGE_MOUNT_POINT}."
        return 0
    fi

    local existing_mount
    existing_mount="$(get_existing_mount_for_image || true)"
    if [[ -n "$existing_mount" ]]; then
        IMAGE_MOUNT_POINT="$existing_mount"
        IMAGE_DEVICE="$(device_for_mount_point "$IMAGE_MOUNT_POINT" || true)"
        EXISTING_IMAGE_MOUNT=1
        if [[ "$existing_mount" != "$EXPECTED_IMAGE_MOUNT_POINT" ]]; then
            warn "Sparsebundle is already mounted at ${existing_mount} instead of ${EXPECTED_IMAGE_MOUNT_POINT}."
        else
            info "Sparsebundle already mounted at ${IMAGE_MOUNT_POINT}."
        fi
        return 0
    fi

    # Prefer Finder/open here because it has proven more compatible with Time Machine
    # sparsebundles on SMB than a fully hdiutil-driven attach flow.
    info "Requesting sparsebundle mount using macOS-native open for ${BUNDLE_PATH}."
    run_in_console_user_context open "$BUNDLE_PATH" >/dev/null 2>&1 || return 1

    if wait_for_mountpoint "$EXPECTED_IMAGE_MOUNT_POINT" 45; then
        IMAGE_MOUNT_POINT="$EXPECTED_IMAGE_MOUNT_POINT"
    else
        existing_mount="$(get_existing_mount_for_image || true)"
        [[ -n "$existing_mount" ]] || return 1
        IMAGE_MOUNT_POINT="$existing_mount"
        if [[ "$existing_mount" != "$EXPECTED_IMAGE_MOUNT_POINT" ]]; then
            warn "Sparsebundle mounted at ${existing_mount}; expected ${EXPECTED_IMAGE_MOUNT_POINT}."
        fi
    fi

    IMAGE_DEVICE="$(device_for_mount_point "$IMAGE_MOUNT_POINT" || true)"
    MOUNTED_IMAGE_IN_RUN=1
    return 0
}
# -----------------------------------------------
# Mount
# -----------------------------------------------
# -----------------------------------------------------------------------------
# mount_image()
# High-level sparsebundle attach validation with retry behavior.
# -----------------------------------------------------------------------------
mount_image() {
    info "Preparing to mount sparsebundle ${BUNDLE_PATH}."
    [[ -d "$BUNDLE_PATH" ]] || die "Sparsebundle path does not exist: ${BUNDLE_PATH}"

    retry 3 5 mount_sparsebundle_once || die "Failed to mount sparsebundle ${BUNDLE_PATH}. If it is encrypted, confirm the password prompt succeeded or that the password is stored in Keychain."
    [[ -d "$IMAGE_MOUNT_POINT" ]] || die "Sparsebundle mounted but mount point ${IMAGE_MOUNT_POINT} is missing."
    info "Sparsebundle mounted at ${IMAGE_MOUNT_POINT}."
}

# -----------------------------------------------------------------------------
# tm_destination_info()
# Reads Time Machine destination information.
# -----------------------------------------------------------------------------
tm_destination_info() {
    tmutil destinationinfo 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# tm_destination_matches_path()
# Checks whether the current mounted sparsebundle is already a Time Machine destination.
# -----------------------------------------------------------------------------
tm_destination_matches_path() {
    local destination_info
    destination_info="$(tm_destination_info)"
    [[ -n "$destination_info" ]] || return 1
    printf '%s\n' "$destination_info" | grep -Fq "$IMAGE_MOUNT_POINT"
}

# -----------------------------------------------------------------------------
# tm_destination_matches_name()
# Checks for an existing Time Machine destination with the same volume name.
# -----------------------------------------------------------------------------
tm_destination_matches_name() {
    local destination_info
    destination_info="$(tm_destination_info)"
    [[ -n "$destination_info" ]] || return 1
    printf '%s\n' "$destination_info" | grep -Fq "$VOLUME_NAME"
}
# -----------------------------------------------
# Configuration
# -----------------------------------------------
# -----------------------------------------------------------------------------
# configure_tm()
# Registers the mounted sparsebundle volume with Time Machine idempotently.
# -----------------------------------------------------------------------------
configure_tm() {
    info "Configuring Time Machine destination with tmutil."

    if tm_destination_matches_path; then
        info "Time Machine destination already configured for ${IMAGE_MOUNT_POINT}; keeping configuration idempotent."
        return 0
    fi

    if tm_destination_matches_name; then
        warn "A Time Machine destination named ${VOLUME_NAME} is already registered, but not for ${IMAGE_MOUNT_POINT}; adding the current mounted volume path."
    fi

    run_as_root tmutil setdestination -a "$IMAGE_MOUNT_POINT"
    tm_destination_matches_path || die "Time Machine does not report ${IMAGE_MOUNT_POINT} as a destination after configuration."
}

# -----------------------------------------------------------------------------
# write_file_atomically()
# Writes generated helper/plist assets via temp file and install for safer updates.
# -----------------------------------------------------------------------------
write_file_atomically() {
    local target="$1"
    local mode="$2"
    local temp_file="${TMP_DIR}/$(basename "$target").tmp"

    cat >"$temp_file"
    run_as_root install -m "$mode" "$temp_file" "$target"
}
# -----------------------------------------------
#Launchagent
# -----------------------------------------------
# -----------------------------------------------------------------------------
# setup_launchagent()
# Installs the v2.2.1 LaunchAgent, remount helper, and persistent monitor. This replaces unreliable short-lived StartInterval-only behavior.
# -----------------------------------------------------------------------------
setup_launchagent() {
    if [[ "$SETUP_LAUNCHAGENT" -ne 1 ]]; then
        SUMMARY_LAUNCHAGENT_STATUS="skipped"
        return 0
    fi

    local network_url_applescript
    network_url_applescript="$(escape_for_applescript "$NETWORK_URL")"

    info "Installing LaunchAgent helper assets."
    run_as_root mkdir -p "$HELPER_DIR"
    run_as_root chown "$CONSOLE_USER:$CONSOLE_GROUP" "$HELPER_DIR"
    run_as_root chmod 0750 "$HELPER_DIR"
    run_as_root mkdir -p "${CONSOLE_HOME}/Library/LaunchAgents" "$LAUNCH_LOG_DIR"
    run_as_root chown "$CONSOLE_USER:$CONSOLE_GROUP" "${CONSOLE_HOME}/Library/LaunchAgents" "$LAUNCH_LOG_DIR"
    run_as_root chmod 0755 "${CONSOLE_HOME}/Library/LaunchAgents" "$LAUNCH_LOG_DIR"

    write_file_atomically "$HELPER_SCRIPT_PATH" 0750 <<EOF
#!/bin/bash
set -euo pipefail
IFS=\$'\\n\\t'

LOG_FILE="${LAUNCH_LOG_DIR}/chronos-remount.log"
LOCK_DIR="${LAUNCH_LOG_DIR}/chronos-remount.lock"
DISK_IMAGE_MOUNTER_APP="/System/Library/CoreServices/DiskImageMounter.app"
NETWORK_URL="${NETWORK_URL}"
SHARE_HOST="${SHARE_HOST}"
SHARE_PORT="${SHARE_PORT}"
DESTINATION="${DESTINATION}"
BUNDLE_PATH="${BUNDLE_PATH}"
VOLUME_NAME="${VOLUME_NAME}"
VOLUME_MOUNT_POINT="/Volumes/${VOLUME_NAME}"

# -----------------------------------------------------------------------------
# timestamp()
# Centralized timestamp helper used by the main script and generated helper scripts.
# -----------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# -----------------------------------------------------------------------------
# log()
# Writes structured log entries to the configured log file and optionally to stderr for verbose/debug/operator-facing messages.
# -----------------------------------------------------------------------------
log() {
    printf '[%s] [%s] %s\n' "\$(timestamp)" "\$1" "\$2" >>"\$LOG_FILE"
}

# -----------------------------------------------------------------------------
# cleanup_lock()
# Remount helper cleanup for lock directory ownership.
# -----------------------------------------------------------------------------
cleanup_lock() {
    if [[ -d "\$LOCK_DIR" ]] && [[ -f "\$LOCK_DIR/pid" ]]; then
        local owner_pid=""
        owner_pid="\$(cat "\$LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ "\$owner_pid" == "\$\$" ]]; then
            rm -rf "\$LOCK_DIR" >/dev/null 2>&1 || true
        fi
    fi
}

# -----------------------------------------------------------------------------
# acquire_lock()
# Prevents overlapping remount helper executions and clears stale locks.
# -----------------------------------------------------------------------------
acquire_lock() {
    if mkdir "\$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "\$\$" >"\$LOCK_DIR/pid"
        return 0
    fi

    local existing_pid=""
    existing_pid="\$(cat "\$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "\$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "\$existing_pid" 2>/dev/null; then
        log WARN "Another remount check is already running with pid \$existing_pid; skipping duplicate invocation"
        return 1
    fi

    log WARN "Removing stale remount lock at \$LOCK_DIR"
    rm -rf "\$LOCK_DIR" >/dev/null 2>&1 || true

    if mkdir "\$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "\$\$" >"\$LOCK_DIR/pid"
        return 0
    fi

    log WARN "Unable to acquire remount lock at \$LOCK_DIR"
    return 1
}

# -----------------------------------------------------------------------------
# is_mountpoint()
# Checks whether a path is currently mounted by scanning mount output.
# -----------------------------------------------------------------------------
is_mountpoint() {
    mount | awk -v target="on \$1 " 'index(\$0, target) { found=1 } END { exit found ? 0 : 1 }'
}

# -----------------------------------------------------------------------------
# path_is_accessible()
# Confirms a path exists and can be listed, useful for stale network mounts.
# -----------------------------------------------------------------------------
path_is_accessible() {
    local target="\$1"

    [[ -e "\$target" ]] || return 1
    /bin/ls -ld "\$target" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# share_path_ready()
# Checks whether the network share is mounted and accessible.
# -----------------------------------------------------------------------------
share_path_ready() {
    is_mountpoint "\$DESTINATION" && path_is_accessible "\$DESTINATION"
}

# -----------------------------------------------------------------------------
# bundle_path_ready()
# Checks whether the sparsebundle directory exists, is accessible, and looks structurally valid.
# -----------------------------------------------------------------------------
bundle_path_ready() {
    [[ -d "\$BUNDLE_PATH" ]] || return 1
    path_is_accessible "\$BUNDLE_PATH" || return 1

    if [[ -f "\$BUNDLE_PATH/Info.plist" || -d "\$BUNDLE_PATH/bands" ]]; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# bundle_is_attached()
# Checks whether hdiutil already sees the sparsebundle as attached.
# -----------------------------------------------------------------------------
bundle_is_attached() {
    /usr/bin/hdiutil info 2>/dev/null | /usr/bin/grep -Fq "\$BUNDLE_PATH"
}

# -----------------------------------------------------------------------------
# network_host_reachable()
# Tests SMB/AFP host reachability before GUI mount calls to avoid offline Finder popups.
# -----------------------------------------------------------------------------
network_host_reachable() {
    /usr/bin/nc -z -w 2 "\$SHARE_HOST" "\$SHARE_PORT" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# wait_for_mountpoint()
# Polls until a mountpoint appears or a timeout is reached.
# -----------------------------------------------------------------------------
wait_for_mountpoint() {
    local target="\$1"
    local timeout="\$2"
    local elapsed=0

    while [[ "\$elapsed" -lt "\$timeout" ]]; do
        if is_mountpoint "\$target"; then
            return 0
        fi
        # sleep can be interrupted on macOS wake; with set -e this would terminate
        # the helper early, so we explicitly ignore non-zero exit codes here
        sleep 1 || true
        elapsed=\$((elapsed + 1))
    done

    return 1
}

trap cleanup_lock EXIT INT TERM HUP

if ! acquire_lock; then
    exit 0
fi

# -----------------------------------------------------------------------------
# request_share_mount()
# Requests share mount only after host reachability succeeds.
# -----------------------------------------------------------------------------
request_share_mount() {
    local elapsed=0

    log INFO "Share mount requested for \$NETWORK_URL"

    # Finder-backed mount APIs can raise user-facing connection dialogs when the
    # SMB/AFP host is offline, so skip GUI mount requests until the host answers.
    if ! network_host_reachable; then
        log WARN "Network host \$SHARE_HOST:\$SHARE_PORT is not reachable; skipping GUI mount request to avoid Finder popup"
        return 1
    fi

    /usr/bin/osascript >/dev/null 2>&1 <<OSA || true
try
    mount volume "${network_url_applescript}"
end try
OSA

    if ! share_path_ready; then
        /usr/bin/open "\$NETWORK_URL" >/dev/null 2>&1 || log WARN "Failed to request share mount for \$NETWORK_URL"
    fi

    while [[ "\$elapsed" -lt 30 ]]; do
        if share_path_ready && bundle_path_ready; then
            return 0
        fi
        sleep 1 || true
        elapsed=\$((elapsed + 1))
    done

    share_path_ready && bundle_path_ready
}

# -----------------------------------------------------------------------------
# refresh_share_access()
# Validates or repairs share access while avoiding GUI mount calls when host is offline.
# -----------------------------------------------------------------------------
refresh_share_access() {
    if share_path_ready && bundle_path_ready; then
        log INFO "Share and sparsebundle path already reachable"
        return 0
    fi

    if ! network_host_reachable; then
        log WARN "Network host \$SHARE_HOST:\$SHARE_PORT is not reachable; leaving share disconnected to avoid Finder popup"
        return 1
    fi

    if is_mountpoint "\$DESTINATION"; then
        log WARN "Share mountpoint exists but is not fully reachable; requesting reconnect"
    fi

    request_share_mount
}

# -----------------------------------------------------------------------------
# mount_sparsebundle_with_diskimagemounter()
# Attempts sparsebundle mount through DiskImageMounter for GUI/Keychain compatibility.
# -----------------------------------------------------------------------------
mount_sparsebundle_with_diskimagemounter() {
    if [[ ! -d "\$DISK_IMAGE_MOUNTER_APP" ]]; then
        log WARN "DiskImageMounter app is missing at \$DISK_IMAGE_MOUNTER_APP"
        return 1
    fi

    log INFO "Attempting DiskImageMounter open for \$BUNDLE_PATH"
    if /usr/bin/open -g -a "\$DISK_IMAGE_MOUNTER_APP" "\$BUNDLE_PATH" >/dev/null 2>&1; then
        log INFO "DiskImageMounter open requested for \$BUNDLE_PATH"
        return 0
    fi

    log WARN "DiskImageMounter open failed for \$BUNDLE_PATH"
    return 1
}

# -----------------------------------------------------------------------------
# mount_sparsebundle_with_open()
# Fallback mount via Launch Services open.
# -----------------------------------------------------------------------------
mount_sparsebundle_with_open() {
    log INFO "Attempting Launch Services open fallback for \$BUNDLE_PATH"
    if /usr/bin/open "\$BUNDLE_PATH" >/dev/null 2>&1; then
        log INFO "Launch Services open fallback requested for \$BUNDLE_PATH"
        return 0
    fi

    log WARN "Launch Services open fallback failed for \$BUNDLE_PATH"
    return 1
}

# -----------------------------------------------------------------------------
# mount_sparsebundle_with_hdiutil()
# Fallback mount via hdiutil attach using agentpass.
# -----------------------------------------------------------------------------
mount_sparsebundle_with_hdiutil() {
    log INFO "Attempting hdiutil attach for \$BUNDLE_PATH"
    if /usr/bin/hdiutil attach -quiet -noautoopen -agentpass "\$BUNDLE_PATH" >/dev/null 2>&1; then
        log INFO "hdiutil attach succeeded for \$BUNDLE_PATH"
        return 0
    fi

    log WARN "hdiutil attach failed for \$BUNDLE_PATH"
    return 1
}

# -----------------------------------------------------------------------------
# attempt_sparsebundle_mount()
# Retries share refresh and sparsebundle mount attempts safely.
# -----------------------------------------------------------------------------
attempt_sparsebundle_mount() {
    local attempt=1

    while [[ "\$attempt" -le 3 ]]; do
        if ! refresh_share_access; then
            log WARN "Share refresh attempt \${attempt}/3 failed for \$DESTINATION"
            sleep 5 || true
            attempt=\$((attempt + 1))
            continue
        fi

        if ! share_path_ready || ! bundle_path_ready; then
            log WARN "Share or sparsebundle path is not reachable after refresh; skipping sparsebundle mount attempt \${attempt}/3"
            sleep 5 || true
            attempt=\$((attempt + 1))
            continue
        fi

        if is_mountpoint "\$VOLUME_MOUNT_POINT"; then
            log INFO "Sparsebundle already mounted at \$VOLUME_MOUNT_POINT"
            return 0
        fi

        if bundle_is_attached; then
            log INFO "Sparsebundle already attached for \$BUNDLE_PATH"
            return 0
        fi

        if mount_sparsebundle_with_diskimagemounter || mount_sparsebundle_with_open || mount_sparsebundle_with_hdiutil; then
            if wait_for_mountpoint "\$VOLUME_MOUNT_POINT" 45 || bundle_is_attached; then
                return 0
            fi
        fi

        log WARN "Sparsebundle mount attempt \${attempt}/3 did not complete; refreshing share before retry"
        if network_host_reachable; then
            request_share_mount || true
        else
            log WARN "Network host \$SHARE_HOST:\$SHARE_PORT is not reachable; skipping share refresh before retry"
        fi
        sleep 5 || true
        attempt=\$((attempt + 1))
    done

    return 1
}

log INFO "Chronos remount check started"

if ! share_path_ready || ! bundle_path_ready; then
    if refresh_share_access; then
        log INFO "Share mount confirmed at \$DESTINATION"
    else
        log WARN "Unable to confirm network share and sparsebundle path at \$DESTINATION"
        exit 0
    fi
else
    log INFO "Share already mounted and sparsebundle path is reachable"
fi

log INFO "Bundle path verified at \$BUNDLE_PATH"

if is_mountpoint "\$VOLUME_MOUNT_POINT"; then
    log INFO "Sparsebundle already mounted at \$VOLUME_MOUNT_POINT"
    exit 0
fi

if bundle_is_attached; then
    log INFO "Sparsebundle already attached for \$BUNDLE_PATH"
    exit 0
fi

if attempt_sparsebundle_mount; then
    :
else
    log WARN "All sparsebundle mount attempts failed for \$BUNDLE_PATH"
fi

if wait_for_mountpoint "\$VOLUME_MOUNT_POINT" 5; then
    log INFO "Final mount confirmed at \$VOLUME_MOUNT_POINT"
elif bundle_is_attached; then
    log INFO "Final mount confirmed for attached bundle at \$BUNDLE_PATH"
else
    log WARN "Final mount not confirmed at \$VOLUME_MOUNT_POINT. If encrypted, ensure the password is available via Keychain for unattended remounts."
fi
EOF

    write_file_atomically "$MONITOR_SCRIPT_PATH" 0750 <<EOF
#!/bin/bash
set -euo pipefail
IFS=\$'\\n\\t'

LOG_FILE="${LAUNCH_LOG_DIR}/chronos-remount-monitor.log"
HELPER_SCRIPT="${HELPER_SCRIPT_PATH}"
CHECK_INTERVAL="${LAUNCH_INTERVAL}"
HELPER_TIMEOUT_SECONDS="${LAUNCH_INTERVAL}"

if [[ "\$HELPER_TIMEOUT_SECONDS" -lt 180 ]]; then
    log WARN "Helper timeout floored to 180s (requested \${CHECK_INTERVAL}s)"
    HELPER_TIMEOUT_SECONDS=180
fi

# -----------------------------------------------------------------------------
# timestamp()
# Centralized timestamp helper used by the main script and generated helper scripts.
# -----------------------------------------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# -----------------------------------------------------------------------------
# log()
# Writes structured log entries to the configured log file and optionally to stderr for verbose/debug/operator-facing messages.
# -----------------------------------------------------------------------------
log() {
    printf '[%s] [%s] %s\n' "\$(timestamp)" "\$1" "\$2" >>"\$LOG_FILE"
}

# -----------------------------------------------------------------------------
# run_helper_once()
# Monitor routine that launches the helper with timeout enforcement.
# -----------------------------------------------------------------------------
run_helper_once() {
    local helper_pid=""
    local helper_status=0
    local elapsed=0

    log INFO "Launching remount helper"
    /bin/bash "\$HELPER_SCRIPT" &
    helper_pid=\$!

    while kill -0 "\$helper_pid" 2>/dev/null; do
        if [[ "\$elapsed" -ge "\$HELPER_TIMEOUT_SECONDS" ]]; then
            log WARN "Remount helper exceeded timeout of \${HELPER_TIMEOUT_SECONDS}s; terminating pid \$helper_pid"
            kill "\$helper_pid" >/dev/null 2>&1 || true
            sleep 2 || true
            kill -0 "\$helper_pid" 2>/dev/null && kill -KILL "\$helper_pid" >/dev/null 2>&1 || true
            wait "\$helper_pid" >/dev/null 2>&1 || true
            log WARN "Remount helper timed out after \${HELPER_TIMEOUT_SECONDS}s"
            return 124
        fi

        sleep 1 || true
        elapsed=\$((elapsed + 1))
    done

    if wait "\$helper_pid"; then
        log INFO "Remount helper exited with code 0"
        return 0
    fi

    helper_status="\$?"
    log WARN "Remount helper exited with code \$helper_status"
    return "\$helper_status"
}

# -----------------------------------------------------------------------------
# handle_shutdown()
# Graceful monitor shutdown handler.
# -----------------------------------------------------------------------------
handle_shutdown() {
    log INFO "Chronos remount monitor stopping"
    exit 0
}

trap handle_shutdown INT TERM HUP

# Keep one GUI-session monitor alive instead of depending on launchd to re-fire
# a short-lived job on StartInterval. In practice that timer has already proven
# unreliable here, while the helper itself is healthy and works when launched in
# the logged-in Aqua session. A persistent monitor keeps the Finder-sensitive
# mount logic in the same user context after login and through later reconnects.
# Sleep can return early after wake or signal delivery; that must not terminate
# the persistent monitor loop in a long-running user session.
log INFO "Chronos remount monitor started with interval \${CHECK_INTERVAL}s"

while true; do
    run_helper_once || true
    log INFO "Chronos remount monitor sleeping for \${CHECK_INTERVAL}s"
    sleep "\$CHECK_INTERVAL" || true
done
EOF

    write_file_atomically "$LAUNCH_AGENT_PATH" 0644 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${MONITOR_SCRIPT_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LAUNCH_LOG_DIR}/chronos-monitor.out</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOG_DIR}/chronos-monitor.err</string>
</dict>
</plist>
EOF

    run_as_root chown "$CONSOLE_USER:$CONSOLE_GROUP" "$HELPER_SCRIPT_PATH" "$MONITOR_SCRIPT_PATH" "$LAUNCH_AGENT_PATH"

    info "Attempting launchctl bootout for ${LAUNCH_AGENT_LABEL}."
    if run_as_root launchctl bootout "gui/${CONSOLE_UID}" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
        info "launchctl bootout completed for ${LAUNCH_AGENT_LABEL}."
    else
        info "launchctl bootout completed with no existing loaded instance for ${LAUNCH_AGENT_LABEL}."
    fi

    info "Attempting launchctl bootstrap for ${LAUNCH_AGENT_LABEL}."
    if run_as_root launchctl bootstrap "gui/${CONSOLE_UID}" "$LAUNCH_AGENT_PATH"; then
        info "launchctl bootstrap completed for ${LAUNCH_AGENT_LABEL}."
    else
        die "launchctl bootstrap failed for ${LAUNCH_AGENT_LABEL}."
    fi

    info "Attempting launchctl kickstart for ${LAUNCH_AGENT_LABEL}."
    if run_as_root launchctl kickstart -k "gui/${CONSOLE_UID}/${LAUNCH_AGENT_LABEL}"; then
        info "launchctl kickstart completed for ${LAUNCH_AGENT_LABEL}."
    else
        die "launchctl kickstart failed for ${LAUNCH_AGENT_LABEL}."
    fi

    SUMMARY_LAUNCHAGENT_STATUS="installed"
    info "LaunchAgent ${LAUNCH_AGENT_LABEL} installed as a persistent remount monitor."
}
# -----------------------------------------------
# Creation finished, start Backup
# -----------------------------------------------
# -----------------------------------------------------------------------------
# start_first_backup()
# Optionally starts the first Time Machine backup and treats “already running” as a normal state.
# -----------------------------------------------------------------------------
start_first_backup() {
    if [[ "$START_FIRST_BACKUP" -ne 1 ]]; then
        SUMMARY_BACKUP_STATUS="skipped"
        return 0
    fi

    info "Starting first Time Machine backup."
    local output=""
    if output="$(run_as_root tmutil startbackup --auto 2>&1)"; then
        SUMMARY_BACKUP_STATUS="started"
        info "Time Machine backup initiation succeeded."
        if [[ -n "$output" ]]; then
            info "$output"
        fi
        return 0
    elif printf '%s\n' "$output" | grep -qi "Backup already in progress"; then
        SUMMARY_BACKUP_STATUS="already-running"
        warn "A Time Machine backup is already in progress."
    else
        die "Failed to start the first backup: ${output}"
    fi
}

# -----------------------------------------------------------------------------
# print_summary()
# Prints operator-facing run summary for validation and ticket notes.
# -----------------------------------------------------------------------------
print_summary() {
    cat <<EOF
Summary
-------
Sparsebundle path : ${BUNDLE_PATH}
Sparsebundle mode : ${SUMMARY_BUNDLE_STATUS}
Mounted at        : ${IMAGE_MOUNT_POINT}
LaunchAgent       : ${SUMMARY_LAUNCHAGENT_STATUS}
Backup start      : ${SUMMARY_BACKUP_STATUS}
Log file          : ${LOG_FILE}
EOF

    if [[ "$ENABLE_ENCRYPTION" -eq 1 ]]; then
        printf '%s\n' "Note: encrypted sparsebundles may require the password to be saved in Keychain for unattended GUI remounts."
    fi
}
# -----------------------------------------------
# Main
# -----------------------------------------------
# -----------------------------------------------------------------------------
# main()
# Top-level orchestration flow for validation, context prep, mount/setup, LaunchAgent install, backup start, and final summary.
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    [[ -d "$(dirname "$LOG_FILE")" && -w "$(dirname "$LOG_FILE")" ]] || die "Log directory is not writable: $(dirname "$LOG_FILE")"
    : >"$LOG_FILE"

    info "Chronos ${VERSION} starting."
    validate_setup
    prepare_context

    info "Console user: ${CONSOLE_USER}"
    info "Computer name: ${COMPUTER_NAME}"
    info "Bundle path: ${BUNDLE_PATH}"
    info "Destination mount: ${DESTINATION}"
    info "Filesystem: ${FILESYSTEM}"
    info "Encryption enabled: ${ENABLE_ENCRYPTION}"

    if [[ "$LAUNCHAGENT_ONLY" -eq 1 ]]; then
        SUMMARY_BUNDLE_STATUS="unchanged"
        SUMMARY_BACKUP_STATUS="skipped-launchagent-only"
        info "LaunchAgent-only mode selected; skipping share mount, sparsebundle changes, MachineID writes, image mount, and Time Machine destination changes."
    else
        mount_network_share
        create_sparsebundle
        write_machine_id_plist
        mount_image
        configure_tm
    fi

    setup_launchagent

    if [[ "$LAUNCHAGENT_ONLY" -ne 1 ]]; then
        start_first_backup
    fi

    print_summary
    RUN_SUCCEEDED=1
}

main "$@"
