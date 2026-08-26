#!/bin/bash
# Shared helpers for pulling the scripts that chronos-gn writes at install time
# back out of their heredocs so tests can run them. Sourced by the checks in
# this directory; not executable on its own.

# Captures the body of the heredoc that write_file_atomically feeds into the
# named destination variable.
extract_block() {
    local source_script="$1"
    local marker="$2"
    local out="$3"

    awk -v marker="$marker" '
        $0 ~ ("write_file_atomically \\\"\\$" marker "\\\"") { capture=1; next }
        capture && /^EOF$/ { exit }
        capture { print }
    ' "$source_script" >"$out"

    [[ -s "$out" ]] || { echo "could not extract ${marker} block" >&2; return 1; }
}

# Emulate what an unquoted heredoc does: \$ -> $, \\ -> \, \` -> `
unescape() {
    sed -e 's/\\\$/$/g' -e 's/\\`/`/g' -e 's/\\\\/\\/g' "$1"
}

# Stand-in values for what the installer interpolates.
substitute() {
    sed \
        -e 's|${LAUNCH_LOG_DIR}|/tmp/chronos-gn-logs|g' \
        -e 's|${APP_NAME}|chronos-gn|g' \
        -e 's|${NETWORK_URL}|smb://nas.example.com/TimeMachine|g' \
        -e 's|${network_url_applescript}|smb://nas.example.com/TimeMachine|g' \
        -e 's|${SHARE_HOST}|nas.example.com|g' \
        -e 's|${SHARE_PORT}|445|g' \
        -e 's|${DESTINATION}|/Volumes/TimeMachine|g' \
        -e 's|${BUNDLE_PATH}|/Volumes/TimeMachine/host_AABBCC.sparsebundle|g' \
        -e 's|${VOLUME_NAME}|Time Machine Backups|g' \
        -e 's|${HELPER_SCRIPT_PATH}|/usr/local/lib/chronos-gn/chronos-gn-remount.sh|g' \
        -e 's|${MONITOR_SCRIPT_PATH}|/usr/local/lib/chronos-gn/chronos-gn-remount-monitor.sh|g' \
        -e 's|${LAUNCH_AGENT_LABEL}|io.github.example.chronos-gn|g' \
        -e 's|${LAUNCH_INTERVAL}|300|g' \
        -e 's|${GUI_MOUNT_COOLDOWN}|1800|g' \
        -e 's|${BACKUP_ALERT_DAYS}|7|g' \
        "$1"
}

# extract -> unescape -> substitute, leaving a runnable script at $4.
render_block() {
    local source_script="$1"
    local marker="$2"
    local work_dir="$3"
    local out="$4"

    extract_block "$source_script" "$marker" "${work_dir}/${marker}.raw" || return 1
    unescape "${work_dir}/${marker}.raw" >"${work_dir}/${marker}.unescaped"
    substitute "${work_dir}/${marker}.unescaped" >"$out"
}
