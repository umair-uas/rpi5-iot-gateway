## Common base include for IoT Gateway images (RPi5)

# Core inheritance shared by all image variants
inherit core-image iotgw-rootfs iotgw-listen-guard extrausers
inherit iotgw-rauc-image

# Label the rootfs with SELinux file contexts at do_rootfs (runs setfiles
# against refpolicy-mcs's file_contexts). Without this, files ship as
# unlabeled_t and the first boot pays a slow full autorelabel. RAUC OTA
# slots inherit labels because the bundled rootfs is built with this class.
IMAGE_CLASSES += "selinux-image"

# Include centralized user/group definitions
require iotgw-users.inc

# Avoid redundant image formats
IMAGE_FSTYPES:remove = "ext3"

# Common baseline features
IMAGE_FEATURES += " \
    ssh-server-openssh \
"

# Headless-first default: avoid degraded state from static vconsole setup unit.
# Desktop profile can override this to "0" if VT keyboard setup is required.
IOTGW_DISABLE_VCONSOLE_SETUP ?= "1"

# Keep upstream RAUC mark-good flow enabled.
IOTGW_DISABLE_RAUC_MARK_GOOD ?= "0"
IOTGW_UBOOT_BOOTDELAY ?= "2"
# U-Boot feature tokens (surface_reduce fit_enforce watchdog) default distro-wide
# in conf/distro/include/iotgw-common.inc; iotgw_write_uboot_policy below emits
# the resolved value into /etc/default/iotgw-uboot-policy. prod image overrides
# to append appliance/prompt lockdown.
IOTGW_AUDIT_RULE_IMMUTABLE ?= "1"

# Desktop profile can include splash
IMAGE_FEATURES:append:desktop = " splash"

# Common packages across all variants
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-base \
    packagegroup-iot-gw-hwtools \
    packagegroup-iot-gw-apps \
    packagegroup-iot-gw-selinux \
    iotgw-banner \
    iotgw-network-units \
    iotgw-sysctl \
    iotgw-journald \
    iotgw-log-persist \
    ${@bb.utils.contains('DISTRO_FEATURES', 'bluetooth', 'iotgw-bluetooth-persist', '', d)} \
    iotgw-firewall \
    iotgw-systemd-presets \
    iotgw-provision \
    iotgw-nftables \
    iotgw-sshd-hardening \
    nftables \
    figlet \
    wpa-supplicant \
    kernel-modules \
    linux-firmware-rpidistro-bcm43455 \
"

# systemd 259's `systemctl preset-all` emits a "Failed to preset all unit:
# Unit <X> is masked" line for a masked unit that carries a preset directive,
# which the rootfs log_check counts as an error. Of the units this image masks
# (see iotgw-rootfs.bbclass), only systemd-networkd-wait-online trips this — the
# others are masked by mechanisms that don't run through preset-all — so the log
# carries exactly one such notice; filter it. NB: IMAGE_LOG_CHECK_EXCLUDES splits
# on literal spaces, so the regex uses \s, never a literal space.
IMAGE_LOG_CHECK_EXCLUDES += "Failed\sto\spreset\sall\sunit.*is\smasked"

iotgw_write_uboot_policy () {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/default
    cat > ${IMAGE_ROOTFS}${sysconfdir}/default/iotgw-uboot-policy <<EOF
# Managed by image build. Applied on target by iotgw-provision.sh.
IOTGW_UBOOT_BOOTDELAY=${IOTGW_UBOOT_BOOTDELAY}
IOTGW_UBOOT_EXTRA_KERNEL_ARGS=${IOTGW_UBOOT_EXTRA_KERNEL_ARGS}
IOTGW_UBOOT_FEATURES=${IOTGW_UBOOT_FEATURES}
EOF
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_write_uboot_policy; "
