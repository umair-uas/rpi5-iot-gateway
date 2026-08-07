FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Single source of truth is iotgw-common.inc; fall back for a standalone parse
# so the managed-path template (@WIFI_IFACE@) never resolves to an empty iface.
IOTGW_WIFI_IFACE ??= "wlan0"

# The U-Boot bootloader backend needs fw_printenv/fw_setenv and the compiled
# environment at runtime.
RDEPENDS:${PN} += "u-boot-fw-utils u-boot-env"

# Prepend (=+) so this subpackage is walked before ${PN}: otherwise the default
# FILES:${PN} ("${sbindir}/*") claims grow-data-partition.sh before
# FILES:rauc-grow-data-part:append can, misfiling the script into the main
# package. meta-rauc uses =+ for its own subpackages for the same reason.
PACKAGES =+ "rauc-grow-data-part"
SYSTEMD_PACKAGES += "${PN}-grow-data-part"
SYSTEMD_SERVICE:${PN}-grow-data-part = "rauc-grow-data-partition.service"
RDEPENDS:${PN}-grow-data-part = "parted"

# Provide improved grow-partition unit and script
SRC_URI:append = " \
    file://rauc-grow-data-partition.service \
    file://grow-data-partition.sh \
    file://managed-paths.conf \
    file://managed-paths.d/network.conf \
    file://managed-paths.d/observability.conf \
    file://overlay-reconcile.py \
    file://99-iotgw-rauc-slots.rules \
    file://rauc-tpm2-pkcs11-store.service.conf \
    file://de.pengutronix.rauc-iotgw.conf \
    file://rauc-hardening.service.conf \
"

IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE ?= "file"
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "0"
# rauc.inc has no PACKAGECONFIG[pkcs11]; use the meson option directly.
# pkcs11_engine defaults to true in 1.15.x — disable it when not needed to
# avoid pulling in the OpenSSL engine for builds that don't use PKCS#11 keys.
EXTRA_OEMESON:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', '', ' -Dpkcs11_engine=false', d)}"

# grow-data-partition.sh requires bash/e2fsprogs plus util-linux (lsblk, partprobe),
# udev (udevadm), and sgdisk for GPT backup header relocation.
RDEPENDS:${PN}-grow-data-part:append = " bash e2fsprogs util-linux udev gptfdisk"

do_install:append() {
    # Override unit with our hardened version
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/rauc-grow-data-partition.service \
        ${D}${systemd_system_unitdir}/rauc-grow-data-partition.service

    # Install grow helper script used by the unit
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/grow-data-partition.sh \
        ${D}${sbindir}/grow-data-partition.sh

    # Install managed overlay reconciliation metadata consumed by bundle hooks.
    install -d ${D}${datadir}/iotgw/overlay-reconcile
    install -m 0644 ${UNPACKDIR}/managed-paths.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.conf
    install -d ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d
    install -m 0644 ${UNPACKDIR}/managed-paths.d/network.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d/network.conf
    # Template the Wi-Fi interface so the managed-path tracks the same iface as
    # iotgw-network-units / iotgw-hardening (single source: IOTGW_WIFI_IFACE).
    sed -i "s/@WIFI_IFACE@/${IOTGW_WIFI_IFACE}/g" \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d/network.conf
    install -m 0644 ${UNPACKDIR}/managed-paths.d/observability.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d/observability.conf

    # Install Python overlay reconciler invoked by bundle hooks.
    install -d ${D}${libexecdir}/rauc
    install -m 0755 ${UNPACKDIR}/overlay-reconcile.py \
        ${D}${libexecdir}/rauc/overlay-reconcile.py

    # Install stable RAUC slot udev rules — symlinks appear at udev-trigger
    # time so the grow service no longer needs udev-settle.
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-iotgw-rauc-slots.rules \
        ${D}${sysconfdir}/udev/rules.d/99-iotgw-rauc-slots.rules

    # Restrict who may call the root RAUC service over D-Bus. meta-rauc's own
    # policy grants send_destination to context="default" - i.e. every local
    # process - to a root, unsandboxed installer. /etc/dbus-1/system.d is
    # included AFTER /usr/share/dbus-1/system.d by system.conf, so this file's
    # explicit <deny> revokes that grant. See the file header for why a
    # same-named replacement would NOT have worked.
    install -d ${D}${sysconfdir}/dbus-1/system.d
    install -m 0644 ${UNPACKDIR}/de.pengutronix.rauc-iotgw.conf \
        ${D}${sysconfdir}/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf

    # Conservative unit sandboxing. Numbered above the TPM drop-in so ordering
    # is explicit rather than incidental.
    install -d ${D}${sysconfdir}/systemd/system/rauc.service.d
    install -m 0644 ${UNPACKDIR}/rauc-hardening.service.conf \
        ${D}${sysconfdir}/systemd/system/rauc.service.d/20-iotgw-hardening.conf

    if ${@bb.utils.contains('IOTGW_RAUC_PKCS11_USES_TPM2', '1', 'true', 'false', d)}; then
        install -d ${D}${sysconfdir}/systemd/system/rauc.service.d
        sed -e "s|@IOTGW_TPM2_PKCS11_STORE@|${IOTGW_TPM2_PKCS11_STORE}|g" \
            -e "s|@IOTGW_RAUC_PKCS11_MODULE@|${IOTGW_RAUC_PKCS11_MODULE}|g" \
            ${UNPACKDIR}/rauc-tpm2-pkcs11-store.service.conf \
            > ${D}${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf
        chmod 0644 ${D}${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf
    fi

}

# Ensure the script is placed with the grow subpackage
FILES:rauc-grow-data-part:append = " ${sbindir}/grow-data-partition.sh"
FILES:${PN}-service:append = " ${datadir}/iotgw/overlay-reconcile/managed-paths.conf ${datadir}/iotgw/overlay-reconcile/managed-paths.d/network.conf ${datadir}/iotgw/overlay-reconcile/managed-paths.d/observability.conf ${libexecdir}/rauc/overlay-reconcile.py"
FILES:${PN}:append = " ${sysconfdir}/udev/rules.d/99-iotgw-rauc-slots.rules"
FILES:${PN}-service:append = " ${sysconfdir}/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf \
                               ${sysconfdir}/systemd/system/rauc.service.d/20-iotgw-hardening.conf \
                             "
FILES:${PN}-service:append = "${@bb.utils.contains('IOTGW_RAUC_PKCS11_USES_TPM2', '1', ' ${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf', '', d)}"
RDEPENDS:${PN}-service:append = " python3-core"
RDEPENDS:${PN}-service:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', ' openssl-engines libp11', '', d)}"

# Keep RAUC available for D-Bus activation, but don't start it by default
SYSTEMD_AUTO_ENABLE:${PN}-service = "disable"
