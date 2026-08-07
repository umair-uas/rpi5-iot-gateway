SUMMARY = "IoT GW nftables baseline rules"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://nftables.conf \
           file://nftables-otbr.conf \
          "

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# The OTBR rules live in their own file rather than inline in a sed script.
# As embedded sed text they were invisible to any grep over *.conf, so a lint or
# guard scanning the tracked ruleset would have passed while the OTBR build
# branch - the one that actually shipped - carried unqualified rules. Keeping
# them in a real file means one pattern covers both build configurations.
do_install() {
    install -d ${D}${datadir}/iotgw-firewall
    install -m 0644 ${UNPACKDIR}/nftables.conf ${D}${datadir}/iotgw-firewall/nftables.conf

    if [ "${IOTGW_ENABLE_OTBR}" = "1" ]; then
        # Splice the file in at the marker, then drop the marker line itself.
        sed -i -e '/@OTBR_RULES@/r ${UNPACKDIR}/nftables-otbr.conf' \
               -e '/@OTBR_RULES@/d' \
               ${D}${datadir}/iotgw-firewall/nftables.conf
    else
        sed -i '/@OTBR_RULES@/d' ${D}${datadir}/iotgw-firewall/nftables.conf
    fi

    # Fail the build rather than ship a rule that silently spans both families.
    # Matches tcp/udp dport ANYWHERE on a rule line (not just as the first
    # token, so "ct state new tcp dport 22 accept" is caught too). Comments
    # are stripped BEFORE matching, both whole-line and trailing ("tcp dport
    # 22 accept # ip note" must not evade on the strength of its own
    # comment), and a rule already constrained by "meta nfproto", "ip", or
    # "ip6" is accepted.
    _nft_file="${D}${datadir}/iotgw-firewall/nftables.conf"
    _nft_bad=$(sed -E 's/#.*$//' "${_nft_file}" \
        | grep -nE '\b(tcp|udp)[[:space:]]+dport\b' \
        | grep -vE '\bmeta[[:space:]]+nfproto\b|\bip6?\b') || true
    if [ -n "${_nft_bad}" ]; then
        bbfatal "iotgw-firewall: the lines below name a port with no address family.
${_nft_bad}
In a 'table inet' they admit the port on IPv4 AND IPv6. Add an explicit \
'meta nfproto ipv4' / 'meta nfproto ipv6' match. See the header comment in \
recipes-security/iotgw-firewall/files/nftables.conf."
    fi
}

FILES:${PN} = "${datadir}/iotgw-firewall/nftables.conf"

RDEPENDS:${PN} += "nftables"
