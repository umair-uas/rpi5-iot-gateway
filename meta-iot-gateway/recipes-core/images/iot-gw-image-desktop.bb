SUMMARY = "IoT GW Desktop LAB image (RPi5, Wayland/Weston) - NOT HARDENED, do not ship"
DESCRIPTION = "Wayland-first desktop image using Weston compositor with full desktop environment."

LICENSE = "MIT"

# Pull in common base (RAUC, SSH, splash, baseline pkgs)
require iot-gw-image-base.inc
# Developer user account (devel + passwordless sudo); not in prod image
require iotgw-dev-users.inc

# Desktop images may use VT keyboard setup.
IOTGW_DISABLE_VCONSOLE_SETUP = "0"

# Weston via IMAGE_FEATURES, not only via the packagegroup.
#
# This does two things, and the second is the one that is easy to miss:
#   1. pulls oe-core's packagegroup-core-weston;
#   2. makes oe-core derive the default systemd target —
#      rootfs-postcommands.bbclass:45
#        SYSTEMD_DEFAULT_TARGET ?= '${@bb.utils.contains_any("IMAGE_FEATURES",
#            [ "x11-base", "weston" ], "graphical.target", "multi-user.target", d)}'
#
# Previously Weston was pulled ONLY through packagegroup-iot-gw-desktop-core's
# RDEPENDS, so that contains_any() saw no "weston", default.target stayed
# multi-user.target, and upstream weston.service (WantedBy=graphical.target)
# was never started. The compositor would not have come up even once the
# packagegroup's missing packages were fixed.
IMAGE_FEATURES += "weston"

# --- Lab/bench ergonomics ---------------------------------------------------
#
# THIS IMAGE IS A LAB/BENCH VARIANT — NOT HARDENED, NOT FOR SHIPPING.
# It exists so DEEPX DX-M1 / edge-AI inference work can be done comfortably on
# an attached screen. base/dev/prod are unaffected: everything here is scoped to
# THIS RECIPE, which no other image reads. That scoping is deliberate and load-
# bearing — `IOTGW_PROFILE`/`:desktop` is set build-WIDE in local_conf_header,
# so it would also apply to iot-gw-image-prod in the same composition and must
# NOT be used as the guard for a security relaxation.
#
# Module signature enforcement is deliberately LEFT ON. Relaxing it would need
# a separate kernel build and would rotate the signing key; the correct fix is a
# persistent CONFIG_MODULE_SIG_KEY, available opt-in via
# IOTGW_MODULE_SIG_KEY_FILE — see docs/KERNEL.md, "Persistent module-signing
# key".
IMAGE_FEATURES += " \
    tools-debug \
    post-install-logging \
    package-management \
"

# Desktop environment with applications and utilities
# Includes: Weston/Wayland, file manager, system utilities, fonts, GStreamer
CORE_IMAGE_EXTRA_INSTALL += " packagegroup-iot-gw-desktop iotgw-dev-ssh-keys iotgw-sudoers iotgw-systemd-presets-desktop"

# DEEPX DX-M1 demo stack — the whole point of this variant.
#
# Same IOTGW_ENABLE_DEEPX_DXM1 gate as iot-gw-image-dev.bb (which takes the
# BASE packagegroup, not -demo), so composing kas/deepx.yml is what
# enables it; the toggle alone is not enough (packagegroup-iot-gw-deepx.bb
# bb.fatal's if the layer is absent, which is the intended fail-fast).
#
# -demo rather than the base group: it adds dx-stream (the GStreamer elements
# dxpreprocess/dxinfer/dxpostprocess/dxosd) and the sample payload. Those
# elements need a Wayland compositor, which is why the demo belongs HERE and
# not in the headless dev image.
#
# Developer toolchain, matching iot-gw-image-dev.bb: gdb/strace/perf, build
# essentials, editors. Months of driver and pipeline work need these on the
# machine itself.
CORE_IMAGE_EXTRA_INSTALL += " \
    ${@bb.utils.contains('IOTGW_ENABLE_DEEPX_DXM1', '1', 'packagegroup-iot-gw-deepx-demo', '', d)} \
    packagegroup-iot-gw-dev \
    packagegroup-iot-gw-devtools \
    packagegroup-core-buildessential \
"

# Optional: install individual sub-packages for customization
# - packagegroup-iot-gw-desktop-core     (Weston/Wayland foundation)
# - packagegroup-iot-gw-desktop-apps     (file manager; weston-terminal comes with weston)
# - packagegroup-iot-gw-desktop-utils    (system utilities, fonts, polkit/udisks)
# - packagegroup-iot-gw-desktop-media    (GStreamer incl. waylandsink)
#
# There is deliberately no -themes sub-package. The earlier version of this
# comment listed one, plus a browser and editors, none of which ever existed —
# the comment described an intent, not the recipe.

# Extra space for desktop artifacts (browser cache, user files, etc.)
# Chromium + full desktop: ~2-3GB additional recommended
IMAGE_ROOTFS_EXTRA_SPACE = "3145728"
