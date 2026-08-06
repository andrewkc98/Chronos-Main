#!/bin/bash
# =================================================================================================
# Chronos Refactor Uninstall 2.2.1
# Author: Andrew Tucker
# Description: Automated Time Machine Setup Uninstallation
# Usage: bash chronos_uninstall.sh
# -------------------------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
LOG_FILE="/tmp/chronos-uninstall.log"
HELPER_DIR="/usr/local/lib/chronos"
VOLUME_NAME="Time Machine Backups"
REMOVE_TM_DESTINATION=1
REMOVE_HELPER_ASSETS=1
REMOVE_LOGS=1
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0

CONSOLE_USER=""
CONSOLE_UID=""
CONSOLE_GROUP=""
CONSOLE_HOME=""
LAUNCH_AGENT_LABEL=""
LAUNCH_AGENT_PATH=""
HELPER_SCRIPT_PATH=""
LEGACY_APPLESCRIPT_PATH=""
LAUNCH_LOG_DIR=""
EXPECTED_MOUNT_POINT=""

usage() {
    cat <<'EOF'
Usage: chronos_uninstall.sh [options]

Options:
  -n, --name NAME            Time Machine backup volume name (default: Time Machine Backups)
      --helper-dir PATH      Chronos helper directory (default: /usr/local/lib/chronos)
      --keep-tm-destination  Do not remove matching Time Machine destination entries
      --keep-helper-assets   Do not remove generated helper files
      --keep-logs            Do not remove Chronos log files
      --dry-run              Show planned actions without changing the system
  -y, --yes                  Auto-confirm removal actions
  -v, --verbose              Print INFO/WARN logs to stderr
  -h, --help                 Show this help
EOF
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    shift
    local message="$*"
    printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >>"$LOG_FILE"
    if [[ "$VERBOSE" -eq 1 || "$level" == "WARN" || "$level" == "ERROR" ]]; then
        printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >&2
    fi
}

info() {
    log "INFO" "$*"
}

warn() {
    log "WARN" "$*"
}

error() {
    log "ERROR" "$*"
}

die() {
    error "$*"
    exit 1
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_or_echo() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local rendered=""
        printf -v rendered '%q ' "$@"
        info "DRY RUN: ${rendered% }"
        return 0
    fi

    "$@"
}

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

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--name)
                VOLUME_NAME="${2:?Missing value for $1}"
                shift 2
                ;;
            --helper-dir)
                HELPER_DIR="${2:?Missing value for $1}"
                shift 2
                ;;
            --keep-tm-destination)
                REMOVE_TM_DESTINATION=0
                shift
                ;;
            --keep-helper-assets)
                REMOVE_HELPER_ASSETS=0
                shift
                ;;
            --keep-logs)
                REMOVE_LOGS=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                VERBOSE=1
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_console_home() {
    local home_dir=""

    home_dir="$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$home_dir" ]]; then
        printf '%s\n' "$home_dir"
        return 0
    fi

    home_dir="$(awk -F: -v user="$CONSOLE_USER" '$1 == user { print $6; exit }' /etc/passwd || true)"
    if [[ -n "$home_dir" ]]; then
        warn "Falling back to /etc/passwd to resolve home directory for ${CONSOLE_USER}."
        printf '%s\n' "$home_dir"
        return 0
    fi

    home_dir="$(eval "printf '%s\n' ~${CONSOLE_USER}" 2>/dev/null || true)"
    if [[ -n "$home_dir" && "$home_dir" != "~${CONSOLE_USER}" ]]; then
        warn "Falling back to shell expansion to resolve home directory for ${CONSOLE_USER}."
        printf '%s\n' "$home_dir"
        return 0
    fi

    return 1
}

prepare_context() {
    CONSOLE_USER="$(stat -f '%Su' /dev/console)"
    [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]] || die "Unable to determine the logged-in console user."

    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    CONSOLE_GROUP="$(id -gn "$CONSOLE_USER")"
    CONSOLE_HOME="$(resolve_console_home || true)"
    [[ -n "$CONSOLE_HOME" ]] || die "Unable to determine home directory for ${CONSOLE_USER}."

    LAUNCH_AGENT_LABEL="com.${CONSOLE_USER}.chronos"
    LAUNCH_AGENT_PATH="${CONSOLE_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
    HELPER_SCRIPT_PATH="${HELPER_DIR}/chronos-remount.sh"
    LEGACY_APPLESCRIPT_PATH="${HELPER_DIR}/chronos.scpt"
    LAUNCH_LOG_DIR="${CONSOLE_HOME}/Library/Logs/Chronos"
    EXPECTED_MOUNT_POINT="/Volumes/${VOLUME_NAME}"
}

validate_setup() {
    require_command awk
    require_command date
    require_command dscl
    require_command launchctl
    require_command rm
    require_command rmdir
    require_command stat
    require_command tmutil

    [[ "$HELPER_DIR" = /* ]] || die "Helper directory must be an absolute path."
    [[ "$HELPER_DIR" != "/" ]] || die "Helper directory '/' is not allowed."
}

launch_agent_loaded() {
    launchctl print "gui/${CONSOLE_UID}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1
}

unload_launchagent() {
    info "Unloading LaunchAgent ${LAUNCH_AGENT_LABEL} if present."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "DRY RUN: launchctl bootout gui/${CONSOLE_UID} ${LAUNCH_AGENT_PATH}"
        return 0
    fi

    run_as_root launchctl bootout "gui/${CONSOLE_UID}" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
    run_as_root launchctl bootout "gui/${CONSOLE_UID}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true

    if launch_agent_loaded; then
        warn "LaunchAgent ${LAUNCH_AGENT_LABEL} still appears to be loaded."
    else
        info "LaunchAgent ${LAUNCH_AGENT_LABEL} is not loaded."
    fi
}

remove_file_if_present() {
    local path="$1"
    local description="$2"

    if [[ -e "$path" ]]; then
        info "Removing ${description}: ${path}"
        run_or_echo run_as_root rm -f "$path"
    else
        info "${description} not present: ${path}"
    fi
}

cleanup_logs() {
    if [[ "$REMOVE_LOGS" -ne 1 ]]; then
        info "Skipping log cleanup."
        return 0
    fi

    remove_file_if_present "${LAUNCH_LOG_DIR}/launchagent.out" "LaunchAgent stdout log"
    remove_file_if_present "${LAUNCH_LOG_DIR}/launchagent.err" "LaunchAgent stderr log"
    remove_file_if_present "${LAUNCH_LOG_DIR}/chronos-remount.log" "remount helper log"

    if [[ -d "$LAUNCH_LOG_DIR" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "DRY RUN: remove log directory if empty: ${LAUNCH_LOG_DIR}"
        else
            rmdir "$LAUNCH_LOG_DIR" >/dev/null 2>&1 || info "Keeping log directory ${LAUNCH_LOG_DIR} because it is not empty."
        fi
    fi
}

cleanup_helper_dir() {
    if [[ -d "$HELPER_DIR" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "DRY RUN: remove helper directory if empty: ${HELPER_DIR}"
        else
            run_as_root rmdir "$HELPER_DIR" >/dev/null 2>&1 || info "Keeping helper directory ${HELPER_DIR} because it is not empty."
        fi
    fi
}

remove_helper_assets() {
    if [[ "$REMOVE_HELPER_ASSETS" -ne 1 ]]; then
        info "Skipping helper asset removal."
        return 0
    fi

    unload_launchagent
    remove_file_if_present "$LAUNCH_AGENT_PATH" "LaunchAgent plist"
    remove_file_if_present "$HELPER_SCRIPT_PATH" "Chronos remount helper"
    remove_file_if_present "$LEGACY_APPLESCRIPT_PATH" "legacy Chronos AppleScript"
    cleanup_logs
    cleanup_helper_dir
}

matching_destination_ids() {
    tmutil destinationinfo 2>/dev/null | awk -v wanted_name="$VOLUME_NAME" -v wanted_mount="$EXPECTED_MOUNT_POINT" '
        /^=+/ || /^> =+/ {
            if (id != "" && (name == wanted_name || mount_point == wanted_mount)) {
                print id
            }
            name=""
            mount_point=""
            id=""
            next
        }
        /^Name[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            name=$0
            next
        }
        /^Mount Point[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            mount_point=$0
            next
        }
        /^ID[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            id=$0
            next
        }
        END {
            if (id != "" && (name == wanted_name || mount_point == wanted_mount)) {
                print id
            }
        }
    '
}

remove_tm_destinations() {
    if [[ "$REMOVE_TM_DESTINATION" -ne 1 ]]; then
        info "Skipping Time Machine destination removal."
        return 0
    fi

    local destination_ids=""
    destination_ids="$(matching_destination_ids || true)"

    if [[ -z "$destination_ids" ]]; then
        info "No matching Time Machine destination found for ${VOLUME_NAME} (${EXPECTED_MOUNT_POINT})."
        return 0
    fi

    info "Matching Time Machine destination IDs:"
    while IFS= read -r destination_id; do
        [[ -n "$destination_id" ]] || continue
        info "  ${destination_id}"
    done <<<"$destination_ids"

    if [[ "$ASSUME_YES" -ne 1 ]] && ! confirm_action "Remove matching Time Machine destination entries?"; then
        warn "Skipping Time Machine destination removal by user choice."
        return 0
    fi

    while IFS= read -r destination_id; do
        [[ -n "$destination_id" ]] || continue
        info "Removing Time Machine destination ${destination_id}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "DRY RUN: tmutil removedestination ${destination_id}"
        else
            run_as_root tmutil removedestination "$destination_id"
        fi
    done <<<"$destination_ids"
}

print_summary() {
    cat <<EOF
Summary
-------
LaunchAgent label : ${LAUNCH_AGENT_LABEL}
LaunchAgent path  : ${LAUNCH_AGENT_PATH}
Helper dir        : ${HELPER_DIR}
Volume name       : ${VOLUME_NAME}
Expected mount    : ${EXPECTED_MOUNT_POINT}
Dry run           : ${DRY_RUN}
Log file          : ${LOG_FILE}
EOF
}

main() {
    parse_args "$@"
    : >"$LOG_FILE"

    info "Chronos uninstall ${VERSION} starting."
    validate_setup
    prepare_context
    print_summary

    remove_tm_destinations
    remove_helper_assets

    info "Chronos uninstall completed."
}

main "$@"
