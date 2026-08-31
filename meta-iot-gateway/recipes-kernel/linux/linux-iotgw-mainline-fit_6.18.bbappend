# Kernel CVE exclusions -- 13180 generated CVE_STATUS entries for 6.18.37.
#
# READ THIS BEFORE TRUSTING, EXTENDING OR DELETING THE FILE. Its original
# justification no longer holds, and the replacement justification is not yet
# measured.
#
# Original reason (obsolete): OE-core shipped
# recipes-kernel/linux/cve-exclusion_6.18.inc as a point-in-time snapshot that
# went stale between layer pin bumps -- at our previous pin it was generated for
# 6.18.24 while we ship 6.18.37. Carrying our own regenerated copy beat that
# stale snapshot.
#
# What changed: OE-core commit b737508e638 ("linux-yocto: remove CVE exclusion
# list, sbom-cve-check does this itself", 2026-05-20) DELETED both the exclusion
# list and generate-cve-exclusions.py. Upstream's argument is that
# sbom-cve-check reads MITRE cvelistV5, which is fed by vulns.git, and NVD has
# prioritised the kernel for enrichment -- so the scanner already has the same
# metadata. Upstream measured the effect as ~20 MB less SPDX with the reported
# CVE list unchanged.
#
# Why the file is still here: upstream measured that against linux-yocto, at
# database tip. We ship a different kernel recipe and pin the CVE database
# (kas/cve.yml), and our own earlier delta measurements compared this file
# against OE-core's STALE 6.18.24 copy -- not against having no file at all,
# which is the comparison upstream's claim is about. Those are different
# experiments, and only the second one answers whether these 13180 entries
# still move a row.
#
# OPEN: run the differential -- one scan with this include, one without, same
# commit and same database pin, and classify every row that moves in either
# direction. If nothing moves, delete this file and the include below; the
# entries are then pure SPDX weight. If rows move, record which and why, and
# this comment gets replaced by that evidence. Do not delete it on upstream's
# measurement alone.
#
# Mechanics, still accurate: a same-path shadow file in this layer does NOT
# override an OE-core include -- include/require resolve via plain BBPATH search
# (first match wins) and BBPATH puts .kas/openembedded-core/meta ahead of this
# layer, unlike FILESEXTRAPATHS/PROVIDES which do respect layer priority.
# Verified by testing, not assumed. ${THISDIR} sidesteps BBPATH entirely.
#
# Regenerating: generate-cve-exclusions.py no longer exists upstream. To refresh
# this file, take the script from OE-core before b737508e638 and run it against
# a current clone of https://git.kernel.org/pub/scm/linux/security/vulns.git:
#   python3 <generator> <vulns-clone> <LINUX_VERSION>
# Pull the vulns clone --ff-only first; the data must be current, not just
# present. Only worth doing if the differential above shows the file still
# earns its place.
include ${THISDIR}/files/cve-exclusion_6.18.inc
