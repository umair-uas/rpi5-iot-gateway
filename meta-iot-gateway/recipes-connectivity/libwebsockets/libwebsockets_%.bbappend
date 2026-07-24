# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches that are fixed
# in the shipped version or scoped to a platform this image does not build.
#
# CVE-2025-1866: the flaw is in the Win32 code path and affects releases before
# 4.3.4; this image ships 4.5.8 on linux/aarch64. Past the fixed boundary and
# wrong platform. https://nvd.nist.gov/vuln/detail/CVE-2025-1866
CVE_STATUS[CVE-2025-1866] = "fixed-version: shipped libwebsockets 4.5.8 > fixed 4.3.4 (and the flaw is Win32-only)"
