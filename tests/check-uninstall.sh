#!/bin/bash
# Exercises bin/chronos-gn-uninstall. The uninstaller deletes files on someone
# else's machine, so the properties worth guarding are mostly negative ones:
# --dry-run must remove nothing, the --keep-* flags must be honored, and no run
# may touch the sparsebundle or files the installer did not create.
#
# Two layers:
#   1. Unit  - source the script with its `main "$@"` line stripped and call
#              individual functions (the tmutil parser, config loader, lock wait).
#   2. Sandbox - run the real script end to end against a fake console-user home
#              with stubs for sudo/stat/dscl/launchctl/tmutil on PATH, then check
#              exactly which files survived.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="${REPO_ROOT}/bin/chronos-gn-uninstall"
WORK_DIR="$(mktemp -d)"
LIB="${WORK_DIR}/uninstall.lib.sh"
STUB_DIR="${WORK_DIR}/stubs"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
checks=0

ok() {
    checks=$((checks + 1))
    echo "ok: $*"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "FAIL: $*" >&2
}

assert_absent() {
    [[ ! -e "$1" ]] && ok "removed: ${1#"$WORK_DIR"/}" || fail "should have been removed: ${1#"$WORK_DIR"/}"
}

assert_present() {
    [[ -e "$1" ]] && ok "untouched: ${1#"$WORK_DIR"/}" || fail "should have survived: ${1#"$WORK_DIR"/}"
}

assert_eq() {
    local expected="$1" actual="$2" what="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$what"
    else
        fail "${what}: expected [${expected}], got [${actual}]"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$what"
    else
        fail "${what}: output did not contain '${needle}'"
    fi
}

# -------------------------------------------------------------------------
# Layer 1: source the script without running main()
# -------------------------------------------------------------------------
sed '/^main "\$@"$/d' "$UNINSTALL" >"$LIB"
if grep -q '^main "\$@"$' "$LIB"; then
    echo "FAIL: could not strip the main invocation" >&2
    exit 1
fi

DEST_TWO="${WORK_DIR}/dest-two.txt"
cat >"$DEST_TWO" <<'EOF'
====================================================
Name          : Time Machine Backups
Kind          : Network
URL           : smb://nas.example.com/TimeMachine
Mount Point   : /Volumes/Time Machine Backups
ID            : AAAA-1111
====================================================
Name          : Other Backup
Kind          : Local
Mount Point   : /Volumes/Other
ID            : BBBB-2222
EOF

DEST_BY_MOUNT="${WORK_DIR}/dest-by-mount.txt"
cat >"$DEST_BY_MOUNT" <<'EOF'
====================================================
Name          : Renamed In Finder
Kind          : Network
Mount Point   : /Volumes/Time Machine Backups
ID            : CCCC-3333
EOF

DEST_NONE="${WORK_DIR}/dest-none.txt"
cat >"$DEST_NONE" <<'EOF'
====================================================
Name          : Someone Elses Disk
Kind          : Local
Mount Point   : /Volumes/Someone Elses Disk
ID            : DDDD-4444
EOF

destination_ids_for() {
    local fixture="$1"
    (
        # shellcheck disable=SC1090
        source "$LIB" >/dev/null 2>&1
        IFS=$' \t\n'
        # Both are read by matching_destination_ids from the sourced script.
        # shellcheck disable=SC2034
        VOLUME_NAME="Time Machine Backups"
        # shellcheck disable=SC2034
        EXPECTED_MOUNT_POINT="/Volumes/Time Machine Backups"
        tmutil() { cat "$fixture"; }
        matching_destination_ids
    )
}

assert_eq "AAAA-1111" "$(destination_ids_for "$DEST_TWO")" \
    "destination parser matches on name and ignores the unrelated destination"
assert_eq "CCCC-3333" "$(destination_ids_for "$DEST_BY_MOUNT")" \
    "destination parser matches a renamed destination on its mount point"
assert_eq "" "$(destination_ids_for "$DEST_NONE")" \
    "destination parser matches nothing when no destination is ours"

# The config file is parsed, never sourced.
run_config_case() {
    local body="$1"
    local path="${WORK_DIR}/case.conf"
    printf '%s' "$body" >"$path"
    (
        # shellcheck disable=SC1090
        source "$LIB" >/dev/null 2>&1
        IFS=$' \t\n'
        load_config_file "$path" >/dev/null 2>&1 || exit 1
        printf 'HELPER_DIR=%s\nVOLUME_NAME=%s\nLABEL_PREFIX=%s\nLOG_FILE=%s\n' \
            "$HELPER_DIR" "$VOLUME_NAME" "$LABEL_PREFIX" "$LOG_FILE"
    )
}

config_out="$(run_config_case 'HELPER_DIR=/opt/chronos-gn
VOLUME_NAME="Time Machine Backups"
LABEL_PREFIX=com.example
# a comment
UNRELATED_INSTALLER_KEY=whatever
SIZE=100g
')"
assert_contains "$config_out" "HELPER_DIR=/opt/chronos-gn" "config sets HELPER_DIR"
assert_contains "$config_out" "VOLUME_NAME=Time Machine Backups" "config strips surrounding quotes"
assert_contains "$config_out" "LABEL_PREFIX=com.example" "config sets LABEL_PREFIX"

# Installer-only keys must be ignored rather than fatal, since both tools read
# the same file.
if [[ -n "$config_out" ]]; then
    ok "config file shared with the installer is accepted"
else
    fail "config file containing installer-only keys was rejected"
fi

rm -f "${WORK_DIR}/pwned"
inject_out="$(run_config_case 'VOLUME_NAME=$(touch '"${WORK_DIR}"'/pwned)
HELPER_DIR=`touch '"${WORK_DIR}"'/pwned2`
')"
if [[ -e "${WORK_DIR}/pwned" || -e "${WORK_DIR}/pwned2" ]]; then
    fail "config file achieved command execution"
else
    ok "config file cannot execute commands"
fi
assert_contains "$inject_out" 'VOLUME_NAME=$(touch' "command substitution stays a literal string"

if run_config_case 'HELPER_DIR /opt/chronos-gn
' >/dev/null 2>&1; then
    fail "config line without '=' was accepted"
else
    ok "config line without '=' is rejected"
fi

if run_config_case 'BAD-KEY=1
' >/dev/null 2>&1; then
    fail "invalid config key was accepted"
else
    ok "invalid config key is rejected"
fi

# A live remount helper must be waited out before its lock directory is taken.
lock_wait_result="$(
    (
        # shellcheck disable=SC1090
        source "$LIB" >/dev/null 2>&1
        IFS=$' \t\n'
        # Read by the sourced script's log(); keep this run quiet.
        # shellcheck disable=SC2034
        VERBOSE=0
        LOG_FILE=""

        lock="${WORK_DIR}/lock-dead"
        mkdir -p "$lock"
        echo "999999" >"${lock}/pid"
        start=$SECONDS
        wait_for_helper_lock_release "$lock"
        [[ $((SECONDS - start)) -le 1 ]] && echo "dead-ok"

        lock="${WORK_DIR}/lock-garbage"
        mkdir -p "$lock"
        echo "not-a-pid" >"${lock}/pid"
        start=$SECONDS
        wait_for_helper_lock_release "$lock"
        [[ $((SECONDS - start)) -le 1 ]] && echo "garbage-ok"

        lock="${WORK_DIR}/lock-live"
        mkdir -p "$lock"
        sleep 2 &
        echo "$!" >"${lock}/pid"
        start=$SECONDS
        wait_for_helper_lock_release "$lock"
        [[ $((SECONDS - start)) -ge 1 ]] && echo "live-ok"
    ) 2>/dev/null
)"
assert_contains "$lock_wait_result" "dead-ok" "lock wait returns at once for a dead helper pid"
assert_contains "$lock_wait_result" "garbage-ok" "lock wait returns at once for a garbage pid file"
assert_contains "$lock_wait_result" "live-ok" "lock wait blocks while a helper is still running"

# -------------------------------------------------------------------------
# Layer 2: argument validation (dies before touching the system)
# -------------------------------------------------------------------------
expect_rejected() {
    local message="$1"
    shift
    local out
    out="$(bash "$UNINSTALL" "$@" 2>&1 </dev/null)"
    if [[ $? -eq 0 ]]; then
        fail "expected failure for: $*"
        return
    fi
    assert_contains "$out" "$message" "rejects: $*"
}

expect_rejected "too broad"        --helper-dir /usr/local/lib -y
expect_rejected "too broad"        --helper-dir / -y
expect_rejected "too broad"        --helper-dir /etc -y
expect_rejected "absolute path"    --helper-dir relative/dir -y
expect_rejected "Invalid label prefix" --label-prefix "bad prefix" -y
expect_rejected "Unknown option"   --definitely-not-a-flag
expect_rejected "must be absolute" --log-file relative.log -y

ln -sf /dev/null "${WORK_DIR}/log-symlink"
expect_rejected "symlink" --log-file "${WORK_DIR}/log-symlink" -y

help_out="$(bash "$UNINSTALL" --help 2>&1 </dev/null)"
if [[ $? -eq 0 ]]; then
    ok "--help exits cleanly"
else
    fail "--help did not exit 0"
fi
assert_contains "$help_out" "sparsebundle itself is never deleted" \
    "--help states the sparsebundle is never deleted"

# -------------------------------------------------------------------------
# Layer 3: sandboxed end-to-end runs
# -------------------------------------------------------------------------
REAL_USER="$(id -un)"
mkdir -p "$STUB_DIR"

cat >"${STUB_DIR}/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF

# Only /dev/console is faked; every other stat call is the real one.
cat >"${STUB_DIR}/stat" <<EOF
#!/bin/bash
if [[ "\$*" == *"/dev/console" ]]; then
    printf '%s\n' "${REAL_USER}"
    exit 0
fi
exec /usr/bin/stat "\$@"
EOF

cat >"${STUB_DIR}/dscl" <<'EOF'
#!/bin/bash
# dscl . -read /Users/<user> NFSHomeDirectory
printf 'NFSHomeDirectory: %s\n' "${FAKE_HOME}"
EOF

cat >"${STUB_DIR}/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${STUB_LOG}/launchctl"
# `print` is the "is it loaded?" probe; report not loaded.
[[ "$1" != "print" ]]
EOF

cat >"${STUB_DIR}/tmutil" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${STUB_LOG}/tmutil"
if [[ "$1" == "destinationinfo" ]]; then
    cat "${TMUTIL_FIXTURE}"
fi
exit 0
EOF

chmod +x "${STUB_DIR}"/*

# Builds a fresh fake install under $1 and echoes nothing; callers use the
# well-known paths below.
build_sandbox() {
    local root="$1"
    local stray_log="${2:-0}"

    rm -rf "$root"
    mkdir -p "${root}/home/Library/LaunchAgents"
    mkdir -p "${root}/home/Library/Logs/chronos-gn"
    mkdir -p "${root}/helper"
    mkdir -p "${root}/share/host_AABBCC.sparsebundle/bands"
    mkdir -p "${root}/stublog"

    echo "plist" >"${root}/home/Library/LaunchAgents/io.github.test.chronos-gn.plist"
    echo "not ours" >"${root}/home/Library/LaunchAgents/com.example.somethingelse.plist"

    local logs="${root}/home/Library/Logs/chronos-gn"
    for f in chronos-gn.log chronos-gn-monitor.out chronos-gn-monitor.err \
             chronos-gn-remount.log chronos-gn-remount-monitor.log \
             chronos-gn-gui-mount.state; do
        echo "x" >"${logs}/${f}"
    done
    mkdir -p "${logs}/chronos-gn-remount.lock"
    echo "999999" >"${logs}/chronos-gn-remount.lock/pid"
    [[ "$stray_log" -eq 1 ]] && echo "keep me" >"${logs}/someone-elses.log"

    echo "helper" >"${root}/helper/chronos-gn-remount.sh"
    echo "monitor" >"${root}/helper/chronos-gn-remount-monitor.sh"
    echo "legacy" >"${root}/helper/chronos.scpt"

    echo "irreplaceable backup history" >"${root}/share/host_AABBCC.sparsebundle/bands/0001"
    echo "plist" >"${root}/share/host_AABBCC.sparsebundle/Info.plist"

    return 0
}

# Runs the uninstaller against a sandbox. Extra args are passed through.
run_sandbox() {
    local root="$1"
    shift
    PATH="${STUB_DIR}:${PATH}" \
    FAKE_HOME="${root}/home" \
    STUB_LOG="${root}/stublog" \
    TMUTIL_FIXTURE="$DEST_TWO" \
        bash "$UNINSTALL" \
            --helper-dir "${root}/helper" \
            --label-prefix io.github.test \
            --name "Time Machine Backups" \
            --log-file "${root}/uninstall.log" \
            -v "$@" 2>&1 </dev/null
}

stub_log() {
    cat "${1}/stublog/${2}" 2>/dev/null || true
}

echo
echo "--- sandbox: --dry-run changes nothing ---"
SB="${WORK_DIR}/sb-dry"
build_sandbox "$SB"
dry_out="$(run_sandbox "$SB" --dry-run -y)"
dry_status=$?
assert_eq "0" "$dry_status" "dry run exits 0"
assert_present "${SB}/home/Library/LaunchAgents/io.github.test.chronos-gn.plist"
assert_present "${SB}/home/Library/Logs/chronos-gn/chronos-gn.log"
assert_present "${SB}/home/Library/Logs/chronos-gn/chronos-gn-remount.lock"
assert_present "${SB}/helper/chronos-gn-remount.sh"
assert_present "${SB}/helper/chronos-gn-remount-monitor.sh"
assert_present "${SB}/helper/chronos.scpt"
assert_present "${SB}/helper"
assert_present "${SB}/share/host_AABBCC.sparsebundle/bands/0001"
assert_contains "$dry_out" "DRY RUN" "dry run announces itself"
if [[ "$(stub_log "$SB" tmutil)" == *"removedestination"* ]]; then
    fail "dry run called tmutil removedestination"
else
    ok "dry run does not call tmutil removedestination"
fi
if [[ "$(stub_log "$SB" launchctl)" == *"bootout"* ]]; then
    fail "dry run called launchctl bootout"
else
    ok "dry run does not call launchctl bootout"
fi

echo
echo "--- sandbox: full removal ---"
SB="${WORK_DIR}/sb-full"
build_sandbox "$SB"
full_out="$(run_sandbox "$SB" -y)"
full_status=$?
assert_eq "0" "$full_status" "full run exits 0"

assert_absent "${SB}/home/Library/LaunchAgents/io.github.test.chronos-gn.plist"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn.log"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-monitor.out"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-monitor.err"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-remount.log"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-remount-monitor.log"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-gui-mount.state"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn-remount.lock"
assert_absent "${SB}/home/Library/Logs/chronos-gn"
assert_absent "${SB}/helper/chronos-gn-remount.sh"
assert_absent "${SB}/helper/chronos-gn-remount-monitor.sh"
assert_absent "${SB}/helper/chronos.scpt"
assert_absent "${SB}/helper"

# The whole point of the uninstaller's contract.
assert_present "${SB}/share/host_AABBCC.sparsebundle"
assert_present "${SB}/share/host_AABBCC.sparsebundle/bands/0001"
assert_present "${SB}/share/host_AABBCC.sparsebundle/Info.plist"
assert_present "${SB}/home/Library/LaunchAgents/com.example.somethingelse.plist"
assert_present "${SB}/home/Library/LaunchAgents"

tm_calls="$(stub_log "$SB" tmutil)"
assert_contains "$tm_calls" "removedestination AAAA-1111" "removes the matching Time Machine destination"
if [[ "$tm_calls" == *"BBBB-2222"* ]]; then
    fail "removed an unrelated Time Machine destination"
else
    ok "leaves the unrelated Time Machine destination alone"
fi
assert_contains "$(stub_log "$SB" launchctl)" "bootout" "unloads the LaunchAgent"
assert_contains "$full_out" "sparsebundle was not removed" "reports that the sparsebundle was kept"

echo
echo "--- sandbox: a stray file keeps the log directory ---"
SB="${WORK_DIR}/sb-stray"
build_sandbox "$SB" 1
run_sandbox "$SB" -y >/dev/null
assert_present "${SB}/home/Library/Logs/chronos-gn/someone-elses.log"
assert_present "${SB}/home/Library/Logs/chronos-gn"
assert_absent "${SB}/home/Library/Logs/chronos-gn/chronos-gn.log"

echo
echo "--- sandbox: --keep-* flags ---"
SB="${WORK_DIR}/sb-keep-helpers"
build_sandbox "$SB"
run_sandbox "$SB" -y --keep-helper-assets >/dev/null
assert_present "${SB}/home/Library/LaunchAgents/io.github.test.chronos-gn.plist"
assert_present "${SB}/helper/chronos-gn-remount.sh"
assert_present "${SB}/home/Library/Logs/chronos-gn/chronos-gn.log"
assert_contains "$(stub_log "$SB" tmutil)" "removedestination AAAA-1111" \
    "--keep-helper-assets still removes the Time Machine destination"

SB="${WORK_DIR}/sb-keep-logs"
build_sandbox "$SB"
run_sandbox "$SB" -y --keep-logs >/dev/null
assert_present "${SB}/home/Library/Logs/chronos-gn/chronos-gn.log"
assert_present "${SB}/home/Library/Logs/chronos-gn/chronos-gn-remount.lock"
assert_absent "${SB}/helper/chronos-gn-remount.sh"
assert_absent "${SB}/home/Library/LaunchAgents/io.github.test.chronos-gn.plist"

SB="${WORK_DIR}/sb-keep-dest"
build_sandbox "$SB"
run_sandbox "$SB" -y --keep-tm-destination >/dev/null
if [[ "$(stub_log "$SB" tmutil)" == *"removedestination"* ]]; then
    fail "--keep-tm-destination still removed the destination"
else
    ok "--keep-tm-destination leaves the destination in place"
fi
assert_absent "${SB}/helper/chronos-gn-remount.sh"

echo
echo "--- sandbox: destination removal is gated ---"
SB="${WORK_DIR}/sb-noconfirm"
build_sandbox "$SB"
noconfirm_out="$(run_sandbox "$SB")"
if [[ "$(stub_log "$SB" tmutil)" == *"removedestination"* ]]; then
    fail "removed a Time Machine destination without confirmation on a non-tty"
else
    ok "declines to remove the destination without -y on a non-tty"
fi
assert_contains "$noconfirm_out" "user choice" "explains why the destination was kept"

SB="${WORK_DIR}/sb-othervolume"
build_sandbox "$SB"
PATH="${STUB_DIR}:${PATH}" FAKE_HOME="${SB}/home" STUB_LOG="${SB}/stublog" \
TMUTIL_FIXTURE="$DEST_TWO" \
    bash "$UNINSTALL" --helper-dir "${SB}/helper" --label-prefix io.github.test \
        --name "A Volume Nobody Has" --log-file "${SB}/uninstall.log" -v -y \
        >/dev/null 2>&1 </dev/null
if [[ "$(stub_log "$SB" tmutil)" == *"removedestination"* ]]; then
    fail "removed a destination that does not match the requested volume name"
else
    ok "removes no destination when the volume name does not match"
fi

echo
if [[ "$failures" -gt 0 ]]; then
    echo "${failures} of ${checks} checks failed" >&2
    exit 1
fi
echo "All ${checks} uninstaller checks passed."
