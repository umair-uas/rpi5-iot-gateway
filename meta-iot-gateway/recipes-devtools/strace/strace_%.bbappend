# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches.
#
# CVE-2000-0006 is NOT a fixed-version case, and this file previously claimed it
# was. OE-Core's own disposition (meta/conf/distro/include/cve-extra-exclusions.inc)
# is `upstream-wontfix`: the CVE is more than 20 years old with no resolution
# evident, and the broken reference links in the CVE database make one
# impractical to establish. "No resolution is known" and "long since fixed" are
# opposite claims; only the first is supported by evidence, and asserting the
# second silently converted an unresolved finding into Patched.
#
# This distro does not `require` cve-extra-exclusions.inc, so the entry is
# adopted verbatim here — including OE-Core's cpe scope — rather than
# paraphrased, so a later diff against upstream stays trivial.
# https://nvd.nist.gov/vuln/detail/CVE-2000-0006
CVE_STATUS[CVE-2000-0006] = "upstream-wontfix: cpe:*:strace: CVE is more than 20 years old \
with no resolution evident. Broken links in CVE database references make resolution impractical."
