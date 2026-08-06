#!/bin/bash
# Extracts the helper, monitor, and LaunchAgent plist that chronos-gn writes at
# install time and checks each one parses. Without this, a syntax error inside a
# heredoc only shows up on a real install, after the sparsebundle already exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/bin/chronos-gn"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

extract_block() {
    local marker="$1"
    local out="$2"

    awk -v marker="$marker" '
        $0 ~ ("write_file_atomically \\\"\\$" marker "\\\"") { capture=1; next }
        capture && /^EOF$/ { exit }
        capture { print }
    ' "$SOURCE_SCRIPT" >"$out"

    [[ -s "$out" ]] || { echo "FAIL: could not extract ${marker} block" >&2; return 1; }
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
        "$1"
}

render() {
    local marker="$1"
    local out="${WORK_DIR}/${marker}.rendered"

    extract_block "$marker" "${WORK_DIR}/${marker}.raw"
    unescape "${WORK_DIR}/${marker}.raw" >"${WORK_DIR}/${marker}.unescaped"
    substitute "${WORK_DIR}/${marker}.unescaped" >"$out"
    printf '%s' "$out"
}

check_shell() {
    local marker="$1"
    local rendered

    rendered="$(render "$marker")"

    if bash -n "$rendered"; then
        echo "ok: generated ${marker} parses as bash"
    else
        echo "FAIL: generated ${marker} has a bash syntax error" >&2
        failures=$((failures + 1))
    fi

    if grep -q '\${[A-Za-z_]' "$rendered"; then
        # Runtime variables in the generated script are written \${...} and survive
        # unescaping as ${...}, so this is informational only.
        :
    fi
}

check_plist() {
    local rendered
    rendered="$(render "LAUNCH_AGENT_PATH")"

    if plutil -lint "$rendered" >/dev/null; then
        echo "ok: generated LaunchAgent plist is valid"
    else
        echo "FAIL: generated LaunchAgent plist is invalid" >&2
        failures=$((failures + 1))
    fi

    for key in Label ProgramArguments RunAtLoad KeepAlive LimitLoadToSessionType; do
        if ! grep -q "<key>${key}</key>" "$rendered"; then
            echo "FAIL: generated plist is missing <key>${key}</key>" >&2
            failures=$((failures + 1))
        fi
    done

    if ! grep -q "<string>Aqua</string>" "$rendered"; then
        echo "FAIL: generated plist does not limit loading to the Aqua session" >&2
        failures=$((failures + 1))
    fi
}

check_shell HELPER_SCRIPT_PATH
check_shell MONITOR_SCRIPT_PATH
check_plist

if [[ "$failures" -gt 0 ]]; then
    echo "${failures} check(s) failed" >&2
    exit 1
fi

echo "All generated assets check out."
