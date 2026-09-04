# Port meta-deepx-m1's dx-stream from its walnascar baseline to wrynose.
#
# Same single defect as dx-rt and dx-driver: the recipe sets
# S = "${WORKDIR}/git". Up to walnascar that worked because base.bbclass moved
# unpacked sources into WORKDIR as a compatibility step; wrynose oe-core removed
# that shim (commit 53e9ea30aaf) and deliberately made it a HARD QA ERROR rather
# than a warning. Sources now land in UNPACKDIR:
#
#   UNPACKDIR ??= "${WORKDIR}/sources"     (meta/conf/bitbake.conf)
#   S          = "${UNPACKDIR}/${BP}"
#
# and the git fetcher's destsuffix follows the new S default, so the checkout
# lands at ${UNPACKDIR}/${BP} (dx-stream-3.1.1/), NOT ${UNPACKDIR}/git. This is
# the same value we had to use for dx-rt; see that bbappend for the confirmed
# on-disk layout.
S = "${UNPACKDIR}/${BP}"

# Deliberately NOT restated here, because each still resolves correctly once S
# is right — restating them would silently decouple our copy from upstream:
#
#   MESON_SOURCEPATH = "${S}/gst-dxstream-plugin"   follows S
#   LIC_FILES_CHKSUM = "file://LICENSE;md5=..."     resolved relative to S
#   --cross-file=${WORKDIR}/meson.cross             STILL CORRECT on wrynose:
#       meson.bbclass:73 writes meson.cross to ${WORKDIR}, and :51 references it
#       there. UNPACKDIR moved the SOURCES, not the generated cross file, so the
#       recipe's hand-rolled meson invocations in do_compile:append need no
#       change. Verified by reading meson.bbclass, not assumed.
#
# UNVERIFIED until this builds: upstream's do_compile:append runs `meson setup`
# by hand for each postprocess library under
# ${S}/dx_stream/custom_library/postprocess_library/*/ and installs into
# ${S}/install. Those are all S-relative and so follow the fix, but the recipe
# has never been built on wrynose in this layer. Expect to iterate.

# Build fix for Eigen 3.4.1 (libeigen, meta-openembedded).
#
# OC_SORT's Association.cpp clamps a float Eigen array with INTEGER literals,
# `.min(1).max(-1)`. Eigen 3.4 then deduces the array-expression overload with
# `const int` as the RHS and tries to instantiate traits<const int>, which does
# not exist — do_compile dies inside Eigen's headers. Upstream presumably built
# against an Eigen old enough not to care. See the patch header for the full
# diagnosis; the clamp bounds and numerics are unchanged.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-OC_SORT-use-float-literals-in-Eigen-min-max-clamp.patch"

# Cross-compile fix for the staged pkg-config file.
#
# do_compile:append installs the plugin into ${S}/install and builds the
# custom_library postprocess libs against it via pkg-config. meson's pkgconfig
# module hardcodes the absolute install prefix, so the STAGED gstdxstream.pc
# claims prefix=/usr and hands those libs -I/usr/include and
# -L/usr/lib/gstreamer-1.0 -- the BUILD HOST's directories. PKG_CONFIG_SYSROOT_DIR
# does not rescue it: pkg-config only rewrites .pc files found under the sysroot,
# and this one is staged outside it on purpose. The -I is fatal under
# -Werror=poison-system-directories; the -L is silent and worse.
SRC_URI += "file://0002-pkgconfig-make-gstdxstream.pc-prefix-relocatable.patch"

# Compatibility path for upstream DeepX pipeline scripts.
#
# Every pipeline under dx_stream/pipelines/ (and the dx-agent-dev-showcase
# scripts) hardcodes the postprocess library location as
#     library-file-path=/usr/local/share/gstdxstream/lib/...
# because DeepX ships a Debian install.sh that installs under /usr/local.
# The recipe installs into ${datadir} (/usr/share/gstdxstream/lib), so every
# one of those scripts fails at element construction until it is sed'ed —
# which makes the vendor's own examples unusable as-is and quietly diverges
# our copies from theirs on every upstream refresh.
#
# A symlink is the right shape here rather than a second install location:
# there is exactly one copy of the libraries, ${datadir} stays the owner, and
# nothing has to be kept in sync. This makes those scripts path-compatible; it
# does not by itself verify any particular pipeline.
do_install:append() {
    if [ -d "${D}${datadir}/gstdxstream" ]; then
        install -d ${D}${prefix}/local/share
        ln -snf ${datadir}/gstdxstream ${D}${prefix}/local/share/gstdxstream
    fi
}

FILES:${PN} += "${prefix}/local/share/gstdxstream"
