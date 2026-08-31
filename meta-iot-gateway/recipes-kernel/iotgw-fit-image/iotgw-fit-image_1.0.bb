SUMMARY     = "Signed FIT image for the iotgw distro on Raspberry Pi 5"
DESCRIPTION = "Assembles and signs a U-Boot FIT image (kernel + DTB + signed \
config node) for raspberrypi5 using the wrynose kernel-fit-image class. \
Consumes linux.bin / linux_comp published by linux-iotgw-mainline-fit via its \
kernel-fit-extra-artifacts class. Replaces the pre-wrynose in-kernel \
do_assemble_fitimage flow (kernel-fitimage.bbclass was removed in OE-Core \
wrynose). See docs/FIT_BOOT_SIGNING.md."
HOMEPAGE    = "https://github.com/umair-as/rpi5-iot-gateway"
SECTION     = "kernel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit kernel-fit-image

COMPATIBLE_MACHINE = "raspberrypi5"

# Single primary DTB in the FIT — device-tree overlays are applied by the RPi
# firmware, not carried in the FIT. The class emits exactly one
# /configurations/conf-<dtb> node and FIT_CONF_DEFAULT_DTB pins it as the
# FIT's signed `default` property. That property is the ONLY place the
# config name lives: U-Boot boots the default config (bootm with no
# explicit #conf), and the env var iotgw_fit_conf is an operator override
# only. (A dual-config primary/recovery FIT split is tracked as separate
# future work; this recipe intentionally emits the single config.)
KERNEL_DEVICETREE = "broadcom/bcm2712-rpi-5-b.dtb"
FIT_CONF_DEFAULT_DTB = "bcm2712-rpi-5-b.dtb"

# UBOOT_LOADADDRESS / UBOOT_ENTRYPOINT are intentionally left to the
# environment default (uboot-config.bbclass), which yields the load/entry
# values the boot flow on this board is validated against.

# File-key FIT signing: a config-level signature over the kernel + fdt images.
# The control-DTB public key that verifies this FIT at boot is injected into
# the deployed board DTB by linux-iotgw-mainline-fit's do_deploy, using the
# same UBOOT_SIGN key material. FIT_HASH_ALG / FIT_SIGN_ALG come from the
# fitflow config (sha256 / rsa2048).
FIT_KERNEL_SIGN_ENABLE  = "${UBOOT_SIGN_ENABLE}"
FIT_KERNEL_SIGN_KEYNAME = "${UBOOT_SIGN_KEYNAME}"
FIT_KERNEL_SIGN_KEYDIR  = "${UBOOT_SIGN_KEYDIR}"
