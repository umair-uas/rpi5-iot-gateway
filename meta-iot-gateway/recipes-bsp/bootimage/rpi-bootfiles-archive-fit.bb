SUMMARY = "Boot files archive (FIT variant) for RAUC post-install copy"
DESCRIPTION = "Packs bootloader and FIT kernel boot files into bootfiles-fit.tar.gz for inclusion in RAUC bundles."
require rpi-bootfiles-archive-common.inc

# rpi-bootfiles (meta-raspberrypi) is COMPATIBLE_MACHINE-gated to rpi;
# match it so this recipe drops out of world on other machines.
COMPATIBLE_MACHINE = "^rpi$"

IOTGW_BOOTFILES_ARCHIVE_NAME = "bootfiles-fit.tar.gz"
IOTGW_BOOTFILES_STAGE_FILES = "u-boot.bin config.txt cmdline.txt splash.bmp fitImage Image kernel_2712.img"

# Wrynose split-FIT model: fitImage is produced by the separate iotgw-fit-image
# recipe (not virtual/kernel). Order this archive after its deploy so the
# signed fitImage is present in DEPLOY_DIR_IMAGE before staging.
do_deploy[depends] += " iotgw-fit-image:do_deploy"
