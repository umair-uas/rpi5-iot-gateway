# Kernel CVE Applicability

The kernel extensions to the general decision model in
[CVE Applicability](CVE_APPLICABILITY.md). Everything there applies; this page
states what changes for a kernel recipe and what the sanctioned S4 procedure is.
Patch mechanics live in [Kernel CVE Patch](KERNEL_CVE_PATCH.md); the scanning
pipeline in [SBOM & CVE Scanning](SBOM_CVE.md).

## The question is different

Kernel triage is **fix-commit ancestry plus compiled-config reachability**, not
a version-range boundary. A single upstream version number does not describe a
stable branch, and the CPE ranges that flatten it into one are the reason a
kernel floods the report with matches that mean nothing.

Two consequences shape everything below: the version question must be asked
**per stable branch**, and the applicability question must be answered from
**what the build actually produced**, not from what the configuration appears to
select.

## Identity normalisation comes first

No version arithmetic is valid until the kernel's identity is normalised.

- `CVE_PRODUCT` is pinned to the canonical kernel CPE, so the recipe is not
  matched under an incidental second product token.
- `CVE_VERSION` is the upstream `LINUX_VERSION`, not `PV`. A git `PV` carries
  multiple `+` segments and is not a PEP 440 version; tools that parse the
  report's `version` field reject it outright.
- Normalise the report before feeding it to any downstream tool, deriving the
  clean version from the report's own `cpes` field rather than typing it.
  `scripts/sbom-cve/kernel-cve-normalize.py` does this, writes a **copy**, and
  fails loudly rather than guessing when the data is ambiguous. Pass
  `--expect-version` with the `LINUX_VERSION` you believe you built so a
  disagreement is a hard error rather than a silent pick.

## Two separable jobs, judged separately

OE-Core's `improve_kernel_cve_report.py` does two things that rest on different
evidence and have different adoption status. Do not treat it as one tool.

**1. CNA re-derivation — adopted.** It re-reads each CVE against the kernel CNA
records and recomputes the per-branch fix boundary. `--spdx` is optional and
this path does not need it. The result is better than a pinned scanner database
on freshness and per-branch coverage — provided the exact feed revision is
recorded, without which the output is as unfalsifiable as the number it
replaces. A pinned database reports what was known at its cutoff, so a CVE whose
branch fix boundary was published afterwards can read `Patched` purely because
the record was incomplete when the snapshot was taken.

**2. Compiled-file suppression — not adopted.** Given `--spdx` or
`--debug-sources-file`, the tool also drops CVEs whose affected files it
believes were not compiled, emitting `Ignored`. That removes rows from the
actionable set silently and in the unsafe direction, on an evidence set that
cannot answer the question it is being asked (see below). Do not use its output
for any triage decision.

The reason is mechanistic and holds independently of any measurement: the
evidence set is vmlinux-only, so it cannot distinguish "not compiled" from
"compiled into a module". That the gap bites in practice, and by how much, has
been measured once — a run against the 2026-08-06 CVE data found that **77 of
the 375 suppressed rows (20.5%) were in code this image compiles**, every one of
them loadable-module code, checked against the build tree's own object files.
Re-measure rather than reuse that figure; it describes one build and one feed
revision.

### Running the CNA re-derivation

Adopt path 1 only.

**Pick the dated report, never the symlink** — the un-dated `*.rootfs.*` file is
a pointer to the newest build and will change under you.

```bash
R=build/tmp/deploy/images/<machine>/<image>-<machine>.rootfs-<BUILDNAME>.sbom-cve-check.yocto.json
```

**Prove integrity on the source report, before deriving anything.**

```bash
python3 scripts/sbom-cve/cve-report.py -i "$R" --strict --require-latest
```

**Normalise the kernel version.**

```bash
# Derive the expected version from the build — do not type it from memory.
LV=$(. scripts/env.sh >/dev/null 2>&1 && kas shell kas/local.yml:kas/cve.yml \
       -c 'bitbake-getvar -q -r linux-iotgw-mainline-fit --value LINUX_VERSION' \
       2>/dev/null | tail -1)

scripts/sbom-cve/kernel-cve-normalize.py \
  -i "$R" -o /tmp/cve-normalized.json --expect-version "$LV"
```

**Record the CVE-data commit — the answer is only as good as that snapshot.**

```bash
git -C <vulns-clone> log -1 --format='%H %ci'
```

**Run without `--spdx`.** That flag is what enables the unadopted suppression;
omitting it is the point.

```bash
python3 .kas/openembedded-core/scripts/contrib/improve_kernel_cve_report.py \
  --datadir <vulns-clone> \
  --old-cve-report /tmp/cve-normalized.json \
  --new-cve-report /tmp/cve-enriched.json
```

**Read the summary it prints as the gate.** The line reporting CVEs ignored due
to not-applicable config **must be zero** — that confirms nothing was
suppressed. Any non-zero value means a compiled-files flag crept back in and the
run must be discarded. The total-CNA line is the tally reconciliation: it should
account for every record the feed contains.

The run also prints each corrected row. Those are the findings a stale pinned
database was hiding, and they are the reason to run this at all.

**What the surviving vulnerable count is, and is not.** It is the number of CVEs
whose version range covers the built kernel — the honest upper bound with no
applicability filtering applied. It is not a count of exploitable issues, and it
is deliberately not reduced by compiled-file evidence.

### The enriched report is derived and cannot carry a cohort

Validate the source report, then derive from it. The same-build checks bind a
*scan* to its image outputs through neighbouring `.manifest` and
`.testdata.json` companions; a derived file has no companions and no build
identity, so it fails `--strict` by construction. Renaming it to preserve the
stem does not help — the companion lookup keys on the exact
`.sbom-cve-check.yocto.json` suffix.

Record a provenance block beside the enriched report so the derived numbers tie
back to a validated build:

```
source-report : <dated stem>.sbom-cve-check.yocto.json
source-sha256 : <sha256sum of that file>
feed-commit   : <CVE-data SHA from the step above>
derived-with  : kernel-cve-normalize.py -> improve_kernel_cve_report.py (no --spdx)
```

Read the enriched file **without** `--strict`. That is not a weaker check on the
same thing; it is a check that does not apply to this kind of file. The
build-integrity question was already answered on the source report.

## The compiled-source blind spot

**Treat this as a hard property of the input, not a caveat.** When kernel
modules are signed, debug-source capture is skipped for them during packaging:
the packaging step returns early for a signed module so it is not stripped, and
that same early return also skips source extraction. Every `.ko` therefore
carries an **empty** source list while `vmlinux` carries all of them.

Nothing in the output marks the gap. The modules are present as entries, just
with no sources, so any consumer reading "compiled sources" from this data sees
a built-in-only kernel and concludes no module code is built.
`--debug-sources-file` reads the same data and has the identical hole.

**The check is local and falsifiable — run it against your own tree.** Any `.ko`
entry with zero sources means the blind spot is present:

```bash
zstdcat build/tmp/pkgdata/<machine>/debugsources/<kernel-recipe>-debugsources.json.zstd \
  | python3 -c 'import json,sys
d = json.load(sys.stdin)
ko = [k for k in d if k.endswith(".ko")]
print(len(ko), "modules,", sum(1 for k in ko if not d[k]), "with zero sources")'
```

**The condition for retiring the build-object oracle is this check passing at
our pin — not any upstream event.** A fix merging upstream is not the same event
as a fix reaching this build. Until the check reports zero blind modules on a
tree we actually built, the compiled-source manifest cannot answer "was this
module compiled" and must not be used as if it could.

## The build-object oracle

**The normative S4 evidence source for the kernel is the build tree's own object
files.** For an affected source file, the question is whether the compiler
produced an object for it — covering built-in and module code alike.

Cross-check the derived set against `modules.order` (loadable) and
`modules.builtin` (built-in) so the oracle's own coverage is asserted rather
than assumed.

**State the dependency honestly, because it constrains when this can be run.**
The procedure requires the kernel build tree. `make clean` destroys it, CI does
not have one, and a workdir whose packaging tasks were restored from sstate may
contain built-in objects while containing no module objects at all — which looks
like a usable tree and is not. Therefore:

- A triage run that will record kernel S4 dispositions must **retain the build
  tree**, with the image stem recorded and the tree's kernel release matching
  the source revision the findings were derived against.
- Verify the tree before trusting it: objects must exist for known **module**
  code, not only for built-in code.
- If the tree is absent, incomplete, or does not match the revision under
  triage, the S4 answer is **"unverified"** — never "not applicable". An
  unavailable oracle is missing evidence, and missing evidence never suppresses.

## The revised gate — a falsifiable pre-flight

Run this **before** trusting any compiled-set output, not after. The failure it
exists to catch is a systematic evidence gap that reclassifies rows as
not-applicable while looking like success.

1. **Every subsystem the evidence set is used to clear must contribute `.c`
   files.** `Kconfig` and `Makefile` never count as proof that a subsystem was
   compiled. A subsystem represented only by build glue is not evidence of
   anything.
2. **Coverage is asserted against both `modules.order` and `modules.builtin`.**
   Root-level path alignment says nothing about depth: roots can align perfectly
   while an entire build category is missing.
3. **Known-loaded subsystems are canaries.** Take the subsystems actually loaded
   on the target and assert each contributes `.c` files to the evidence set.
   **Any zero aborts the run.**
4. **Tally reconciliation.** The internal counts must reconcile against the
   total kernel-CNA set. It catches bookkeeping errors that no amount of
   spot-checking will.

A gate that can only pass is not a gate. Each point above must be capable of
failing on a real run, and a failure aborts rather than downgrades.

**Dispositions recorded from an earlier three-point gate must be re-derived
against the build-object oracle before they are relied on.** That gate cleared a
compiled set on root-path alignment and on subsystem survival, neither of which
detects a missing build category, so a disposition it produced may rest on
evidence that never covered module code.

## `=m` is applicability; loaded-or-not is reachability

A module is compiled, packaged, installed, and one `modprobe` or one udev match
away from being resident. **`=m` is not a defence** and never an S4
not-applicable answer.

Whether a module is currently loaded is an S5 question of the weakest kind — it
describes one boot, not a property of the product. It does not suppress and does
not project to exported VEX. Resident is not reachable either: that a module is
loaded establishes the code is present, not that anything can drive it.

## Recording the outcome

**Where dispositions live:**

- **Version-range facts** → the generated kernel exclusion include, produced by
  OE-Core's generator against a current CVE-data clone and `include`d from the
  kernel `.bbappend` via `${THISDIR}`. **Never hand-edit it** — its own header
  says so, and a hand edit is silently clobbered on the next regeneration.
  Regenerate, don't patch. The file is a live build input and belongs in version
  control.
- **Hand dispositions** (config, platform) → a separate, tracked include beside
  the generated one, so they survive regeneration.
- **Everything else** — reachability, mitigation, unverified-for-lack-of-oracle
  — the ledger, per [CVE Applicability](CVE_APPLICABILITY.md).

**Interim state when evidence is unavailable.** The distinction between "proven
not compiled" and "probably not compiled, no oracle available" is **ledger-side**.
The only scanner-visible fallback is `vulnerable-investigating`, which maps to
`Unpatched` and means exactly what it says: open, unproven in either direction.

**Do not invent a `CVE_STATUS` value.** `decode_cve_status()` warns on an
unrecognised detail, falls back to `Unpatched`, and **discards the reason
string** — the nuance is lost, the warning is the only trace it was expressed,
and the row lands in the same bucket it would have reached honestly.

**Carry a security fix even when today's configuration disables the vulnerable
path**, so a later config change cannot expose unpatched source. A
not-applicable disposition is a statement about this build, not a reason to skip
a cheap backport.

## Traps

**Merge precedence, where the enrichment output is combined with our report.**
An `Ignored` in our report beats CNA correction entirely — so a wrong
suppression of ours is uncorrectable by better data, permanently. And an
`Unpatched → Patched` overwrite is accepted with only a warning. Check the
corrected-row output rather than assuming the merge preserved your intent.

**The `backported-patch` guard is dead code.** In `cve_update()` the protection
tests for a key that cannot be present in the structure it is given, so it never
fires. It is harmless while we carry no kernel CVE patches; it will silently
discard our own backport evidence the first time we do. If you carry a kernel
CVE backport, verify by inspection that the enrichment did not overwrite its
status.

**Out-of-tree code is invisible to the CNA data.** The kernel CNA describes
mainline. Any BSP or vendor code we carry outside it is not covered, and no
count derived from that feed describes it. State the scope: a kernel figure is
"of the mainline-CNA-tracked subset", never "the kernel".

## See also

- [CVE Applicability](CVE_APPLICABILITY.md) — the decision model, ledger and
  export policy
- [SBOM & CVE Scanning — Field Guide](SBOM_CVE.md) — pipeline, readers,
  userspace triage
- [Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md) — carrying a backport
- [Kernel Driver Backport](KERNEL_DRIVER_BACKPORT.md)
