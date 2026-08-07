#!/usr/bin/env bash
# Host-side runner for the target-side smoke/check scripts.
#
# The scripts under scripts/{ota,container}/*-target.sh (and
# ota-fit-slot-check.sh) read the DEVICE's own /proc/cmdline, `rauc status`,
# `uname`, /boot, dmesg, etc. — they only produce meaningful results when run
# ON the gateway. Running them directly on your workstation fails at slot
# detection ("could not determine active RAUC slot"). This runner pipes each
# one to a live gateway over SSH ("ssh <host> 'bash -s' < script") and
# aggregates PASS/FAIL, so you drive them from the host with just the device IP.
#
# Usage:
#   scripts/run-target-checks.sh <device-host-or-ip> [check ...]
#   IOTGW_TARGET=<device-ip> scripts/run-target-checks.sh
#   scripts/run-target-checks.sh <device-ip> ota-fit-slot ota-smoke
#   scripts/run-target-checks.sh --list
#
# With no check names, runs the default smoke set (ota-fit-slot ota-smoke
# container-smoke exposure). ota-bench is excluded from the default set (it is
# a benchmark, not a pass/fail check) but can be named explicitly.
#
# The "exposure" check asserts listen scope, address family, and firewall
# qualification. It cannot test off-device reachability - a device cannot prove
# its own; pair it with scripts/security/exposure-probe-host.sh from a second
# host.
#
# Environment overrides:
#   IOTGW_TARGET     device host/IP (used if no positional host is given)
#   IOTGW_SSH_USER   SSH user (default: root)
#   IOTGW_SSH_OPTS   SSH options (default disables strict host-key checking,
#                    because the gateway's host key changes per A/B slot)
#
# Exit status: 0 if every selected check passed; non-zero if any check
# failed or could not be run (matches each target script's own exit contract).

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# check-name -> relative script path (single source of truth for the registry)
check_path() {
    case "$1" in
        ota-fit-slot)    echo "ota/ota-fit-slot-check.sh" ;;
        ota-smoke)       echo "ota/ota-smoke-target.sh" ;;
        container-smoke) echo "container/container-smoke-target.sh" ;;
        ota-bench)       echo "ota/ota-bench-target.sh" ;;
        exposure)        echo "security/exposure-target.sh" ;;
        *)               return 1 ;;
    esac
}
ALL_CHECKS="ota-fit-slot ota-smoke container-smoke ota-bench exposure"
DEFAULT_CHECKS="ota-fit-slot ota-smoke container-smoke exposure"

usage() {
    sed -nE 's/^# ?//p' "${BASH_SOURCE[0]}" | sed -n '1,33p'
}

list_checks() {
    printf 'Available checks (name -> script):\n'
    for c in $ALL_CHECKS; do
        printf '  %-16s %s\n' "$c" "scripts/$(check_path "$c")"
    done
    printf '\nDefault set: %s\n' "$DEFAULT_CHECKS"
}

case "${1:-}" in
    -h|--help)  usage; exit 0 ;;
    --list)     list_checks; exit 0 ;;
esac

# Resolve target host: first positional arg, else IOTGW_TARGET.
TARGET=""
if [ "${1:-}" != "" ] && [ "${1#-}" = "${1:-}" ]; then
    TARGET="$1"
    shift
fi
TARGET="${TARGET:-${IOTGW_TARGET:-}}"
if [ -z "$TARGET" ]; then
    printf 'error: no device host/IP given (pass as first arg or set IOTGW_TARGET)\n\n' >&2
    usage >&2
    exit 2
fi

SSH_USER="${IOTGW_SSH_USER:-root}"
# Per-slot host key changes across A/B, so default to not pinning it.
DEFAULT_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
# shellcheck disable=SC2206
SSH_OPTS=(${IOTGW_SSH_OPTS:-$DEFAULT_SSH_OPTS})

# Non-root users need sudo for the privileged checks; root does not.
REMOTE_CMD="bash -s"
[ "$SSH_USER" != "root" ] && REMOTE_CMD="sudo bash -s"

# Selected checks: remaining args, else the default set.
if [ "$#" -gt 0 ]; then
    SELECTED="$*"
else
    SELECTED="$DEFAULT_CHECKS"
fi

# Validate names up front so a typo fails fast, before touching the device.
for c in $SELECTED; do
    if ! rel=$(check_path "$c"); then
        printf "error: unknown check '%s' (see --list)\n" "$c" >&2
        exit 2
    fi
    if [ ! -r "${SCRIPT_DIR}/${rel}" ]; then
        printf "error: check '%s' script missing: %s\n" "$c" "scripts/${rel}" >&2
        exit 2
    fi
done

printf '== target-checks on %s@%s ==\n' "$SSH_USER" "$TARGET"

overall_rc=0
ran=0
failed_list=""
for c in $SELECTED; do
    rel=$(check_path "$c")
    script="${SCRIPT_DIR}/${rel}"
    printf '\n────────────────────────────────────────\n# check: %s  (scripts/%s)\n────────────────────────────────────────\n' "$c" "$rel"
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET}" "$REMOTE_CMD" < "$script"; then
        printf '# check %s: PASS\n' "$c"
    else
        rc=$?
        printf '# check %s: FAIL (exit %d)\n' "$c" "$rc"
        overall_rc=1
        failed_list="${failed_list} ${c}"
    fi
    ran=$((ran + 1))
done

printf '\n==================== RESULT ====================\n'
printf 'ran %d check(s) on %s\n' "$ran" "$TARGET"
if [ "$overall_rc" -eq 0 ]; then
    printf 'ALL PASSED\n'
else
    printf 'FAILED:%s\n' "$failed_list"
fi
exit "$overall_rc"
