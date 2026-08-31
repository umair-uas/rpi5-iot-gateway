# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version.
#
# CVE-2024-7254: unbounded recursion parsing untrusted protobuf data. Fixed in
# upstream 28.2 (and 3.25.5 / 4.27.5 on the older lines).
#
# READ THE VERSION CAREFULLY — the recipe's PV is NOT the upstream release. This
# recipe versions protobuf as <soname-major>.<upstream>, and the recipe itself
# strips the first component back off when it fetches:
#     PROTOC_VERSION = "v" + PV.split(".", 1)[1]
# So PV 6.33.6 is upstream tag v33.6, which is well past both the 28.2 fix and
# the 3.25.5 backport. A reader who compares "6" against "28" concludes the
# opposite, which is why this note exists.
#
# Deliberately NOT cpe-incorrect: the flaw is commonly described as Java-only,
# but Debian patched the C++ package for it as well, so the CPE match against our
# build is legitimate. It is a genuine match against a version that carries the
# fix. https://nvd.nist.gov/vuln/detail/CVE-2024-7254
CVE_STATUS[CVE-2024-7254] = "fixed-version: PV 6.33.6 is upstream v33.6, past the 28.2 fix"
