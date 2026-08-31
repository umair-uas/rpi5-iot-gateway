# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped CPython point release.
#
# All of the following were backported to CPython 3.14.4 (affected 3.14.0-3.14.3);
# this image ships 3.14.4. The scanner's "fixed from 3.15.0" hint reflects the
# 3.15-alpha main-branch fix and misses the 3.14.4 stable backport; per-CVE OSV
# ranges confirm 3.14.4 is the first fixed 3.14.x release.
#   https://osv.dev/vulnerability/CVE-2025-13462  (tarfile DIRTYPE normalization)
#   https://osv.dev/vulnerability/CVE-2026-2297   (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3644    (http.cookies control chars)
#   https://osv.dev/vulnerability/CVE-2026-4224    (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3479    (fixed 3.14.4; also PSF-disputed, CVSS 0.0)
#
# NOTE: imaplib/poplib CVE-2025-15366 / -15367 are deliberately absent from the
# list above. They are fixed only in 3.15.0a6, so 3.14.4 really is affected and a
# status entry would be a false claim. They are carried as backports in SRC_URI
# instead.
#
# The scanner does NOT currently credit those two backports — it reports both as
# Unpatched / version-in-range. That is known and deliberate for now.
# oe.cve_check.parse_cves_from_patch_file() only reads a CVE id from the patch
# FILENAME or from a line starting with "CVE:", and these patches carry the id
# only in the git Subject line. The fix is to rename them to CVE-<id>.patch and
# add a "CVE:" header, which has been validated (the recipe SPDX then emits a
# VexFixed/fix-file-included relationship with a patchedBy edge).
#
# It is not applied here because changing SRC_URI rebuilds python3-NATIVE
# (BBCLASSEXTEND = "native nativesdk"), whose sysroot feeds util-linux-native ->
# e2fsprogs-native -> libarchive-native -> rpm-native, and rpm-native is a
# dependency of do_package for every recipe in the image. One filename change
# therefore invalidates the packaging step of the entire distro. Batch it with
# other source-affecting work (patch adds, PV bumps) on a build day rather than
# paying that cost on a metadata/triage pass.
CVE_STATUS[CVE-2025-13462] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-2297] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3644] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-4224] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3479] = "disputed: PSF-disputed, CVSS 0.0; also fixed in 3.14.4 (shipped)"
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0001-python3-reject-control-characters-in-IMAP-commands-C.patch file://0002-python3-reject-control-characters-in-POP3-commands-C.patch"

