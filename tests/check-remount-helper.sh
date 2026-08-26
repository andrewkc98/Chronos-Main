#!/bin/bash
# Unit-tests the remount helper that chronos-gn writes at install time.
#
# The helper runs under `set -euo pipefail`, which makes any `cmd | grep -q`
# construct silently unreliable: grep exits at the first match, the writer takes
# SIGPIPE, and pipefail promotes that 141 to the pipeline's status -- so a
# successful match reports failure. That defect made the helper believe the
# sparsebundle was never attached, which is what left stale attachments behind a
# password dialog nobody could satisfy. These checks pin the behavior down.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/bin/chronos-gn"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck source=tests/lib-extract.sh
source "${REPO_ROOT}/tests/lib-extract.sh"

BUNDLE="/Volumes/TimeMachine/host_AABBCC.sparsebundle"
STUB_DIR="${WORK_DIR}/stubs"
mkdir -p "$STUB_DIR"

failures=0
checks=0

ok() { checks=$((checks + 1)); echo "ok: $*"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL: $*" >&2; }

# The helper's function definitions only. Its top-level run begins at the
# "remount check started" log line; the lock trap and acquire_lock call sit
# above that, interleaved with definitions, so drop those three constructs
# rather than truncating at them.
HELPER_FUNCS="${WORK_DIR}/helper-functions.sh"
render_block "$SOURCE_SCRIPT" "HELPER_SCRIPT_PATH" "$WORK_DIR" "${WORK_DIR}/helper.rendered" || exit 1
awk '
    /^log INFO "chronos-gn remount check started"/ { exit }
    /^trap cleanup_lock EXIT/                      { next }
    /^if ! acquire_lock; then$/                    { skip = 3 }
    skip > 0                                       { skip--; next }
    { print }
' "${WORK_DIR}/helper.rendered" >"$HELPER_FUNCS"

# Assert up front that every function under test survived extraction. Without
# this, a definition that lands below the cut point silently becomes undefined
# and the checks below pass vacuously.
for fn in bundle_is_attached mounted_state_healthy gui_mount_prompt_pending \
          detach_stale_attachment note_gui_prompt_seen warn_if_gui_prompt_stuck; do
    if ! grep -q "^${fn}()" "$HELPER_FUNCS"; then
        echo "FAIL: ${fn} not found in the extracted helper" >&2
        exit 1
    fi
done

if grep -q "^acquire_lock\b" "$HELPER_FUNCS" && grep -q "^if ! acquire_lock" "$HELPER_FUNCS"; then
    echo "FAIL: extraction left the top-level acquire_lock call in place" >&2
    exit 1
fi

# The helper calls hdiutil by absolute path, so point it at the stub rather than
# relying on PATH.
sed -i '' "s|/usr/bin/hdiutil|${STUB_DIR}/hdiutil|g" "$HELPER_FUNCS"

# hdiutil info output big enough to overrun the pipe buffer, with the match near
# the top so a `grep -q` reader exits while the writer still has work to do.
# This is what a real machine with several attached images looks like.
make_hdiutil_stub() {
    local match="$1"
    cat >"${STUB_DIR}/hdiutil" <<STUB
#!/bin/bash
if [[ "\$1" == "info" ]]; then
    echo "framework       : 671.100.4"
    echo "driver          : 671.100.4"
    if [[ "${match}" == "yes" ]]; then
        echo "image-path      : ${BUNDLE}"
        echo "image-alias     : ${BUNDLE}"
    fi
    # Bulk filler standing in for other attached images.
    i=0
    while [[ \$i -lt 6000 ]]; do
        echo "image-path      : /Volumes/Other/filler-\${i}.dmg padding padding padding padding"
        i=\$((i + 1))
    done
    exit 0
fi
exit 0
STUB
    chmod +x "${STUB_DIR}/hdiutil"
}

run_bundle_is_attached() {
    (
        # shellcheck disable=SC1090
        source "$HELPER_FUNCS" >/dev/null 2>&1
        LOG_FILE="${WORK_DIR}/helper.log"
        BUNDLE_PATH="$BUNDLE"
        if bundle_is_attached; then echo attached; else echo "not-attached"; fi
    ) 2>/dev/null
}

echo "--- bundle_is_attached ---"

make_hdiutil_stub yes
result="$(run_bundle_is_attached)"
if [[ "$result" == "attached" ]]; then
    ok "reports attached when hdiutil info lists the bundle (large output, pipefail on)"
else
    fail "reported '${result}' for an attached bundle -- SIGPIPE/pipefail defect"
fi

make_hdiutil_stub no
result="$(run_bundle_is_attached)"
if [[ "$result" == "not-attached" ]]; then
    ok "reports not attached when hdiutil info omits the bundle"
else
    fail "reported '${result}' for a bundle that is not attached"
fi

# Same check with a tiny hdiutil output. This passes even with the defect
# present, which is exactly why the bug was intermittent -- keep it so a fix
# cannot regress the small-output case either.
cat >"${STUB_DIR}/hdiutil" <<STUB
#!/bin/bash
[[ "\$1" == "info" ]] && echo "image-path      : ${BUNDLE}"
exit 0
STUB
chmod +x "${STUB_DIR}/hdiutil"
result="$(run_bundle_is_attached)"
if [[ "$result" == "attached" ]]; then
    ok "reports attached when hdiutil info is small enough to fit the pipe buffer"
else
    fail "reported '${result}' for an attached bundle with small hdiutil output"
fi

echo
echo "--- mounted_state_healthy: a pending prompt means wait, not detach ---"

# Drives mounted_state_healthy with the surrounding predicates stubbed out.
# $1 mounted, $2 volume answers reads, $3 bundle attached, $4 prompt pending.
run_mounted_state_healthy() {
    local mounted="$1" answers="$2" attached="$3" prompt="$4"
    rm -f "${WORK_DIR}/detached"
    (
        # shellcheck disable=SC1090
        source "$HELPER_FUNCS" >/dev/null 2>&1
        # All three are read by the sourced helper, not by this test.
        # shellcheck disable=SC2034
        LOG_FILE="${WORK_DIR}/helper.log"
        # shellcheck disable=SC2034
        BUNDLE_PATH="$BUNDLE"
        # shellcheck disable=SC2034
        VOLUME_MOUNT_POINT="/Volumes/Time Machine Backups"

        is_mountpoint() { [[ "$mounted" == "yes" ]]; }
        probe_path_with_timeout() { [[ "$answers" == "yes" ]]; }
        bundle_is_attached() { [[ "$attached" == "yes" ]]; }
        gui_mount_prompt_pending() { [[ "$prompt" == "yes" ]]; }
        detach_stale_attachment() { echo yes >"${WORK_DIR}/detached"; }

        if mounted_state_healthy; then echo "healthy"; else echo "not-healthy"; fi
    ) 2>/dev/null
}

detached_p() { [[ -f "${WORK_DIR}/detached" ]] && echo yes || echo no; }

result="$(run_mounted_state_healthy no no yes yes)"
if [[ "$(detached_p)" == "no" && "$result" == "not-healthy" ]]; then
    ok "attached with a prompt open: waits, does not detach"
else
    fail "attached with a prompt open: detached=$(detached_p) result=${result} -- this is the bug that poisons the dialog"
fi

result="$(run_mounted_state_healthy no no yes no)"
if [[ "$(detached_p)" == "yes" && "$result" == "not-healthy" ]]; then
    ok "attached with no prompt open: reconciles the stale attachment"
else
    fail "attached with no prompt: detached=$(detached_p) result=${result}"
fi

result="$(run_mounted_state_healthy yes no no yes)"
if [[ "$(detached_p)" == "no" ]]; then
    ok "mounted but unresponsive with a prompt open: leaves the attachment alone"
else
    fail "mounted but unresponsive with a prompt open: detached anyway"
fi

result="$(run_mounted_state_healthy yes no no no)"
if [[ "$(detached_p)" == "yes" ]]; then
    ok "mounted but unresponsive with no prompt: detaches for remount"
else
    fail "mounted but unresponsive with no prompt: did not detach"
fi

result="$(run_mounted_state_healthy yes yes no no)"
if [[ "$(detached_p)" == "no" && "$result" == "healthy" ]]; then
    ok "mounted and answering reads: reports healthy, detaches nothing"
else
    fail "mounted and healthy: detached=$(detached_p) result=${result}"
fi

echo
echo "--- class guards ---"

# The SIGPIPE/pipefail hazard is a class of bug, not one line. Both generated
# scripts run under pipefail, so no `cmd | grep -q` may reappear in either.
render_block "$SOURCE_SCRIPT" "MONITOR_SCRIPT_PATH" "$WORK_DIR" "${WORK_DIR}/monitor.rendered" || exit 1
offenders="$(grep -nE '\|[[:space:]]*(/usr/bin/)?grep[[:space:]]+-[A-Za-z]*q' "${WORK_DIR}/helper.rendered" "${WORK_DIR}/monitor.rendered" || true)"
if [[ -z "$offenders" ]]; then
    ok "no 'cmd | grep -q' pipelines in the generated helper or monitor"
else
    fail "pipefail-unsafe grep -q pipeline reintroduced:"$'\n'"${offenders}"
fi

for script in helper monitor; do
    if grep -q '^set -euo pipefail' "${WORK_DIR}/${script}.rendered"; then
        ok "generated ${script} still runs under set -euo pipefail"
    else
        fail "generated ${script} lost 'set -euo pipefail'; the guards above assume it"
    fi
done

# The monitor clamps HELPER_TIMEOUT_SECONDS by calling log(). Calling it before
# log() is defined kills the monitor at load time under set -e.
log_def_line="$(grep -n '^log()' "${WORK_DIR}/monitor.rendered" | head -1 | cut -d: -f1)"
clamp_line="$(grep -n 'Helper timeout floored' "${WORK_DIR}/monitor.rendered" | head -1 | cut -d: -f1)"
if [[ -n "$log_def_line" && -n "$clamp_line" ]] && [[ "$clamp_line" -gt "$log_def_line" ]]; then
    ok "monitor defines log() before the helper-timeout clamp uses it"
else
    fail "monitor calls log() at line ${clamp_line:-?} before it is defined at line ${log_def_line:-?}"
fi

echo
if [[ "$failures" -gt 0 ]]; then
    echo "${failures} of ${checks} checks failed" >&2
    exit 1
fi
echo "All ${checks} remount helper checks passed."
