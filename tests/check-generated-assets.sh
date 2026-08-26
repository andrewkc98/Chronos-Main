#!/bin/bash
# Extracts the helper, monitor, and LaunchAgent plist that chronos-gn writes at
# install time and checks each one parses. Without this, a syntax error inside a
# heredoc only shows up on a real install, after the sparsebundle already exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/bin/chronos-gn"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck source=tests/lib-extract.sh
source "${REPO_ROOT}/tests/lib-extract.sh"

failures=0

render() {
    local marker="$1"
    local out="${WORK_DIR}/${marker}.rendered"

    render_block "$SOURCE_SCRIPT" "$marker" "$WORK_DIR" "$out" || return 1
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
