# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version.
#
# CVE-2024-12084: affects rsync 3.2.7/3.3.0; shipped 3.4.1 is outside the
# affected set. https://nvd.nist.gov/vuln/detail/CVE-2024-12084
CVE_STATUS[CVE-2024-12084] = "fixed-version: shipped rsync 3.4.1 is past the fixed boundary"
