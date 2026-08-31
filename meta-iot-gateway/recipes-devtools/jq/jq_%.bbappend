# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version.
#
# CVE-2025-49014: regression introduced in jq 1.8.0 and fixed for 1.8.1
# (shipped). https://nvd.nist.gov/vuln/detail/CVE-2025-49014
CVE_STATUS[CVE-2025-49014] = "fixed-version: fixed in jq 1.8.1 (shipped)"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2026-40164.patch"
