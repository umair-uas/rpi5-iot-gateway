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
  database has a deliberate age; refresh it on a policy cadence — procedure and
  traps in §"Refreshing the pin" below.
- The custom kernel recipe normalises `CVE_PRODUCT = "linux_kernel"` /
  `CVE_VERSION = "${LINUX_VERSION}"` and emits compiled-source SPDX, which keeps
  the kernel from flooding the report with CPE mismatches.

> **The compiled-source SPDX is vmlinux-only. Treat this as a hard property of
> the input, not a caveat.** When kernel modules are signed, debug-source
> capture is skipped for them during packaging: the packaging step returns
> early for a signed module so it is not stripped, and that same early return
> also skips source extraction — which is read-only and would have been safe.
> Every `.ko` therefore carries an **empty** source list while `vmlinux`
> carries all of them.
>
> Nothing in the output marks the gap. The modules are present as entries, just
> with no sources, so any consumer reading "compiled sources" from this data
> sees a built-in-only kernel and concludes that no module code is built.
> `--debug-sources-file` reads the same data and has the identical hole.
>
> Check it against your own tree — any `.ko` with zero sources means the blind
> spot is present:
>
> ```bash
> zstdcat build/tmp/pkgdata/<machine>/debugsources/<kernel-recipe>-debugsources.json.zstd \
>   | python3 -c 'import json,sys
> d = json.load(sys.stdin)
> ko = [k for k in d if k.endswith(".ko")]
> print(len(ko), "modules,", sum(1 for k in ko if not d[k]), "with zero sources")'
> ```
>
> On this tree that reports every module blind (`1357 modules, 1357 with zero
> sources`), against a `vmlinux` entry carrying 7428. Until the packaging
> behaviour is fixed **and that fix reaches our pinned layers**, this input
> cannot answer "was this module compiled". Fixed upstream is not the same
> event as fixed here.

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

## Refreshing the pin

`RELEASE.md` makes this mandatory before a release, and the reason is the one
stated above: a scan reports what was known at the pinned cutoff, not what is
known today. Shipping a count measured against a stale pin produces a
healthy-looking number that is silently blind to everything published since.

Read the current cutoff from the dated comments in `kas/cve.yml` — never from a
date written anywhere else. To move it:

**`DL_DIR` is a bitbake variable set in `kas/local.yml`, not a shell variable.**
An ambient `$DL_DIR` is not authoritative, and the failure is not that it is
merely unset: on this project's host it has carried a leftover export pointing
at a pre-NVMe cache that no longer receives fetches. That is worse than empty —
an empty variable yields an obviously broken path, while a stale one silently
reads a real repository whose contents stopped advancing months ago. Ask
bitbake:

```bash
# 0. Resolve DL_DIR through the same configuration the build uses.
DL_DIR=$(. scripts/env.sh >/dev/null 2>&1 && \
         kas shell kas/local.yml:kas/cve.yml \
           -c 'bitbake-getvar -q --value DL_DIR' 2>/dev/null | tail -1)
[ -d "$DL_DIR" ] || { echo "DL_DIR did not resolve: '$DL_DIR'"; exit 1; }

# 1. Ask UPSTREAM what the current head is. This is the only step that yields a
#    NEW revision — see the warning below about reading the local mirror.
git ls-remote https://github.com/CVEProject/cvelistV5.git         main
git ls-remote https://github.com/fkie-cad/nvd-json-data-feeds.git main

# 2. What is already local? Objects present here cost no network on the next
#    build. This is an informational comparison, NOT a source of new SHAs.
git -C "$DL_DIR/git2/github.com.CVEProject.cvelistV5.git"         log -1 --format='%H %ci' main
git -C "$DL_DIR/git2/github.com.fkie-cad.nvd-json-data-feeds.git" log -1 --format='%H %ci' main

# 3. Edit BOTH SRCREVs in kas/cve.yml to the step-1 values, updating the date
#    comment above each to that commit's date.

# 4. Confirm BOTH new values actually bind, in RECIPE context, before starting a
#    long build. Two pins were edited, so two must be verified — checking only
#    one leaves the other free to be a typo that silently keeps the old database.
. scripts/env.sh && kas shell kas/local.yml:kas/cve.yml -c "\
  bitbake-getvar -q -r sbom-cve-check-update-cvelist-native --value SRCREV; \
  bitbake-getvar -q -r sbom-cve-check-update-nvd-native     --value SRCREV"
```

> **Never take the new revision from the local mirror.** Auto-update is
> disabled and the fetch is pinned, so the mirror's `main` does not advance on
> its own — in practice it sits at exactly the commit you already pinned.
> Reading it and pasting the result back into `kas/cve.yml` is a refresh that
> changes nothing while looking like it worked. Measured on this tree: mirror
> `main` was `d34c2612…`/`b9056dbe…`, identical to the pins in `kas/cve.yml`,
> while upstream had moved on. Step 1 is the only authoritative source.

> **Verify in recipe context, not the global datastore.**
> `bitbake-getvar --value SRCREV:pn-<recipe>` only proves the *assignment
> exists* in the configuration. `-r <recipe> --value SRCREV` resolves the
> **effective** value that recipe will fetch, after overrides and expansion —
> which is the property this step claims to check. The two agree when
> everything is correct, which is exactly why the weaker form cannot be used to
> detect the case where they don't.

Sourcing `scripts/env.sh` is not optional outside an interactive shell.
Interactive shells pick it up via direnv; **agent tool-shells and CI do not**,
and a bare `kas shell` without it re-clones the entire layer stack into the repo
root (`AGENTS.md`).

Then re-scan and **classify the whole delta**, not the top N — a refresh moves
CVEs in both directions, and the newly-visible ones are the point of the
exercise. Expect the unpatched count to rise; that is the pin's debt coming due,
not a regression.

**Cadence.** No fixed interval is mandated, but the pin's age is a release-time
question: refresh and re-scan before a release rather than shipping a count
measured against an arbitrarily old database, and state the cutoff alongside any
figure that leaves the project.

Two traps, both live:

- The `SRCREV:pn-…` overrides are keyed on **PN** while upstream carries the
  database date in **PV**. They therefore survive a layer bump and keep binding
  whatever `kas/cve.yml` says — so bumping layers without editing these two
  lines silently reverts the database advance the bump would have brought.
- Local corpus clones kept for lookups are often shallow (`--depth 1`) and
  cannot serve as a fetch source for a pinned SRCREV. Check with
  `git rev-parse --is-shallow-repository` before assuming a SHA is available
  locally.

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
| `not-applicable-config` | the vulnerable feature is compiled out (`do_configure`/defconfig line) **and**, if a binary, the provider is another package. **Kernel: a stronger bar applies — see below** |
| `not-applicable-platform` | the advisory's platform scope vs. this image's `aarch64` |
| `disputed` | an upstream/CNA dispute link |
| component-not-present | `files-in-image.txt` showing the package is build-closure only, not installed — express at **image/product VEX**, never a recipe `fixed` |
| left open | an explicit reason; nothing proven yet (e.g. kernel ancestry pending) |

**A wrong `Ignored` will not be corrected *for* you.** The CNA re-derivation
pass (see *Kernel CVEs*) will not reopen a row already dispositioned `Ignored`
in our report — suppression takes precedence over correction. A wrong
`fixed-version` can still be caught by a fresher database; a wrong `Ignored`
removes the row from the set that fresher data is applied to, so no amount of
better upstream data will surface it again.

That is a durability claim, not an irreversibility one: remove or correct the
originating `CVE_STATUS` and rebuild, and the row reopens normally. The point
is that nothing will *prompt* you to — the finding simply stops appearing, and
the only thing that brings it back is a human revisiting the disposition. When
the evidence is thin, leave the finding open instead.

**`not-applicable-config` for the kernel needs a stronger bar than for
userspace.** Absence from the compiled-source SPDX is *not* evidence that code
was not built — see the blind spot under *What it is*. Nor is `=m` a defence: a
module is compiled, packaged, installed in the image, and one `modprobe` or one
udev match away from being live. The bar for a kernel `not-applicable-config`
is that **no object was produced in the build tree** for the affected source.

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

Kernel triage differs from userspace and has its own guide:
[Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md). The question there is
**fix-commit ancestry + compiled-config reachability**, not a version-range
boundary, and answering it needs evidence this pipeline does not produce.

Three things to know before reading a kernel row here:

- The kernel recipe already includes OE-Core's generic and version-specific
  `cve-exclusion*.inc`; the residual rows are what needs per-CVE work.
- **CNA re-derivation is adopted** — it corrects rows the pinned database
  reports from an incomplete snapshot. **Compiled-file suppression is not
  adopted**, and its output must not be used for any triage decision. They are
  two separable jobs of one tool. Procedure and rationale:
  [Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md).
- The compiled-source SPDX this build produces is **vmlinux-only**, so it cannot
  answer "was this module compiled". That guide carries the local check and the
  sanctioned evidence source in its place.

Rows that a compiled-file filter would have dropped **stay visible**, carried as
`vulnerable-investigating` — open and unproven in either direction. Do not
invent a status value to express "probably not compiled";
`decode_cve_status()` warns, falls back to `Unpatched`, and discards the reason
string.

The general decision model both guides sit inside — the stage order, the
suppression and export policy, and where each kind of statement belongs — is
[CVE Applicability](CVE_APPLICABILITY.md). Patch mechanics:
[Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md).

## Not this

- Do not commit generated SBOM/CVE artifacts (they are large and rebuildable).
- Do not synthesise `CVE_STATUS` from a version string or a CVE's age alone.
- Do not treat a matching filename timestamp as proof two artifacts share a
  build — use the stem + the readers' same-build check.
