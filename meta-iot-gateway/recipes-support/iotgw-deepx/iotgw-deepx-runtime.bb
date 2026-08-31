SUMMARY = "DX-M1 runtime integration: service identity, device policy, dxrtd unit"
DESCRIPTION = "Project-owned glue for the DEEPX DX-M1 accelerator: a dedicated \
non-interactive service account, udev ownership for /dev/dxrt*, and a native \
systemd unit for the DXRT daemon ordered after the modules it needs."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://dxrtd.service \
    file://99-dx-dma.rules \
"

inherit systemd useradd

# --- service identity --------------------------------------------------------
# dxrtd runs as a dedicated non-interactive account rather than root. The
# accelerator is a DMA-capable PCIe device, so the daemon that owns it is worth
# confining even though it is vendor code we do not control.
#
# The group is what carries device access: /dev/dxrt* is root:dxrt 0660, and
# the daemon is in dxrt. That keeps the node off world-writable (upstream ships
# 0666) without making it root-only, which would defeat running the daemon
# unprivileged.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system dxrt"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /var/lib/dxrt \
                       --shell /sbin/nologin --gid dxrt dxrt"

# NOTE: --gid dxrt is safe here because GROUPADD_PARAM in this same recipe
# creates it. Do NOT add cross-recipe supplementary groups via --groups; this
# layer routes those through IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS instead, because
# useradd fails atomically if the other recipe's groupadd has not run yet
# (.claude/rules/yocto-patterns.md).

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "dxrtd.service"
# Installed only when the feature is enabled, so auto-enable is correct: an
# image carrying this package wants the accelerator running.
SYSTEMD_AUTO_ENABLE = "enable"

# dx-rt, not dx-rt-cli: upstream's -cli package comes out empty and is
# never produced (see packagegroup-iot-gw-deepx.bb for why). dxrtd, which
# this unit runs, ships in dx-rt.
RDEPENDS:${PN} = "dx-rt"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dxrtd.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-dx-dma.rules ${D}${sysconfdir}/udev/rules.d/

    install -d ${D}/var/lib/dxrt
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/dxrtd.service \
    ${sysconfdir}/udev/rules.d/99-dx-dma.rules \
    /var/lib/dxrt \
"

# /var/lib/dxrt is owned by the service account. Kept deliberately small: no
# model or payload lives here, so an A/B slot swap loses nothing.
pkg_postinst:${PN}() {
    chown dxrt:dxrt $D/var/lib/dxrt || true
}

COMPATIBLE_MACHINE = "raspberrypi5"
