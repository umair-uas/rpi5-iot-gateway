# SBOM & CVE Scanning — Field Guide

How this repo generates a software bill of materials and CVE report for an
image, how to read them, and how to turn a scanner row into a defensible
engineering disposition. For carrying a kernel fix as a backport patch, see
[Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md); this page is the
image-wide scanning + userspace-triage companion.

---

## What it is

Scanning runs `sbom-cve-check` (bootlin) over the image's SPDX 3.0 graph:

- `kas/cve.yml` is an additive overlay that enables `create-spdx` +
  `sbom-cve-check` and sets `SPDX_INCLUDE_VEX = "all"`, so `CVE_STATUS`
  dispositions flow into the report as VEX.
- The scanner databases (NVD-FKIE and CVE-List-V5) are **pinned by SRCREV** in
  `kas/cve.yml` and fetched with auto-update disabled — a scan is reproducible
  with respect to database content. "Reproducible" is not "current": the pinned
  database has a deliberate age; refresh it on a policy cadence.
- The custom kernel recipe normalises `CVE_PRODUCT = "linux_kernel"` /
  `CVE_VERSION = "${LINUX_VERSION}"` and emits compiled-source SPDX, which keeps
  the kernel from flooding the report with CPE mismatches.

Provenance is Yocto's and is trusted: `testdata.IMAGE_NAME`,
`SpdxDocument.name`, and the deploy filename stem are one identity; buildhistory
records every layer revision; the deployed database `HEAD`s equal the SRCREV
pins. This guide does not add a parallel provenance system — it only makes the
host-side readers select and present one build unambiguously.

## Running a scan

```bash
make sbom-cve        # build iot-gw-image-dev with the CVE/SBOM overlay + scan
make cve-report      # summarise the CVE report (buckets, kernel split, scaffold)
make sbom-report     # summarise the SBOM (license inventory + HIGH-risk review)
make test-sbom-cve   # fixture tests for the readers (no build)
```

`make sbom-cve` is opt-in and slow (SPDX generation over the whole image); it is
deliberately not run on every build, and CI runs no Yocto builds. Reports land
in `build/tmp/deploy/images/<machine>/` and are **never committed** — they are
regenerated on demand.

## Reading the CVE report

`make cve-report` (reader: `scripts/sbom-cve/cve-report.py`) prints:

- a provenance line naming the **dated** report file that was read;
- `# status totals: Ignored=N, Patched=N, Unpatched=N` — the scanner buckets;
- a CISA CVSS distribution and a **kernel/userland split** (the kernel needs
  config-aware triage, so it is hidden by default — `--kernel` to include);
- the sorted Unpatched rows, and, with `--cve-status`, a `CVE_STATUS[...]`
  scaffold grouped by recipe for hand triage; `--csv` dumps every row.

Useful flags: `--status <Patched|Ignored|Unpatched|*>`, `--top N`, `--all`.

`make sbom-report` gives the license inventory, category tally, download-coverage
gap (over *source* nodes only), and a HIGH-risk license review.

## Same-build safety

Every image output shares one `IMAGE_NAME` stem, e.g.
`iot-gw-image-dev-<machine>.rootfs-<BUILDNAME>`, alongside an un-dated
`*.rootfs.*` symlink to the newest. The readers:

- resolve the **dated** file (not the symlink), so the provenance line always
  identifies the exact build;
- run a same-build check and print `# WARNING:` lines when the selected scan is
  a copy (a required `.manifest`/`.testdata.json` companion is missing), its
  testdata `IMAGE_NAME` disagrees with the stem (mismatched pairing), or a
  **newer image build exists** than the scan (image rebuilt, scan not re-run);
- accept `--strict` to exit non-zero on a cohort **integrity** failure
  (a missing/mismatched companion), and `--require-latest` to additionally fail
  when a **newer** image build exists than the scan. A stale-but-intact scan
  chosen with `-i` is a deliberate selection, so it is not an integrity failure;
  interactive use warns and continues.

**Convention:** a scan and its image outputs (`.manifest`, `.testdata.json`,
`.spdx.json`, `.sbom-cve-check.*.json`) belong together — reference and archive
them **by the shared stem**, never the symlink. `testdata.json` can contain
secrets; the readers read only its `IMAGE_NAME` and never print or copy it.

## Triaging a row into a disposition

A scanner row is not a verdict. Before adding metadata or dropping a finding
from the actionable set, ground the conclusion in a **retained, re-derivable**
artifact — record the command, not just the prose. The scanner flattens
everything to `Patched`/`Ignored`; capture the real engineering meaning:

| Disposition | Minimum evidence |
|---|---|
| `fixed-version` | shipped version (manifest) past the upstream fixed boundary/commit |
| `cpe-incorrect` | wrong-product proof (e.g. a match against a different project of the same name) |
| `not-applicable-config` | the vulnerable feature is compiled out (`do_configure`/defconfig line) **and**, if a binary, the provider is another package |
| `not-applicable-platform` | the advisory's platform scope vs. this image's `aarch64` |
| `disputed` | an upstream/CNA dispute link |
| component-not-present | `files-in-image.txt` showing the package is build-closure only, not installed — express at **image/product VEX**, never a recipe `fixed` |
| left open | an explicit reason; nothing proven yet (e.g. kernel ancestry pending) |

**Scope rules for where metadata lives:**

- recipe-wide facts (fixed-version, wrong-CPE, feature-off) → that recipe's
  `.bbappend`;
- distro-wide false positives true across all images → a distro include
  (`conf/distro/include/iotgw-cve-ignores.inc`);
- build-closure-only absence → image/product VEX or the triage record, **not** a
  global recipe suppression.

**Preserve uncertainty.** Do not collapse a multi-row fan-out (one CVE emitted
against many binary packages of the same source) into a single "newer version"
claim without confirming the shared source. Do not adopt OE-Core exclusions
wholesale to lower a count — each must be reviewed for applicability to this
image's configuration and threat model. `no-version-range` kernel/glibc rows
stay open until proven, not bulk-suppressed because they look old.

## Kernel CVEs

Kernel triage differs from userspace: the question is **fix-commit ancestry +
compiled-config reachability**, not a version-range boundary. The kernel recipe
already includes OE-Core's generic and version-specific `cve-exclusion*.inc`;
the residual `no-version-range` rows need per-CVE work. OE-Core's
`improve_kernel_cve_report.py` can enrich the report from the compiled-source
SPDX (dropping CVEs whose files are not built), but its output must pass a
validation gate before it is trusted:

1. the compiled file set is large and plausible, with kernel-relative roots
   (`arch/`, `fs/`, `net/`) aligned to the CNA `programFiles`;
2. CVEs in known-compiled subsystems still survive as affected — if a compiled
   subsystem's CVEs all vanish, the compiled-path roots are misaligned and the
   result is a false mass "not applicable," not a real reduction;
3. the internal tally reconciles against the total kernel-CNA set.

Exact string matching means a path-root mismatch silently reclassifies
everything as not-applicable and looks like success — always run the gate.
Carry a security fix even when today's Kconfig disables the vulnerable path, so
a later config change cannot expose unpatched source. Patch mechanics:
[Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md).

## Not this

- Do not commit generated SBOM/CVE artifacts (they are large and rebuildable).
- Do not synthesise `CVE_STATUS` from a version string or a CVE's age alone.
- Do not treat a matching filename timestamp as proof two artifacts share a
  build — use the stem + the readers' same-build check.
