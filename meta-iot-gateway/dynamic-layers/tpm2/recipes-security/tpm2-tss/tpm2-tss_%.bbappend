# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version. tpm2-tss comes from meta-tpm2 (composed via the
# kas/tpm.yml overlay); this append lives under dynamic-layers/ so it is parsed
# only when that layer is present (wrynose fails hard on dangling appends).
#
# CVE-2023-22745: fixed before tpm2-tss 4.1.3 (shipped).
# CVE-2024-29040: fixed in tpm2-tss 4.1.0; shipped 4.1.3.
#   https://nvd.nist.gov/vuln/detail/CVE-2023-22745
#   https://nvd.nist.gov/vuln/detail/CVE-2024-29040
CVE_STATUS[CVE-2023-22745] = "fixed-version: fixed before tpm2-tss 4.1.3 (shipped)"
CVE_STATUS[CVE-2024-29040] = "fixed-version: fixed in tpm2-tss 4.1.0; shipped 4.1.3"
