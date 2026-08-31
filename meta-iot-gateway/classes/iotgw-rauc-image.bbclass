## RAUC image additions (always enabled in this distro)

# Explicitly set image formats (override meta-raspberrypi defaults)
# - tar.zst: rootfs archive for backup/inspection
# - ext4: needed for RAUC bundles
# - wic.zst: compressed disk image for flashing (zstd — compresses far faster
#   than bzip2 at comparable ratio)
# - wic.bmap: block map for fast flashing with bmaptool
IMAGE_FSTYPES = "tar.zst ext4 wic.zst wic.bmap"

# Use strong assignment to override meta-raspberrypi's default WKS_FILE
WKS_FILE = "iot-gw-rauc-128g.wks.in"

# A/B root-slot identity model (see the .wks.in files):
#  - RAUC selects slots by PARTLABEL (/dev/disk/by-partlabel/rootA|rootB;
#    set via the WKS `--label`), so slot identity does not depend on PARTUUID.
#  - U-Boot reads the *live* PARTUUID from the GPT at boot (the compiled-in
#    env macro `iotgw_set_bootargs` runs `part uuid ...`) for root=PARTUUID=,
#    so the literal value is never referenced from metadata either.
# The rootA/rootB partitions therefore carry fixed, valid, deterministic
# GPT PARTUUIDs purely to satisfy WIC (wrynose's `sfdisk --part-uuid` rejects
# the non-UUID placeholder strings that earlier WIC releases tolerated).
# Deterministic (not `--use-uuid` random) keeps images reproducible.

# Split-FIT WIC wiring (wrynose): under the FIT boot flow the fitImage is
# assembled + signed by the separate iotgw-fit-image recipe (not
# virtual/kernel, which now yields a plain Image). So the WIC must:
#  (a) stage the signed fitImage into the boot partition (the compiled-in
#      U-Boot env loads it),
#  (b) order do_image_wic after that recipe's deploy so fitImage is present in
#      DEPLOY_DIR_IMAGE before the bootimg-partition plugin copies it.
# The plain Image stays in IMAGE_BOOT_FILES (harmless; mirrors the RAUC
# bootfiles archive, which stages both).
IMAGE_BOOT_FILES:append = " fitImage"
# Drop the upstream-staged boot.scr: the boot flow runs the compiled-in U-Boot
# env (iotgw_load_boot/iotgw_exec_fit), and the surface_reduce hardening sets
# CONFIG_CMD_SOURCE=n so a bootscript can never be sourced. Carrying boot.scr
# onto /boot is dead weight and misleads readers about the boot path.
IMAGE_BOOT_FILES:remove = "boot.scr"
# FIT is the only boot flow; iotgw-fit-image always assembles the signed fitImage.
do_image_wic[depends] += " iotgw-fit-image:do_deploy"

# Keep stock /etc/fstab from base-files intact.
# WIC's imager-level fstab update appends mount lines globally and can create
# duplicates even when part-level --no-fstab-update is set in the .wks file.
WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update"

# Packages required for RAUC flow
IMAGE_INSTALL += " \
    rauc \
    rauc-service \
    virtual-rauc-conf \
    iotgw-rauc-install \
    iotgw-machine-id \
    boot-backup-prune \
    overlayfs-setup \
    rauc-grow-data-part \
"

# Read-only rootfs pairs well with slot updates
IMAGE_FEATURES += " read-only-rootfs"

# Ensure data partition mount point and home base exist
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rauc_create_data_mount;"
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rauc_create_home_dirs;"

iotgw_rauc_create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
}

iotgw_rauc_create_home_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/home
    if [ -d ${IMAGE_ROOTFS}/home/devel ] && [ -r ${IMAGE_ROOTFS}/etc/passwd ]; then
        devel_uid=$(awk -F: '$1=="devel"{print $3}' ${IMAGE_ROOTFS}/etc/passwd)
        devel_gid=$(awk -F: '$1=="devel"{print $4}' ${IMAGE_ROOTFS}/etc/passwd)
        if [ -n "$devel_uid" ] && [ -n "$devel_gid" ]; then
            chown -R "${devel_uid}:${devel_gid}" ${IMAGE_ROOTFS}/home/devel || true
        fi
    fi
}

# Desktop profile hook (Wayland/Weston minimal stack when requested)
IMAGE_INSTALL:append:desktop = " ${IOTGW_DESKTOP_PACKAGES}"

## Note: bootfiles are updated via RAUC bundle hooks (bootfiles.tar.gz)

# Validate generated WIC geometry for adaptive updates.
# This checks the final .direct artifact (not just WKS intent) and fails if
# rootA/rootB partition byte sizes are not 4KiB aligned.
python do_iotgw_validate_wic_alignment() {
    import glob
    import os

    if d.getVar("IOTGW_RAUC_ADAPTIVE") != "1":
        bb.note("WIC adaptive alignment check skipped (IOTGW_RAUC_ADAPTIVE != 1)")
        return

    alignment = 4096
    build_wic_dir = os.path.join(d.getVar("WORKDIR"), "build-wic")
    slot_sizes = {}
    source_desc = ""

    # Preferred path for current flow: split partition images .direct.pN.
    part3 = sorted(glob.glob(os.path.join(build_wic_dir, "*.direct.p3")), key=os.path.getmtime)
    part4 = sorted(glob.glob(os.path.join(build_wic_dir, "*.direct.p4")), key=os.path.getmtime)
    if part3 and part4:
        p3 = part3[-1]
        p4 = part4[-1]
        slot_sizes["rootA"] = os.path.getsize(p3)
        slot_sizes["rootB"] = os.path.getsize(p4)
        source_desc = "%s and %s" % (os.path.basename(p3), os.path.basename(p4))
    else:
        # Fallback for monolithic .direct image outputs.
        direct_images = sorted(
            glob.glob(os.path.join(build_wic_dir, "*.direct")),
            key=os.path.getmtime
        )
        if not direct_images:
            bb.fatal(
                "WIC adaptive alignment check: no .direct or .direct.p3/.direct.p4 artifacts found in %s"
                % build_wic_dir
            )

        direct_img = direct_images[-1]
        source_desc = os.path.basename(direct_img)
        out, _ = bb.process.run("sfdisk -d %s" % direct_img)

        import re
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("/dev/"):
                continue

            size_match = re.search(r"size=\s*([0-9]+)", line)
            name_match = re.search(r'name=\"([^\"]+)\"', line)
            if not size_match or not name_match:
                continue

            name = name_match.group(1)
            if name not in ("rootA", "rootB"):
                continue

            sectors = int(size_match.group(1))
            slot_sizes[name] = sectors * 512

    missing = [slot for slot in ("rootA", "rootB") if slot not in slot_sizes]
    if missing:
        bb.fatal(
            "WIC adaptive alignment check failed: missing root slot sizes from %s: %s"
            % (source_desc, ", ".join(missing))
        )

    for slot in ("rootA", "rootB"):
        size_bytes = slot_sizes[slot]
        if size_bytes % alignment != 0:
            bb.fatal(
                "WIC adaptive alignment check failed for %s in %s: size=%d bytes (mod %d = %d)"
                % (slot, direct_img, size_bytes, alignment, size_bytes % alignment)
            )

    bb.note(
        "WIC adaptive alignment check passed for %s: rootA=%d rootB=%d"
        % (source_desc, slot_sizes["rootA"], slot_sizes["rootB"])
    )
}

addtask iotgw_validate_wic_alignment after do_image_wic before do_image_complete

# -----------------------------------------------------------------------------
# Release-trust WIC misuse guard
# -----------------------------------------------------------------------------
# Under kas/fit-release-trust.yml, the U-Boot control DTB embeds only the
# YubiKey pubkey. The kernel recipe still signs the fitImage with the file
# key at build time (linux-iotgw-mainline-fit_6.18.bb do_deploy:append), and
# the WIC bootimg-partition plugin copies that file-key-signed fitImage to
# /boot/fitImage via IMAGE_BOOT_FILES. Flashing the produced .wic.zst fails
# U-Boot FIT verification on first boot.
#
# Detached signing model: the final release artifact is the resigned RAUC
# bundle from `make bundle-prod-full-fit-resign`, NOT the WIC. Signed
# production initial-flash SD images are not part of the supported flow.
# This guard surfaces the misconfiguration; it does not attempt a second
# WIC signing pipeline. bbwarn (not bbfatal) is used so the bundle workflow
# under release-trust (which transitively depends on do_image_wic via
# do_image_complete) is not broken.
#
# Anonymous python at parse time (not a do_image_wic prefunc) so the warning
# fires on every bitbake invocation against an affected image recipe,
# including sstate-covered rebuilds where prefuncs would be bypassed.
python () {
    fstypes = (d.getVar('IMAGE_FSTYPES') or '').split()
    if not any('wic' in f for f in fstypes):
        return
    file_key = (d.getVar('IOTGW_FIT_TRUST_FILE_KEY') or '1') == '1'
    yk_key   = (d.getVar('IOTGW_FIT_TRUST_YK_KEY')   or '0') == '1'
    if (not file_key) and yk_key:
        bb.warn(
            "Release-trust FIT profile is active (IOTGW_FIT_TRUST_FILE_KEY=0, "
            "IOTGW_FIT_TRUST_YK_KEY=1) but the kernel's fitImage on this WIC "
            "is still file-key signed. The produced .wic.zst is NOT a final "
            "release artifact and is known-unbootable for initial SD flash "
            "(U-Boot FIT verify will reject the file-key signature).\n"
            "\n"
            "The release artifact under the detached signing model is the "
            "resigned RAUC bundle. Use:\n"
            "    make bundle-prod-full-fit\n"
            "    make sign-bootfiles-fit-yk\n"
            "    make bundle-prod-full-fit-resign\n"
            "\n"
            "If you need a flashable SD for development, drop "
            "kas/fit-release-trust.yml from the kas composition -- the dev "
            "or dual-trust profile signs the FIT with a key the DTB trusts."
        )
}
