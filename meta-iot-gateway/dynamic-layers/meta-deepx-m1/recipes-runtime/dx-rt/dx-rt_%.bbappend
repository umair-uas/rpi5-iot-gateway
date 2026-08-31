# Same wrynose port as dx-driver: the recipe sets S = "${WORKDIR}/git", which
# is a hard QA error since oe-core dropped the source-move compatibility shim
# (53e9ea30aaf). The git fetcher's destsuffix now follows the new S default,
# so the checkout lands at ${UNPACKDIR}/${BP}.
#
# This happens to equal oe-core's own default for S. It is restated rather
# than removed because the recipe sets S explicitly and a bbappend cannot
# unset it — the assignment has to be overridden, not deleted.
S = "${UNPACKDIR}/${BP}"

# Drop the SysV init script. The recipe does `inherit update-rc.d` with
# INITSCRIPT_NAME = "dxrt-init", but this distro removes sysvinit from
# DISTRO_FEATURES entirely (iotgw-common.inc:178), so the script installs into
# /etc/init.d and can never run. Shipping a dead init script is worse than
# shipping nothing: it looks like the service is managed when it is not.
#
# The daemon is started by dxrtd.service from iotgw-deepx-runtime instead —
# a native unit ordered after module load, running under a dedicated account.
# Upstream's own dxrt.service exists but is commented out in the recipe and is
# three lines with no ordering or confinement, so it is a reference, not a
# drop-in.
do_install:append() {
    rm -f ${D}${sysconfdir}/init.d/dxrt-init
    rmdir --ignore-fail-on-non-empty ${D}${sysconfdir}/init.d 2>/dev/null || true
}

FILES:${PN}-cli:remove = "${sysconfdir}/init.d/dxrt-init"

# NOTE: the pip build-isolation fix is NOT here. It lives in
# patches/meta-deepx-m1/0002-dx-rt-no-build-isolation.patch, applied to the
# layer by kas, because --no-build-isolation has to go INSIDE upstream's own
# pip invocation and a bbappend cannot edit the middle of a shell function.
#
# An earlier attempt exported PIP_NO_BUILD_ISOLATION = "1" from here. It does
# not work: the variable was confirmed present in the generated task script
# (run.do_install line 95, `export PIP_NO_BUILD_ISOLATION="1"`) and pip still
# went down the build-isolation path and tried to download setuptools. Do not
# reinstate it — it looks like it should work, which is what makes it a trap.
