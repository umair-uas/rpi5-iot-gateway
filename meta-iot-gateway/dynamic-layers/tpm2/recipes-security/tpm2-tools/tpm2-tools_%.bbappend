# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version. tpm2-tools comes from meta-tpm2 (composed via the
# kas/tpm.yml overlay); this append lives under dynamic-layers/ so it is parsed
# only when that layer is present (wrynose fails hard on dangling appends).
#
# CVE-2024-29039: fixed in tpm2-tools 5.7 (shipped).
# CVE-2017-7524: affects tpm2-tools releases before 1.1.1; shipped 5.7.
#   https://nvd.nist.gov/vuln/detail/CVE-2024-29039
#   https://nvd.nist.gov/vuln/detail/CVE-2017-7524
CVE_STATUS[CVE-2024-29039] = "fixed-version: fixed in tpm2-tools 5.7 (shipped)"
CVE_STATUS[CVE-2017-7524] = "fixed-version: affects tpm2-tools < 1.1.1; shipped 5.7"
