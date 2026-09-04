SUMMARY = "IoT GW Desktop package group"
DESCRIPTION = "Desktop environment packages for Wayland/Weston with essential applications and utilities"
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch to support arch-specific packages
PACKAGE_ARCH = "${MACHINE_ARCH}"

PACKAGES = " \
    ${PN} \
    ${PN}-core \
    ${PN}-utils \
    ${PN}-apps \
    ${PN}-media \
"

# Main package pulls in all sub-packages
RDEPENDS:${PN} = " ${PN}-core ${PN}-utils ${PN}-apps ${PN}-media"

# Core Wayland/Weston desktop foundation
# Note: Avoid direct deps on dynamically renamed libs (fontconfig, dbus, libdrm)
#       These get pulled in automatically as dependencies of other packages
#
# packagegroup-core-weston is deliberately NOT listed here any more: the image
# recipe sets IMAGE_FEATURES += "weston", which pulls it AND makes oe-core
# derive SYSTEMD_DEFAULT_TARGET = graphical.target
# (rootfs-postcommands.bbclass). Pulling Weston only through this packagegroup
# left IMAGE_FEATURES without "weston", so default.target stayed
# multi-user.target and upstream weston.service — WantedBy=graphical.target —
# never started. Listing it here as well would work but hides where the real
# dependency lives.
RDEPENDS:${PN}-core = " \
    weston \
    weston-examples \
    wayland-utils \
    mesa \
    xkeyboard-config \
    liberation-fonts \
    xdg-utils \
    xdg-user-dirs \
    alsa-utils \
"

# Wayland-native utilities and system integration.
#
# Scoped to what the composed layer set can actually provide. An earlier
# revision listed packages from layers this configuration never composes, which
# meant the packagegroup could not build at all: waybar, wofi, mako,
# wl-clipboard, grim, slurp and udiskie are in no layer on disk, and
# polkit-gnome and gvfs live in meta-gnome, which rpi5.yml does not compose (it
# takes meta-oe, meta-python, meta-networking and meta-filesystems only).
#
# Restore any of them by composing the layer that provides it and adding it
# back here — not by adding the name alone, which is how this broke.
# The ttf-dejavu-* entries ARE valid: they come from meta-oe's ttf-dejavu
# recipe via FONT_PACKAGES, so a recipe-name search misleadingly misses them.
RDEPENDS:${PN}-utils = " \
    polkit \
    udisks2 \
    pavucontrol \
    hicolor-icon-theme \
    ttf-dejavu-sans \
    ttf-dejavu-sans-mono \
    ttf-dejavu-serif \
"

# Applications (GTK/Wayland-friendly) with minimal deps.
#
# foot, zathura and zathura-pdf-poppler removed for the same reason as the
# -utils entries: no composed layer provides them. A terminal is not lost —
# weston ships weston-terminal inside the main weston package
# (FILES:${PN} includes ${bindir}/weston-terminal), which -core already pulls.
RDEPENDS:${PN}-apps = " \
    pcmanfm \
"

# Media / GStreamer.
#
# The image recipe advertises a "-media (Media players, GStreamer)"
# sub-package. Before this block existed the package was named there but never
# defined, so no GStreamer reached the image at all.
#
# Everything here comes from oe-core. meta-multimedia is NOT needed and is not
# composed. waylandsink in particular needs no PACKAGECONFIG append: oe-core
# enables it off DISTRO_FEATURES (gstreamer1.0-plugins-bad_1.28.2.bb:29
# `${@bb.utils.contains('DISTRO_FEATURES', 'wayland', 'wayland', '', d)}`) and
# splits it into its own package, so naming the split package is sufficient.
# The desktop profile puts `wayland` in DISTRO_FEATURES
# (iotgw-common.inc, DISTRO_FEATURES:append:desktop).
#
# This is what makes an on-screen inference pipeline possible:
#   gst-launch-1.0 ... ! dxinfer ... ! dxosd ! videoconvert ! waylandsink
#
# debugutilsbad is for bench work, not decoration: it provides fpsdisplaysink,
# which every upstream DeepX pipeline script terminates in to show live
# throughput. Without it those scripts have to be rewritten to waylandsink and
# lose the on-screen FPS readout that is the point of comparing models.
# On the two things those scripts assume about their environment:
#   * library-file-path=/usr/local/share/gstdxstream/lib/... — a Debian
#     install.sh prefix; ours is ${datadir}. dx-stream_%.bbappend ships
#     /usr/local/share/gstdxstream as a symlink to it, which makes those scripts
#     PATH-COMPATIBLE without a per-script sed. Ten scripts under
#     dx_stream/pipelines/ reference that prefix; the bundled
#     /etc/dx-stream-sample/run.sh is the one exercised end to end on target.
#     The others are unblocked on the path, not verified individually.
#   * RTSP needs nothing added here. An earlier note in this file claimed
#     rtspsrc/rtpmanager were missing; that was wrong, and checking the built
#     image rather than the note is what showed it. `gstreamer1.0-plugins-good`
#     above is the meta-package, and it pulls all 65 of its split packages —
#     rtsp, rtp, rtpmanager and udp among them. Verified against the shipped
#     rootfs manifest, not inferred from the recipe.
#
# H.264 decode (videoparsersbad + libav) is NOT optional for the DX-M1 demo.
# dx-stream-sample's run.sh is
#   urisourcebin ! decodebin ! dxpreprocess ! dxinfer ! ... ! waylandsink
# and its boat.mp4 is H.264/avc1 1920x1080. Without a parser and a decoder,
# decodebin cannot link and the pipeline dies before a single frame reaches the
# NPU -- Weston comes up, dxtop stays at 0%, and nothing draws. Verified by
# reading the payload (ffprobe: h264,1920,1080), not assumed.
#
# The RPi5 cannot help here: VideoCore VII dropped the H.264 hardware decoder
# that earlier Pis had (it retains HEVC), so software decode is the only path.
# The v4l2-h264 kernel module in the manifest is a stateless-decoder helper,
# not a decoder, and does not change this.
#
# gstreamer1.0-libav (and its ffmpeg dependency) carry LICENSE_FLAGS =
# "commercial", accepted for this LAB image only in kas/desktop.yml. That is
# acceptable precisely because this image is marked not-for-shipping and the
# DEEPX stack already makes it non-redistributable. Do NOT copy this into
# base/dev/prod.
RDEPENDS:${PN}-media = " \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad-waylandsink \
    gstreamer1.0-plugins-bad-videoparsersbad \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-bad-debugutilsbad \
"
