# Our weston.ini replaces oe-core's via FILESEXTRAPATHS search order.
#
# It belongs on weston-init, NOT on weston: weston-init is the recipe that owns
# ${sysconfdir}/xdg/weston/weston.ini (weston-init.bb:62,99-100) and that also
# seds PACKAGECONFIG-derived settings into it (backend=, xwayland, idle-time,
# use-pixman). Attaching a second copy to the `weston` recipe — which this layer
# previously did — produced two packages owning one path and a fatal
# do_rootfs RPM conflict.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Filename note: this is `weston-init.bbappend`, NOT `weston-init_%.bbappend`.
# oe-core ships the recipe as an UNVERSIONED `weston-init.bb`, and the `_%`
# wildcard only matches versioned recipe filenames — a `_%` bbappend here
# matches nothing and bitbake fails the build with
# "No recipes in default available for: .../weston-init_%.bbappend".
# (The old weston_%.bbappend worked because that recipe IS versioned,
# weston_15.0.0.bb.)

# Drop-in that removes the PAM login session from weston.service. Without it
# the compositor cannot start on this distro at all (status=224/PAM) — see the
# file itself for the full diagnosis and why the fix is here rather than in the
# password-aging policy.
SRC_URI += "file://iotgw-weston-no-pam.conf"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/iotgw-weston-no-pam.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/iotgw-weston-no-pam.conf
}

FILES:${PN} += "${systemd_system_unitdir}/weston.service.d/iotgw-weston-no-pam.conf"
