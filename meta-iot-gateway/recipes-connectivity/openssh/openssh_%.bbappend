FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://openssh-hostkeys.tmpfiles.conf \
                   file://sshd.socket-iotgw.conf \
                 "

do_install:append() {
    # Host keys live on the persistent /data partition, so the host identity is
    # stable across reboots and A/B updates and sshdgenkeys runs once. /var/lib
    # is volatile (tmpfs) on this image and OE-Core's read-only-rootfs config
    # points HostKey at volatile /var/run/ssh, either of which would regenerate
    # keys every boot. sshd_check_keys derives the key paths from the HostKey
    # directives of the -f config (sshd_config_readonly, via SSHD_OPTS), so
    # rewriting these lines is sufficient — SYSCONFDIR in /etc/default/ssh is only
    # a runtime scratch dir and does not affect where host keys are generated.
    if [ -f ${D}${sysconfdir}/ssh/sshd_config_readonly ]; then
        sed -i '/^HostKey /d' ${D}${sysconfdir}/ssh/sshd_config_readonly
        {
            echo "HostKey /data/ssh/ssh_host_rsa_key"
            echo "HostKey /data/ssh/ssh_host_ecdsa_key"
            echo "HostKey /data/ssh/ssh_host_ed25519_key"
        } >> ${D}${sysconfdir}/ssh/sshd_config_readonly
    fi

    # Ensure persistent host key directory exists with strict permissions.
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/openssh-hostkeys.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/openssh-hostkeys.conf

    # Pin the socket-activated listener to IPv4. This rides inside openssh-sshd
    # rather than a separate hardening package on purpose: the listen scope must
    # not depend on an image recipe remembering to install a security package.
    # packagegroup-iot-gw-security, for instance, reaches only the dev image, so
    # a drop-in placed there would leave every other variant dual-stack.
    #
    # Guarded on the same PACKAGECONFIG that installs the unit - in service mode
    # sshd.socket does not exist and a drop-in for it would be dead config.
    if ${@bb.utils.contains('PACKAGECONFIG', 'systemd-sshd-socket-mode', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}/sshd.socket.d
        install -m 0644 ${UNPACKDIR}/sshd.socket-iotgw.conf \
            ${D}${systemd_system_unitdir}/sshd.socket.d/override.conf
    fi
}

FILES:${PN}-sshd:append = " ${sysconfdir}/tmpfiles.d/openssh-hostkeys.conf \
                            ${systemd_system_unitdir}/sshd.socket.d/override.conf \
                          "
