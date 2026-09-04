DESCRIPTION = "IoT Gateway Mainline Linux Kernel"
SECTION = "kernel"
HOMEPAGE = "https://www.kernel.org/"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${S}/COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

inherit kernel
inherit iotgw-kernel-fragments
require recipes-kernel/linux/linux-yocto.inc

LINUX_VERSION_EXTENSION = ""
PV = "${LINUX_VERSION}+git${SRCPV}"

# CVE identity for cve-check/sbom-cve-check. kernel.bbclass defaults
# CVE_PRODUCT to "linux_kernel linux:linux"; the trailing "linux:linux" token
# over-matches unrelated "linux" NVD products and yields false positives, so
# pin to the canonical kernel CPE only. CVE_VERSION defaults to PV, whose
# "+git${SRCPV}" suffix breaks NVD version-range comparison — feed the clean
# upstream release (e.g. 6.18.37) instead so fixed-below CVEs aren't flagged.
CVE_PRODUCT = "linux_kernel"
CVE_VERSION = "${LINUX_VERSION}"

# Pinned revision for reproducible CI/release builds. SRCREV_machine tracks a
# released linux-6.18.y tag (not the moving branch tip). The v6.18.37 floor is
# required: it carries the Bluetooth close-path use-after-free fixes (the .34
# hci_uart / l2cap / ISO / hci_conn / bnep batch) that close the
# hci_sock_release -> sk_destruct -> reuseport UAF on HCI-socket close.
SRCREV_machine = "0c503cf3dde2e53614f05261ece12f9d3d4c3c20"
SRCREV_meta = "307ef96123620278563ff5b1c9fb8b7b4da26970"
SRCREV_FORMAT = "machine_meta"
SRCPV = "${@bb.fetch2.get_srcrev(d)}"

KCONFIG_MODE = "--alldefconfig"
KBUILD_DEFCONFIG:raspberrypi5 ?= "defconfig"

COMPATIBLE_MACHINE = "^raspberrypi5$"
DEPENDS:append = "${@' pahole-native' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
KERNEL_DEBUG = "${@'True' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Gate Raspberry Pi firmware RTC backport for easy A/B build testing.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Keep this baseline provider minimal.
KERNEL_FEATURES:remove = "features/debug/printk.scc"
KERNEL_FEATURES:remove = "features/kernel-sample/kernel-sample.scc"

# Skip configcheck: the host kconfiglib/symbol_why stack chokes on newer Kconfig
# syntax in Linux 6.18 (e.g. "transitional"), producing false configcheck
# failures for this provider.
do_kernel_configcheck[noexec] = "1"

# Mainline 6.18 doesn't provide the full CM5 DTB set expected by
# meta-raspberrypi's raspberrypi5 machine config. Limit the DTB build to the one
# board target mainline 6.18 provides.
KERNEL_DEVICETREE:raspberrypi5 = "broadcom/bcm2712-rpi-5-b.dtb"

SRC_URI:append = "${@' file://0001-rtc-rtc-rpi-add-simple-RTC-driver-for-Raspberry-Pi.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = "${@' file://0002-arm64-dts-broadcom-bcm2712-add-rpi-rtc-node.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = "${@' file://0003-arm64-dts-broadcom-rp1-common-add-RP1-SPI0-controller.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
SRC_URI:append = "${@' file://0004-arm64-dts-broadcom-bcm2712-rpi-5-b-add-TPM-on-RP1-SPI0-CS1.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
SRC_URI:append = " file://0005-arm64-dts-broadcom-bcm2712-add-avs-thermal-zone.patch"
SRC_URI:append = "${@' file://0006-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"
SRC_URI:append = "${@' file://0007-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch' if d.getVar('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE') == '1' else ''}"
# BCM2712 hardware watchdog needs no kernel patch: mainline carries BCM2712 PM
# support. bcm2835-pm matches the "brcm,bcm2712-pm" compatible (upstream
# 30ed024fb076) and bcm2712.dtsi ships the watchdog@7d200000 node with the
# "brcm,bcm2835-pm-wdt" fallback and full 0x604 reg range; the MFD registers the
# bcm2835-wdt cell (/dev/watchdog0) unconditionally. (The V3D power-domain reset
# path is GPU-only, absent from mainline, and not required by the watchdog.)
# thermal-rpi5.cfg is a recipe-specific fragment; SRC_URI is derived from
# IOTGW_KERNEL_FRAGMENTS by iotgw-kernel-fragments.bbclass.
IOTGW_KERNEL_FRAGMENTS:append = " thermal-rpi5.cfg"

# BCM2712 PCIe host bridge built in rather than modular. Unconditional: this is
# board-level correctness, not a feature. See the fragment for the boot-ordering
# evidence that motivated it.
IOTGW_KERNEL_FRAGMENTS:append = " pcie-rpi5.cfg"
