# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version.
#
# CVE-2000-0006: a 2000-era issue long fixed; shipped strace 6.19 is unaffected.
# (oe-core carries the same call in cve-extra-exclusions.inc, which this distro
# does not `require`.) https://nvd.nist.gov/vuln/detail/CVE-2000-0006
CVE_STATUS[CVE-2000-0006] = "fixed-version: 2000-era issue long fixed; shipped strace 6.19"
