#!/bin/bash
# Network-exposure assertions for the IoT Gateway distro (iotgw).
#
# Answers one question the rest of the smoke suite does not: is anything
# listening, or admitted by the firewall, on an address family or scope we did
# not intend?
#
# Why this exists. sshd on this image is socket-activated (sshd@.service under
# Accept=yes), so systemd - not sshd - owns the listening socket. Upstream's
# sshd.socket ships a bare "ListenStream=22", which systemd binds DUAL-STACK
# (*:22). With a global IPv6 address on any interface that makes SSH reachable
# over un-NATed IPv6. ListenAddress/AddressFamily in sshd_config are INERT
# under socket activation and cannot fix it; the listen scope lives in
# sshd.socket.d/override.conf.
#
# The single highest-value assertion here is the "Listen" property check in the
# first section: systemd's own answer, and the only thing that distinguishes an
# override that RESET the ListenStream list from one that merely APPENDED to it
# (the latter silently keeps *:22 and is the most likely way the fix regresses).
#
# Usage:
#   # On target directly:
#   sudo ./exposure-target.sh
#
#   # From host over SSH (no copy needed):
#   ssh <gw> 'sudo bash -s' < scripts/security/exposure-target.sh
#
#   # Via the runner:
#   scripts/run-target-checks.sh <device-ip> exposure
#
# Pairs with:
#   scripts/security/exposure-probe-host.sh - the off-device reachability
#     oracle. A device cannot prove its own external reachability; that check
#     must run from a second host.
#
# Environment overrides:
#   IOTGW_EXPECT_SSH_LISTEN  expected sshd.socket Listen value
#                            (default: 0.0.0.0:22)
#   IOTGW_LISTEN_ALLOW       space-separated allowlist of non-loopback
#                            listening addresses, "addr:port" as ss prints them

set -u
PASS=0
FAIL=0
SKIP=0

say_pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
say_fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
say_skip() { printf '  \e[33mSKIP\e[0m %s - %s\n' "$1" "${2:-}"; SKIP=$((SKIP+1)); }
section()  { printf '\n== %s ==\n' "$1"; }

# Expected sshd.socket listener. IPv4-only is deliberate: the listener itself
# enforces the family, rather than depending on a firewall rule staying correct.
EXPECT_SSH_LISTEN="${IOTGW_EXPECT_SSH_LISTEN:-0.0.0.0:22}"

# OTBR (ports 80/8081) is an optional image feature (IOTGW_ENABLE_OTBR),
# default off in the distro itself. Assuming it is present unconditionally
# would fail this check on any correctly-built non-OTBR image, so its
# presence is detected on THIS target rather than assumed.
_otbr_ports=""
if command -v systemctl >/dev/null 2>&1 \
   && systemctl list-unit-files 'otbr-web.service' 'otbr-agent.service' 2>/dev/null | grep -q '\.service'; then
    _otbr_ports="0.0.0.0:80 0.0.0.0:8081"
fi

# Non-loopback, non-link-scoped listeners we intend to have.
#   22          sshd (IPv4-only after the socket pin)
#   80 / 8081   OTBR web UI and agent REST, IPv4-only binds, only when OTBR
#               is actually part of this image (see _otbr_ports above)
#   1883        mosquitto; also binds v6, admitted by NO firewall rule
#   5353        Avahi/mDNS; also binds v6, admitted by NO firewall rule
# The v6 binds on 1883/5353 are safe only because the firewall does not admit
# those ports. That pairing is ASSERTED against the live ruleset in the IPv6
# section below rather than assumed here - assuming it is how this class of bug
# happens in the first place.
DEFAULT_LISTEN_ALLOW="0.0.0.0:22 ${_otbr_ports} 0.0.0.0:1883 [::]:1883 0.0.0.0:5353 [::]:5353"
LISTEN_ALLOW="${IOTGW_LISTEN_ALLOW:-$DEFAULT_LISTEN_ALLOW}"

in_allowlist() {
    local needle="$1" item
    for item in $LISTEN_ALLOW; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Loopback binds are not an exposure surface; they auto-pass.
is_loopback() {
    case "$1" in
        127.*|'[::1]'*|*'%lo:'*) return 0 ;;
        *) return 1 ;;
    esac
}

# Interface-scoped ("%iface") and link-local (fe80::) binds cannot be reached
# from off-link regardless of the firewall - the scope is enforced by the
# kernel, not by policy. These are the DHCP client (:68), the DHCPv6 client
# (:546) and OTBR's ephemeral Thread port, whose number changes per boot and so
# cannot be allowlisted by value. Reported, not judged.
is_link_scoped() {
    case "$1" in
        *%*|'[fe80:'*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
section "sshd.socket listen scope"
if ! command -v systemctl >/dev/null 2>&1; then
    say_skip "sshd.socket Listen" "systemctl not available"
elif ! systemctl cat sshd.socket >/dev/null 2>&1; then
    say_skip "sshd.socket Listen" "unit not present (sshd may not be socket-activated)"
else
    # systemd renders this as "Listen=0.0.0.0:22 (Stream)". A dual-stack bind
    # from a bare "ListenStream=22" renders as "[::]:22 (Stream)". An override
    # that appended instead of resetting yields TWO entries.
    listen_raw=$(systemctl show sshd.socket -p Listen --value 2>/dev/null)
    listen_count=$(printf '%s\n' "$listen_raw" | grep -c '(Stream)')
    listen_addr=$(printf '%s' "$listen_raw" | sed -E 's/ \(Stream\)//g' | tr -s ' ')

    printf '    Listen = %s\n' "${listen_raw:-(empty)}"

    if [ "$listen_count" -gt 1 ]; then
        say_fail "sshd.socket has $listen_count stream listeners - the override APPENDED instead of resetting the ListenStream list (needs a bare 'ListenStream=' first)"
    elif [ "$listen_addr" = "$EXPECT_SSH_LISTEN" ]; then
        say_pass "sshd.socket Listen = $listen_addr"
    else
        say_fail "sshd.socket Listen = '${listen_addr:-(empty)}', expected '$EXPECT_SSH_LISTEN'"
    fi

    # Prove the drop-in is actually being read, not just that the value is right
    # for some other reason.
    if systemctl cat sshd.socket 2>/dev/null | grep -q 'sshd\.socket\.d/'; then
        say_pass "sshd.socket drop-in present in merged unit"
    else
        say_fail "no sshd.socket.d/ drop-in in merged unit - upstream default is unmodified"
    fi
fi

# ---------------------------------------------------------------------------
section "listening socket inventory"
if ! command -v ss >/dev/null 2>&1; then
    say_skip "listener inventory" "ss not available (iproute2-ss)"
else
    unexpected=0
    seen=""
    # -H omits the header; field 4 is Local Address:Port for both -tln and -uln.
    while read -r laddr; do
        [ -z "$laddr" ] && continue
        seen="$seen $laddr"
        if is_loopback "$laddr"; then
            continue
        fi
        if is_link_scoped "$laddr"; then
            printf '    link-scoped (not off-link reachable): %s\n' "$laddr"
            continue
        fi
        if in_allowlist "$laddr"; then
            say_pass "listener $laddr (expected)"
        else
            say_fail "listener $laddr is NOT in the expected set"
            unexpected=$((unexpected + 1))
        fi
    done <<EOF
$( { ss -tlnH; ss -ulnH; } 2>/dev/null | awk '{print $4}' | sort -u )
EOF

    # A listener that VANISHED matters as much as one that appeared - a missing
    # service is a regression too, and a subset check would not notice.
    for want in $LISTEN_ALLOW; do
        case " $seen " in
            *" $want "*) : ;;
            *) say_fail "expected listener $want is ABSENT" ;;
        esac
    done

    [ "$unexpected" -eq 0 ] && say_pass "no unexpected non-loopback listeners"
fi

# ---------------------------------------------------------------------------
section "firewall address-family qualification"
# Ports the input chain admits. Consumed by the IPv6 section below to verify
# that every wildcard v6 listener is in fact unreachable, rather than assuming
# it. Empty string means "could not determine" and the v6 section degrades to a
# SKIP rather than a false PASS.
FW_ACCEPT_PORTS=""
if ! command -v nft >/dev/null 2>&1; then
    say_skip "nftables ruleset" "nft not available"
else
    if nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
        say_pass "/etc/nftables.conf parses"
    else
        say_fail "/etc/nftables.conf does not parse"
    fi

    # In a "table inet", a rule such as "tcp dport 22 accept" with no family
    # qualifier matches BOTH IPv4 and IPv6. nft prints its own canonical form,
    # so a qualified rule appears as "meta nfproto ipv4 tcp dport 22 accept"
    # (or with a leading "ip "/"ip6 " match). Anything with a dport and no
    # family token is unqualified.
    chain=$(nft list chain inet filter input 2>/dev/null)
    if [ -z "$chain" ]; then
        say_skip "inet filter input" "chain not present"
    else
        FW_ACCEPT_PORTS=$(printf '%s\n' "$chain" \
            | grep -E 'dport .* accept' \
            | sed -E 's/.*dport[[:space:]]+\{?[[:space:]]*([0-9, ]+).*/\1/' \
            | tr ',' ' ' | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
        printf '    input chain admits ports: %s\n' "${FW_ACCEPT_PORTS:-(none)}"

        unqualified=$(printf '%s\n' "$chain" \
            | grep -E 'dport' \
            | grep -vE 'nfproto (ipv4|ipv6)' \
            | grep -vE '(^|[[:space:]])ip6?[[:space:]]' || true)
        if [ -z "$unqualified" ]; then
            say_pass "all dport rules in inet filter input are family-qualified"
        else
            say_fail "unqualified dport rule(s) in inet filter input - these match IPv4 AND IPv6:"
            printf '%s\n' "$unqualified" | sed 's/^/        /'
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "IPv6 reachability posture"
# Report the COUNT only. This output is meant to be pasteable into a commit
# body, and the repo is public - a global address identifies the site.
if ! command -v ip >/dev/null 2>&1; then
    say_skip "global IPv6 addresses" "ip not available"
else
    gua_count=$(ip -6 -o addr show scope global 2>/dev/null | wc -l)
    printf '    global IPv6 addresses: %s\n' "$gua_count"
    if [ "$gua_count" -eq 0 ]; then
        say_pass "no global IPv6 addresses - v6 exposure not reachable off-link"
    else
        # Not a failure by itself: OTBR border routing legitimately needs
        # infrastructure IPv6. It IS a failure if a service is bound v6-wide.
        v6_wide=$( { ss -tlnH; ss -ulnH; } 2>/dev/null | awk '{print $4}' \
            | grep -E '^\[::\]:' | sort -u || true)
        if [ -z "$v6_wide" ]; then
            say_pass "$gua_count global IPv6 address(es) present, but no wildcard v6 listeners"
        elif [ -z "$FW_ACCEPT_PORTS" ]; then
            say_skip "wildcard v6 listeners" \
                "firewall accept set unknown - cannot prove these are unreachable"
        else
            # A wildcard v6 bind is acceptable ONLY if the firewall does not
            # admit its port. Checking the listener against a static allowlist
            # would just re-encode the assumption; checking it against the LIVE
            # ruleset is what catches the two controls drifting apart - which is
            # exactly how SSH ended up reachable over IPv6.
            for l in $v6_wide; do
                lport="${l##*:}"
                if printf ' %s ' "$FW_ACCEPT_PORTS" | grep -q " $lport "; then
                    say_fail "wildcard v6 listener $l AND firewall admits port $lport, with $gua_count global IPv6 address(es) - reachable off-link"
                else
                    say_pass "wildcard v6 listener $l is unreachable (firewall does not admit $lport)"
                fi
            done
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "D-Bus authorization (RAUC)"
# rauc.service runs as root and unsandboxed by necessity - it writes raw slot
# images. meta-rauc's shipped policy grants send_destination to
# context="default", so ANY local process could call InstallBundle or Mark:
# replace the rootfs, flip boot state, or roll back to an older still-signed
# bundle. Signature verification constrains what may be installed, not who may
# ask. This asserts the override in
# /etc/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf is actually in force.
#
# Non-destructive by construction: the probe calls a method that DOES NOT EXIST.
# D-Bus evaluates policy before dispatch, so a blocked caller gets AccessDenied
# and an permitted caller gets UnknownMethod - nothing is ever executed.
if ! command -v busctl >/dev/null 2>&1; then
    say_skip "RAUC D-Bus authorization" "busctl not available"
elif ! busctl --system status de.pengutronix.rauc >/dev/null 2>&1 \
     && ! busctl --system list 2>/dev/null | grep -q de.pengutronix.rauc; then
    say_skip "RAUC D-Bus authorization" "rauc not present on the bus"
else
    # Test as a confined service account rather than 'nobody' - it represents
    # the actual threat: a compromised non-root service pivoting to root.
    probe_user=""
    for u in mosquitto otbr nobody; do
        id "$u" >/dev/null 2>&1 && { probe_user="$u"; break; }
    done

    if [ -z "$probe_user" ]; then
        say_skip "RAUC D-Bus authorization" "no unprivileged account to probe with"
    else
        probe_out=$(su -s /bin/sh -c \
            "busctl --system call de.pengutronix.rauc / de.pengutronix.rauc.Installer IotgwPolicyProbe" \
            "$probe_user" 2>&1)

        # busctl's actual wording on this stack is "Call failed: Access denied"
        # (verified on-target), which is neither AccessDenied (no space) nor
        # "Permission denied" (different word). Matching only those two
        # earlier patterns turned a genuine, correct denial into an
        # "inconclusive" SKIP instead of a PASS.
        case "$probe_out" in
            *AccessDenied*|*[Aa]ccess\ denied*|*"not allowed"*|*[Pp]ermission\ denied*)
                say_pass "state-changing Installer call from '$probe_user' is DENIED by policy" ;;
            *UnknownMethod*|*"Unknown method"*|*"No such method"*)
                say_fail "'$probe_user' reached the Installer interface (got UnknownMethod, not AccessDenied) - any local process can call InstallBundle/Mark on a root service" ;;
            *)
                say_fail "RAUC D-Bus authorization: unrecognized busctl response, treating as unverified: ${probe_out%%$'\n'*}" ;;
        esac

        # The override must not break the legitimate readers: edge-healthd calls
        # GetSlotStatus, and denying it would silently break health reporting.
        if su -s /bin/sh -c \
            "busctl --system call de.pengutronix.rauc / de.pengutronix.rauc.Installer GetSlotStatus" \
            "$probe_user" >/dev/null 2>&1; then
            say_pass "read-only GetSlotStatus still permitted for '$probe_user' (edge-healthd path intact)"
        else
            say_fail "GetSlotStatus is denied for '$probe_user' - the policy is too tight and breaks edge-healthd health reporting"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "external reachability"
say_skip "off-device reachability" \
    "a device cannot prove its own external reachability - run scripts/security/exposure-probe-host.sh from a second host"

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
printf '  PASS: %d\n' "$PASS"
printf '  FAIL: %d\n' "$FAIL"
printf '  SKIP: %d\n' "$SKIP"

[ "$FAIL" -eq 0 ]
