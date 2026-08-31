# OE-core ships recipes-kernel/linux/cve-exclusion_6.18.inc as a point-in-time
# snapshot (kernel.org's own CNA output never stops, so it goes stale between
# layer pin bumps) and its own staleness check never fires for us: that check
# is wired to do_cve_check[prefuncs], but this distro scans via sbom-cve-check's
# do_sbom_cve_check task instead, so the warning is silently dead code here.
#
# A same-path shadow file in this layer does NOT override it -- include/require
# resolve via plain BBPATH search (first match wins), and BBPATH puts
# .kas/openembedded-core/meta ahead of this layer for that purpose (unlike
# FILESEXTRAPATHS/PROVIDES, which do respect layer priority). Verified by
# testing, not assumed. ${THISDIR} sidesteps this entirely -- it always
# resolves to this bbappend's own directory regardless of BBPATH order, and a
# bbappend's CVE_STATUS assignments run after the base recipe's, so ours
# override the stale ones for anything both files set.
#
# Regenerate with OE-core's own tool against a local clone of the kernel CVE
# data repository (https://git.kernel.org/pub/scm/linux/security/vulns.git):
#   python3 .kas/openembedded-core/meta/recipes-kernel/linux/generate-cve-exclusions.py \
#     <vulns-clone> <LINUX_VERSION>
# Run `git -C <vulns-clone> pull --ff-only` first -- the data needs to be
# current, not just present. Re-run whenever LINUX_VERSION moves.
include ${THISDIR}/files/cve-exclusion_6.18.inc
