# CVE-2024-2397 — DELIBERATELY NOT DISPOSITIONED. Do not re-add a CVE_STATUS
# here without new evidence.
#
# This file previously asserted "fixed-version: fixed before tcpdump 4.99.5;
# shipped 4.99.6". That boundary could not be established from any corpus we
# check against: the CVE 5 record cites only git SHAs (0d4083e < b9811ef) and no
# version range, and neither NVD nor Debian supplies one. Shipped 4.99.6 is
# plausibly ahead of any boundary those SHAs imply — plausibly is not evidence,
# and a fixed-version entry converts the finding to Patched on the strength of
# it.
#
# Leaving no entry keeps the row open in the report, which is the correct state
# for an unverified claim and is what the report is for. To close it, demonstrate
# release-tag/fix-commit ancestry independently — e.g. show the fix commit is an
# ancestor of the tcpdump-4.99.5 tag in the upstream repository — and record that
# command and its output, not a conclusion.
#
# https://nvd.nist.gov/vuln/detail/CVE-2024-2397
