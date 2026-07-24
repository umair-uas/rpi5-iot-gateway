# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped CPython point release.
#
# All of the following were backported to CPython 3.14.4 (affected 3.14.0-3.14.3);
# this image ships 3.14.4. The scanner's "fixed from 3.15.0" hint reflects the
# 3.15-alpha main-branch fix and misses the 3.14.4 stable backport; per-CVE OSV
# ranges confirm 3.14.4 is the first fixed 3.14.x release.
#   https://osv.dev/vulnerability/CVE-2025-13462  (tarfile DIRTYPE normalization)
#   https://osv.dev/vulnerability/CVE-2026-2297   (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3644    (http.cookies control chars)
#   https://osv.dev/vulnerability/CVE-2026-4224    (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3479    (fixed 3.14.4; also PSF-disputed, CVSS 0.0)
#
# NOTE: imaplib/poplib CVE-2025-15366 / -15367 are NOT suppressed here — they are
# fixed only in 3.15.0a6 and 3.14.x (incl. 3.14.4) remains affected. Those need a
# backport, not a status entry.
CVE_STATUS[CVE-2025-13462] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-2297] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3644] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-4224] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3479] = "disputed: PSF-disputed, CVSS 0.0; also fixed in 3.14.4 (shipped)"
