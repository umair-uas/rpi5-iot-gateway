# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check wrong-product matches.
#
# CVE-2025-64170 / CVE-2025-64517 affect the separate Rust sudo-rs
# implementation, not the classic C sudo 1.9.17p2 shipped here.
#   https://nvd.nist.gov/vuln/detail/CVE-2025-64170
#   https://nvd.nist.gov/vuln/detail/CVE-2025-64517
CVE_STATUS[CVE-2025-64170] = "cpe-incorrect: affects the Rust sudo-rs, not classic C sudo (shipped)"
CVE_STATUS[CVE-2025-64517] = "cpe-incorrect: affects the Rust sudo-rs, not classic C sudo (shipped)"

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2026-35535.patch"
