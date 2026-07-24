FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# CVE_STATUS — CVE-2018-6557 is an Ubuntu base-files packaging issue; OE-Core's
# base-files is a different vendor/product implementation (wrong-CPE match).
# https://nvd.nist.gov/vuln/detail/CVE-2018-6557
CVE_STATUS[CVE-2018-6557] = "cpe-incorrect: Ubuntu base-files packaging issue, not OE-Core base-files"

# fstab matches the WKS layout (A/B slots + LABEL=data)
# Set custom hostname
# Note: issue/motd are shipped by iotgw-banner.
SRC_URI += "file://fstab file://hostname file://hosts file://profile.d/10-iotgw-path.sh file://skel/.bashrc"

# Mount point for the persistent data partition. Must exist in the read-only
# rootfs — systemd cannot mkdir it at mount time.
dirs755 += "/data"

# NOTE: do NOT re-install fstab here. The base recipe's do_install already
# installs this recipe's fstab (S=UNPACKDIR + FILESEXTRAPATHS:prepend makes it win),
# and meta-selinux's base-files_selinux.inc do_install:append then seds a
# `rootcontext=...:var_t:s0` onto the /var/volatile line. A second
# `install ... fstab` in this append ran *after* that sed and silently reverted
# it, so /var/volatile came up unlabeled instead of var_t. Letting the base
# install + meta-selinux sed operate on the final file preserves the rootcontext
# without duplicating meta-selinux's sed.
do_install:append() {
    install -m 0644 ${UNPACKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${UNPACKDIR}/hosts ${D}${sysconfdir}/hosts

    # iotgw-banner owns the login-banner surfaces; base-files must not also
    # package them or the rootfs transaction fails on file conflicts.
    rm -f ${D}${sysconfdir}/issue ${D}${sysconfdir}/issue.net ${D}${sysconfdir}/motd
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/profile.d/10-iotgw-path.sh ${D}${sysconfdir}/profile.d/10-iotgw-path.sh
    install -d ${D}${sysconfdir}/skel
    install -m 0644 ${UNPACKDIR}/skel/.bashrc ${D}${sysconfdir}/skel/.bashrc
    install -d ${D}/root
    install -m 0644 ${UNPACKDIR}/skel/.bashrc ${D}/root/.bashrc
    install -d ${D}/uboot-env

    # Create uninitialized machine-id file.
    # Runtime persistence/bind behavior is handled by iotgw-machine-id service.
    touch ${D}${sysconfdir}/machine-id
    chmod 0444 ${D}${sysconfdir}/machine-id
}
