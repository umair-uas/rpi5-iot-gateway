#!/usr/bin/env bash
# Off-device reachability oracle for the IoT Gateway.
#
# A device cannot prove its own external reachability: its own view of listeners
# and firewall rules is exactly the view that can be wrong. This script runs on
# a SECOND host and answers the only question that matters, what actually
# accepts a connection from somewhere else.
#
# Non-destructive by construction: TCP connect only. No authentication attempt,
# no HTTP request, no state-changing call. A successful connect is closed
# immediately.
#
# Usage:
#   scripts/security/exposure-probe-host.sh --v4 <addr> [--v6 <addr>] [--otbr] [--ports "22 80 ..."]
#
# Addresses are ARGUMENTS ONLY and have no defaults, this repo is public, and a
# baked-in address would leak the deployment. Get them from the device (strip
# the /prefix, these commands print CIDR, not a bare address):
#   ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1
#   ip -6 -o addr show scope global | awk '{print $4}' | cut -d/ -f1
#
# --otbr: this image was built with IOTGW_ENABLE_OTBR=1, so ports 80/8081
# are expected open. It defaults off, matching the distro's own default;
# without it, 80/8081 are reported as INFO (observed, not asserted), since
# this host has no way to know whether the target image has OTBR at all.
#
# Exit status: 0 if the observed reachability matches the expected policy
# (IPv4 management reachable, IPv6 not) AND every asserted probe returned a
# decisive result, non-zero otherwise. A probe that could not run at all (bad
# address, no route, DNS failure) is a FAIL, never a silent pass.
#
# Expected policy after the IPv4-only listener pin:
#   v4: 22 open (management), 80/8081 open only with --otbr, 1883 filtered,
#       443 closed
#   v6: nothing open

set -u

V4=""
V6=""
OTBR=0
PORTS="22 80 443 1883 8081"
TIMEOUT=3

usage() { sed -nE 's/^# ?//p' "${BASH_SOURCE[0]}" | sed -n '1,33p'; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --v4)      V4="${2:-}"; shift 2 ;;
        --v6)      V6="${2:-}"; shift 2 ;;
        --otbr)    OTBR=1; shift ;;
        --ports)   PORTS="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'error: unknown argument %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$V4" ] && [ -z "$V6" ]; then
    printf 'error: give at least --v4 or --v6 (no defaults; see --help)\n\n' >&2
    usage >&2
    exit 2
fi

# --ports/--timeout are spliced into a bash -c string below (to reach
# /dev/tcp); reject anything non-numeric here rather than pass operator input
# through to a shell command string unvalidated.
if ! is_uint "$TIMEOUT" || [ "$TIMEOUT" -eq 0 ]; then
    printf 'error: --timeout must be a positive integer, got %s\n' "$TIMEOUT" >&2
    exit 2
fi
for _p in $PORTS; do
    if ! is_uint "$_p" || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
        printf 'error: --ports must be space-separated integers 1-65535, got %s\n' "$_p" >&2
        exit 2
    fi
done

PASS=0
FAIL=0

say_pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
say_fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
say_info() { printf '  \e[36mINFO\e[0m %s\n' "$1"; }

# ICMP reachability gate. A TCP connect that times out is ambiguous by itself:
# this device's own firewall policy is DROP, not REJECT, so "port filtered by
# policy" and "address unreachable" produce the identical symptom (no reply
# before our timeout). Confirming basic reachability first means a later TCP
# timeout can be read as "filtered", not "who knows".
reachable() {
    local addr="$1"
    case "$addr" in
        *:*) ping -6 -c 1 -W "$TIMEOUT" "$addr" >/dev/null 2>&1 ;;
        *)   ping -4 -c 1 -W "$TIMEOUT" "$addr" >/dev/null 2>&1 ;;
    esac
}

# Bash's /dev/tcp does NOT accept bracketed IPv6 literals ("[::1]" fails
# name resolution outright, confirmed empirically); it wants the bare address.
# Prints one of: open | closed | filtered | error: <reason>
probe() {
    local addr="$1" port="$2" out rc
    out=$(timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${addr}/${port}" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "open"
        return
    fi
    if [ "$rc" -eq 124 ]; then
        echo "filtered"   # no reply within timeout; caller gates this on reachable()
        return
    fi
    case "$out" in
        *"Connection refused"*)
            echo "closed" ;;
        *"Name or service not known"*|*"Temporary failure in name resolution"*)
            echo "error: name resolution failed for ${addr}" ;;
        *"No route to host"*|*"Network is unreachable"*)
            echo "error: no route to ${addr}" ;;
        *"Invalid argument"*)
            echo "error: invalid address syntax for /dev/tcp: ${addr}" ;;
        *)
            echo "error: unrecognized /dev/tcp failure: ${out:-<no output>}" ;;
    esac
}

# expect: "open", "closed" (closed accepts either a refusal or, once
# reachability is confirmed, a firewall-filtered timeout as equivalent), or
# "either" to report the observed state as INFO without a pass/fail verdict.
assert() {
    local family="$1" addr="$2" port="$3" expect="$4" state

    if ! reachable "$addr"; then
        say_fail "${family} tcp/${port}: host unreachable (ping failed), cannot assert ${expect}"
        return
    fi

    state=$(probe "$addr" "$port")
    case "$state" in
        error:*)
            say_fail "${family} tcp/${port}: PROBE ERROR, ${state#error: } (not evidence of open or closed)"
            return
            ;;
        filtered)
            state="closed"   # reachability already confirmed above
            ;;
    esac

    if [ "$expect" = "either" ]; then
        say_info "${family} tcp/${port} ${state} (OTBR-dependent, unasserted; pass --otbr if this image has it)"
    elif [ "$state" = "$expect" ]; then
        say_pass "${family} tcp/${port} ${state} (expected)"
    else
        say_fail "${family} tcp/${port} ${state}, expected ${expect}"
    fi
}

if [ -n "$V4" ]; then
    printf '\n== IPv4 (%s) ==\n' "$V4"
    for p in $PORTS; do
        case "$p" in
            22) assert IPv4 "$V4" "$p" open ;;
            80|8081)
                if [ "$OTBR" -eq 1 ]; then
                    assert IPv4 "$V4" "$p" open
                else
                    assert IPv4 "$V4" "$p" either
                fi
                ;;
            *)  assert IPv4 "$V4" "$p" closed ;;
        esac
    done
fi

if [ -n "$V6" ]; then
    printf '\n== IPv6 (%s) ==\n' "$V6"
    # Every port must be closed over IPv6 regardless of --otbr: OTBR's web UI
    # and agent REST bind IPv4-only by design, so this is a policy invariant,
    # not an OTBR-presence question. The management plane is IPv4-only by
    # policy: the sshd.socket listener is pinned to 0.0.0.0:22 and the firewall
    # rules are family-qualified. A single open port here means one of those two
    # controls regressed.
    for p in $PORTS; do
        assert IPv6 "$V6" "$p" closed
    done
fi

printf '\n== summary ==\n'
printf '  PASS: %d\n' "$PASS"
printf '  FAIL: %d\n' "$FAIL"

[ "$FAIL" -eq 0 ]
