# Fail the image build if a systemd socket unit binds a network address we did
# not intend.
#
# Runs as a ROOTFS_POSTPROCESS_COMMAND against the assembled rootfs, not a
# pre-do_configure recipe check: the defect this guards against (SSH's
# inherited dual-stack sshd.socket) lived in a unit no recipe here
# referenced, so nothing about it exists before packages are installed.
#
# Covers socket-activated units only. A daemon that binds its own socket
# directly is asserted at runtime instead, by a separate on-target check.
# Says nothing about reachability; that pairing (bound + firewalled) is
# asserted at runtime too.
#
# IOTGW_NET_LISTEN_ALLOW: space-separated "<unit>=<address>" pairs, compared
# by EXACT SET EQUALITY. A listener that silently disappears is as much a
# regression as one that appears.

IOTGW_NET_LISTEN_ALLOW ??= "sshd.socket=0.0.0.0:22"

ROOTFS_POSTPROCESS_COMMAND += "iotgw_rootfs_listen_guard;"

iotgw_rootfs_listen_guard() {
    _lg_expected="${IOTGW_NET_LISTEN_ALLOW}"
    _lg_found=""

    for _lg_dir in "${IMAGE_ROOTFS}${systemd_system_unitdir}" \
                   "${IMAGE_ROOTFS}${sysconfdir}/systemd/system"; do
        [ -d "$_lg_dir" ] || continue
        for _lg_unit in "$_lg_dir"/*.socket; do
            [ -e "$_lg_unit" ] || continue
            # A unit symlinked to /dev/null is masked and never starts.
            if [ -L "$_lg_unit" ] && [ "$(readlink "$_lg_unit")" = "/dev/null" ]; then
                continue
            fi
            _lg_name=$(basename "$_lg_unit")

            # Merge in systemd's own order (unit, then /usr/lib and /etc
            # drop-ins, each lexically); an empty assignment resets the list,
            # which is the override mechanism this guard exists to verify.
            _lg_val=""
            for _lg_src in "$_lg_unit" \
                           "${IMAGE_ROOTFS}${systemd_system_unitdir}/${_lg_name}.d"/*.conf \
                           "${IMAGE_ROOTFS}${sysconfdir}/systemd/system/${_lg_name}.d"/*.conf; do
                [ -e "$_lg_src" ] || continue
                while IFS= read -r _lg_line; do
                    case "$_lg_line" in
                        ListenStream=|ListenDatagram=|ListenSequentialPacket=)
                            _lg_val=""   # list reset
                            ;;
                        ListenStream=*|ListenDatagram=*|ListenSequentialPacket=*)
                            _lg_v=${_lg_line#*=}
                            # AF_UNIX (path/abstract) and ListenNetlink= are
                            # not network listeners; several system services
                            # use the latter and would false-positive here.
                            case "$_lg_v" in
                                /*|@*) : ;;
                                *) _lg_val="${_lg_val:+$_lg_val,}$_lg_v" ;;
                            esac
                            ;;
                    esac
                done < "$_lg_src"
            done

            [ -n "$_lg_val" ] && _lg_found="${_lg_found} ${_lg_name}=${_lg_val}"
        done
    done

    _lg_found=$(echo $_lg_found | tr ' ' '\n' | sort | tr '\n' ' ')
    _lg_want=$(echo $_lg_expected | tr ' ' '\n' | sort | tr '\n' ' ')

    if [ "$_lg_found" != "$_lg_want" ]; then
        bbfatal "iotgw-listen-guard: network-listening socket units do not match policy.

  expected: ${_lg_want:-(none)}
  found:    ${_lg_found:-(none)}

A bare port (e.g. 'ListenStream=22') binds DUAL-STACK. To pin a family, ship
a drop-in at <unit>.d/override.conf with an empty ListenStream= reset
followed by the pinned address (ListenStream= is a list; without the reset
the drop-in adds a listener instead of replacing one). Example:
recipes-connectivity/openssh/files/sshd.socket-iotgw.conf. If this listener
is intended, add it to IOTGW_NET_LISTEN_ALLOW in
conf/distro/include/iotgw-common.inc."
    fi
}
