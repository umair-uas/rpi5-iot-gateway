# CVE Applicability — Decision Model

How a scanner finding becomes a defensible engineering disposition, and where
the resulting statement lives. This is the decision system; the scanning
pipeline and userspace triage are in [SBOM & CVE Scanning](SBOM_CVE.md), the
kernel extensions in
[Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md), and patch mechanics in
[Kernel CVE Patch](KERNEL_CVE_PATCH.md).

Everything above the final section is generic Yocto/product-security practice
and is meant to be adopted unchanged by any distro in this family. Only
§"Project adapter" is specific to this repository.

---

## The model

Seven stages, asked in order, each with a short-circuit. The ordering is
load-bearing: it puts the cheap, deterministic, safely-suppressing questions
first, and the expensive, judgement-heavy ones last.

```
S0 Scan integrity ──▶ S1 Finding validity ──▶ S2 Product scope ──▶ S3 Code-level
   (else: no verdict)     (identity wrong)       (not shipped)        applicability
                               │                      │                    │
                               ▼                      ▼                    ▼
                        not-affected            not-in-product         fixed / affected
                                                                            │
                                              ┌─────────────────────────────┘
                                              ▼
                          S4 Build-time ──▶ S5 Reachability ──▶ S6 Mitigation
                             applicability     (priority only)     & remediation
                             (may suppress,     ───────────────────────────────
                              at a high bar)    ▶ never changes status ◀
```

Do not answer stage *N+1* before stage *N* has a recorded answer. That ordering
is what stops a finding that is out of product scope from acquiring an
irrelevant reachability argument, and what stops a weak build-time claim from
short-circuiting a version question that would have settled it outright.

## The five axes

Record five independent facts, not one status. Collapsing them is what produces
both false suppression and evidence that cannot be reused.

| Axis | Question | Legitimate outcomes |
|---|---|---|
| **Finding validity** | Is the scanner talking about our component at all? | valid · wrong-product · withdrawn · unparseable-identity |
| **Technical applicability** | Does the shipped artifact contain the vulnerable code, unfixed? | affected · fixed · code-absent · not-in-product · unverified |
| **Exploitability / reachability** | Can it be executed and driven in this product? | reachable · not-executable · dormant · unknown |
| **Mitigation** | What reduces exposure, and does that still hold? | controls, each with the assertion that verifies it |
| **Remediation** | What are we doing, by when? | bump · backport · config-change · accept · defer(date) · none-needed |

"Applicable" and "reachable" are different claims with different evidence. A
component that is compiled, packaged and installed is applicable whether or not
anything has invoked it yet.

## Suppression and export policy

**The suppression rule.** Only **S1, S2 and S3** may move a finding out of the
actionable set. **S4 may, at a deliberately higher bar.** **S5 and S6 may
never** — they set priority and drive the remediation decision, but a
reachability argument and a mitigation argument never produce `Ignored`.

**S4's bar is positive evidence of absence.** "Not found in the evidence set" is
not evidence that something was not built. Where the evidence is missing rather
than negative, the outcome is a non-suppressing *unverified* state carrying the
reason the evidence was unavailable.

**A wrong suppression is not symmetric with a wrong version claim.** A wrong
`fixed-version` can still be caught by a fresher database. A wrong `Ignored`
removes the row from the set that fresher data is ever applied to, so the error
becomes permanent and silent. When evidence is thin, leave the finding open.

**Internal suppression and external assertion are different acts.** The rule
above governs the internal actionable set and the scanner-facing channel. It
does not govern what the product may assert to a consumer in exported VEX. The
policy is asymmetric on purpose: carrying an over-reported finding internally is
cheap, publishing an under-claimed one is not.

- **S5/S6 never generate scanner suppression.** No `CVE_STATUS`, no `Ignored`,
  no removal from the internal worklist.
- **An S5 finding of `not-executable` MAY project to exported VEX
  `not_affected` with justification `vulnerable_code_not_in_execute_path`** —
  only when both hold: (a) the claim rests on an **invariant property of the
  shipped product** (the calling code does not exist in the image; no unit,
  socket or udev rule can start it; the entry point is not built) rather than on
  observed runtime state; and (b) the record carries a **machine-checkable
  revalidation trigger** that fails if that property stops holding. "Not
  currently loaded" and "not currently running" satisfy neither and never
  project.
- **Preference order is binding.** Where the same fact can be expressed as S2
  (the sub-package is not installed) or S4 (the file is not packaged), express
  it there — those are cheaper to verify, deterministic, and already
  suppression-grade. A VEX assertion derived from S5 is the last resort.
- **`inline_mitigations_already_exist` is out of policy.** Mitigated-but-present
  exports as `affected` with an action statement naming the control. A firewall
  rule, an SELinux domain or a privilege boundary reduces exposure; it does not
  make "this product is not affected" true.
- **Exported VEX is generated from the ledger, never hand-maintained.** A failed
  trigger flips the statement at the next export; that reversibility is what
  makes an S5-derived assertion defensible at all.

## The stages

### S0 — Scan integrity and currency

A precondition, not a triage question. No disposition derived from a scan that
fails S0 is valid.

- The **dated** report resolved, never the symlink; cohort companions present;
  no newer image build than the scan. Run the readers with `--strict`
  (and `--require-latest`) for anything that will be recorded.
- Both **database cutoffs** recorded *in the record itself*: the scanner
  database revisions, and the CNA feed revision if kernel re-derivation ran.
  A count without its cutoffs is not evidence.
- **Layer pins** captured from `buildhistory/metadata-revs`.
- **Scan scope** asserted target-only, so build-host components cannot enter the
  product's finding set.

### S1 — Finding validity

| Sub-question | Evidence | Suppresses |
|---|---|---|
| Does the CPE product name our project? | an upstream, CNA or distro-tracker statement identifying a different codebase | yes → `cpe-incorrect` |
| Same name, different implementation? | the two projects' identities, e.g. a rewrite in another language shipped under the same name | yes → `cpe-incorrect` |
| Is the recipe `PV` the upstream version? | the recipe's own fetch logic — some recipes prepend a soname or strip a component | no, but it **invalidates version arithmetic** until normalised |
| Is the version string parseable? | a git `PV` with multiple `+` segments is not a PEP 440 version | no |
| Native or build-host component? | scan scope | yes → out of product scope |
| Withdrawn or disputed? | a CNA rejection, or an upstream dispute statement | yes → `disputed` |

A wrong-product claim looks identical to a version claim in the report, and the
version arithmetic runs regardless. Treat `PV` as unproven until checked; the
report's `cpes` field is the more reliable identity carrier.

### S2 — Product scope

Three distinct presence questions, answered per image and never per build:

1. In the build closure but **not installed in any image** → out of product
   scope everywhere.
2. Installed in an engineering image but **not in the shipped product** → in
   scope for the former, out for the latter.
3. Installed, but in a sub-package the product does not enable (a plugin, a
   `-tools` split) → needs `pkgdata` granularity, not the recipe name.

Evidence: the image `.manifest` plus `pkgdata/runtime-reverse` (the
package→recipe bridge), or
`buildhistory/images/<machine>/<libc>/<image>/installed-package-names.txt` for
an image not built in this cohort.

**This disposition is per-product and must never be written as a recipe-level
`CVE_STATUS`** — the recipe genuinely is affected. A projection onto an image
from a *different* cohort is indicative only and must be labelled as such, never
recorded as a disposition.

### S3 — Code-level applicability

| Question | Evidence, strongest first |
|---|---|
| Version past the fix boundary? | upstream release notes, the CNA per-branch boundary, or a curated advisory database — **never** the scanner's own hint |
| Fix carried as our backport? | a `SRC_URI` patch named `CVE-<id>.patch` or carrying a `CVE:` header, which yields `fix-file-included` with a `patchedBy` edge |
| Fix inherited from a vendor or distro backport? | the fix commit is an ancestor of our source revision |
| Vulnerable code absent from our source? | the affected function or file at our revision |
| Scanner conclusion disagrees with the source? | the disagreement *is* the finding — record both and resolve against source |

Two standing rules. Never establish a boundary by comparing commit dates through
a cgit `?h=<branch>&id=<hash>` URL; that does not filter by branch. And when the
boundary cannot be established at all — a record citing only commit hashes, with
no version range in any corpus — leave the row open. "The shipped version is
plausibly ahead" is not evidence, and `fixed-version` converts the finding to
`Patched` on the strength of it.

### S4 — Build-time applicability

The question is whether an artifact containing this code was produced.

| Domain | Sufficient evidence | Not sufficient |
|---|---|---|
| Kernel | see [Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md) | absence from a compiled-source manifest; `=m` |
| Userspace | the feature is `PACKAGECONFIG`-off **and** genuinely not compiled, confirmed from `do_configure` output or the built artifact — plus, for a binary, the provider being another package | the recipe not listing a `PACKAGECONFIG`; a plausible-looking symbol name |
| Platform | the advisory's platform scope against this machine's architecture, and the arch-conditional code | a platform named in the summary, unchecked against the code path |
| Packaging | the affected file or binary is in no installed package (`pkgdata` FILES) | the recipe being absent from a manifest — that is S2 |

### S5 — Runtime reachability

Three strengths of claim, which must be distinguished explicitly:

| Claim | Strength | Evidence |
|---|---|---|
| **Code cannot execute** — nothing in this product reaches it | strong; still not internally suppression-grade | the caller does not exist in the image; no unit, socket or udev rule; no entry point |
| **Not currently exercised** | weak | a module installed but not loaded; a daemon installed but disabled |
| **Harder to reach** | weakest | requires local access, authentication, or a protocol the product does not speak |

Only the first strength may project to exported VEX, under the export policy
above. Reclassify to S2 or S4 wherever the fact permits it.

### S6 — Mitigation and remediation

Two outputs, neither a status change.

**Mitigation record** — the architectural control that reduces exposure and the
assertion that verifies it still holds. A control with no executable assertion
is an argument, not a record.

**Remediation decision** — bump, backport, configuration change, accept, or
defer with a date. Order the work by dependency-closure cost rather than by how
small a package sounds; a one-CVE leaf recipe with a `-native` variant can be a
world rebuild.

**Risk acceptance is a product-level register entry, never a `CVE_STATUS`.**
Every value in that vocabulary asserts the finding is wrong or already handled;
none says "true, and we accept it".

## Where each statement lives

| Statement | Home |
|---|---|
| Recipe-wide version/identity facts (`fixed-version`, `cpe-incorrect`, `disputed`, `upstream-wontfix`) | that recipe's `.bbappend` `CVE_STATUS` |
| Cross-recipe fan-out over one upstream project | the distro CVE include, **`cpe:`-scoped, always** |
| Kernel version-range facts | the generated kernel exclusion include — regenerate, never hand-edit |
| Kernel hand dispositions (config, platform) | a separate, tracked hand-maintained include beside it |
| Product-scope absence | the product VEX layer, keyed by image — never a recipe `CVE_STATUS` |
| Reachability findings | the evidence ledger. May project to *exported* VEX only under the S5 export rule |
| Mitigation claims and their assertions | the evidence ledger. Exports as `affected` + action statement |
| Risk acceptance | the product risk register, reviewed per release |
| The reasoning, commands and outputs behind any of the above | the evidence ledger, with `scratch/` as the working scratchpad |

**Scope discipline for `CVE_STATUS`.** A distro-wide entry with no `cpe:` scope
decodes to vendor `*` / product `*` and is applied to **every recipe in the
build**, fabricating `Patched` rows against unrelated components. Both vendor
and product are mandatory once `cpe:` is present, and a malformed scope is
warned about and then silently dropped back to `*/*` — it fails open. Verify a
new entry against a recipe it must **not** match, not only one it must.

**On VEX.** VEX is the right export format and the wrong internal model — not
because it is inexpressive. OpenVEX carries five `not_affected` justifications
(`component_not_present`, `vulnerable_code_not_present`,
`vulnerable_code_not_in_execute_path`,
`vulnerable_code_cannot_be_controlled_by_adversary`,
`inline_mitigations_already_exist`) and four statuses, of which
`under_investigation` is exactly the state for an unresolved finding. Product
scope, uncertainty and risk acceptance are all expressible.

The gap is in our projection path:

1. **No per-image authoring mechanism.** `CVE_STATUS` resolves in a *recipe's*
   datastore, so there is no supported way to say a CVE is
   `component_not_present` for one image and not another.
2. **The justification map is partial and over-claiming.** Only
   `not-applicable-config` and `not-applicable-platform` carry a justification,
   and both map to `vulnerableCodeNotPresent` — true for a config-excluded
   source file, false for a feature still linked into the shipped binary.
3. **The internal vocabulary is narrower than VEX**, and cannot carry the
   evidence, trigger or provenance that make an exported assertion checkable.

So: keep the richer model in the ledger, generate VEX from it at export, and map
to a justification only where the recorded evidence supports that justification.
Emitting no justification is better than emitting a false one.

## The evidence ledger

One tracked, machine-readable record per disposition, reviewed as a diff.

```yaml
cve: CVE-0000-00000
component:
  recipe: <PN>
  cve_product: <CVE_PRODUCT>
  version: "<CVE_VERSION>"        # not PV, where they differ
  srcrev: "<SRCREV>"
  purl_or_cpe: "cpe:2.3:…"
products: [<image>, …]            # which products this record speaks for

observed_in:
  scan: <dated IMAGE_NAME stem>
  scanner_db: {<db>: <rev>, …, cutoff: <date>}
  cna_feed: {repo: <feed>, rev: <sha>, date: <date>}
  layer_pins_ref: buildhistory/metadata-revs@<sha>

axes:
  validity: valid                 # valid|wrong-product|withdrawn|unparseable-identity
  applicability: affected         # affected|fixed|code-absent|not-in-product|unverified
  reachability: unknown           # reachable|not-executable|dormant|unknown
  mitigation: []                  # each with the assertion that verifies it
  remediation: {decision: open, owner: <name>, due: <date>}

evidence:
  - kind: <build-object|packaging|version|runtime|source>
    claim: "<what this shows>"
    command: "<the command that produced it>"
    result: <present|absent|value>
affected_files: []
fix_commits: []
references: []

revalidate_when:                  # ALL must hold for the record to stay valid
  - {type: <trigger>, …}
provenance:
  analyst: <human>
  assisted_by: <tool:model>
  recorded: <date>
  # expires: present ONLY for judgement-bearing evidence — see below
```

Three properties earn the cost: a future scan **joins** on (CVE, component,
version) and reuses the disposition instead of re-deriving it; every claim
carries the command that produced it; and the record is **invalidated by
events** rather than trusted indefinitely.

### Revalidation triggers

| Trigger | Predicate | Evaluated against |
|---|---|---|
| `component_absent` | recipe has no installed package in image X | `pkgdata/runtime-reverse` + manifest/buildhistory |
| `version_at_or_below` / `version_at_least` | shipped version against a boundary | report `version` / image `.manifest` |
| `srcrev_equals` | source revision unchanged | recipe `SRCREV` |
| `config_disabled` | `# CONFIG_X is not set` | merged kernel `.config` |
| `packageconfig_off` | feature absent from `PACKAGECONFIG` | `bitbake-getvar` |
| `object_absent` / `object_present` | no object produced for a source file | the build tree |
| `cpe_identity_unchanged` | `CVE_PRODUCT`/`CVE_VERSION` unchanged | recipe metadata |
| `cna_record_digest` | the digest of the CVE record used as evidence is unchanged | the CVE feed entry at pull time |
| `runtime_assertion` | a named on-target check still passes | an assertion run |
| `layer_pin_unchanged` | OE-Core or BSP pin unchanged | `buildhistory/metadata-revs` |

**Scanner-database age is not a per-record trigger.** How fresh the scan is (S0)
and whether a disposition is still true are different questions. A conclusion
that the shipped version is past the fix boundary does not become false because
the database aged. Database and feed currency are checked **once per scan** and
stated with every count.

What belongs per-record is `cna_record_digest`: store the digest of the specific
CVE record the disposition was reasoned from, and fire when *that record*
changes — a new affected range, a corrected boundary, a rejection, a changed
file list. This is the precise form of the concern, and it catches what a pinned
database structurally cannot see.

**Expiry by evidence kind.** Not every record needs a clock:

- **Deterministic evidence** — identity, version boundaries, object presence,
  packaging, config symbols — is fully covered by the triggers above. **No hard
  expiry.** A date ceiling here generates review churn with no new information,
  which trains reviewers to rubber-stamp.
- **Judgement-bearing evidence** — reachability arguments, mitigation claims,
  and any "this symbol gates *the* vulnerable path" assertion — rests on a
  reading no predicate fully captures. **Keep the `expires:` ceiling**, and only
  here.

**Lifecycle:** `valid` → (a trigger fails, or a ceiling passes) → `stale` → the
finding **reopens as actionable** and the record is queued for re-review. Stale
must be loud.

### What the ledger is authoritative for

Project-authored dispositions only. It does not absorb the other two origins of
disposition data in a build.

| Origin | Ledger's role |
|---|---|
| **Upstream / OE metadata** — layer-shipped `CVE_STATUS`, OE-Core exclusion includes | **Consumed and audited.** The ledger records our *audit decision* — affirm, override or reject — and its evidence. It never restates an upstream claim as if we authored it |
| **Generated objective data** — tool-produced kernel exclusion includes | **Regenerated, never owned.** The ledger may cite an entry as evidence; it never mirrors, edits or supersedes the file |
| **Project-authored** — hand `CVE_STATUS`, product-scope and reachability findings | **Ledger-authoritative.** These records may **generate** `CVE_STATUS` projections, with the ledger id in the description |

Only project-authored records generate `CVE_STATUS`, and only from axes that
justify a scanner status. A stale record stops generating its line, which is
what makes suppression automatically reversible.

## Automation boundary

**Reliably automatable.** Scan-cohort and currency gating. Product-scope
projection through the package→recipe bridge. Fan-out collapsing, so one CVE
matched against many packages of one `CVE_PRODUCT` is one decision. Ledger
revalidation. Differential row diffing between scans against *predicted*
transitions, where any unpredicted transition is a finding. `CVE_STATUS` lint —
well-formed `cpe:` scope, detail keys within the status map, no duplication of
generated entries. Inventory of inherited suppressions by origin layer.
Kernel object-set derivation.

**Automate as proposal only, ratified by a human.** Version-boundary proposals
from CNA or advisory data. Kernel CNA re-derivation. Config-symbol lookup for a
named CVE — the lookup is mechanical, whether the symbol gates the vulnerable
path is not. Runtime-state capture as timestamped evidence attached to a
finding.

**Never automate into a status change.** Anything that turns *absence of
evidence* into a disposition. If an input can be empty for a reason unrelated to
the question being asked, the tool must fail loudly rather than conclude "not
applicable".

**Requires judgement, always.** Whether a same-name match is a different
codebase. Whether a config symbol gates *this* vulnerable path. Whether a
version boundary is establishable at all — deciding it is not, and leaving the
row open, is a judgement and often the right one. Whether a reachability
argument is sound or merely describes one boot. Whether a mitigation is
load-bearing. Risk acceptance and its review cadence. Remediation shape, given
blast radius, branch behaviour and release timing. Whether to inherit an
upstream suppression — each entry reviewed against *this* image's configuration
and threat model, never adopted wholesale to lower a count.

---

## Project adapter — rpi5-iot-gateway

**This section is the only per-repository part of this document.** Another
distro in this family replaces it and keeps everything above verbatim.

| Parameter | Value |
|---|---|
| Kernel recipe | `linux-iotgw-mainline-fit` (`CVE_PRODUCT = "linux_kernel"`, `CVE_VERSION = "${LINUX_VERSION}"`) |
| Machine | `raspberrypi5`, `aarch64` |
| Images | `iot-gw-image-{base,dev,prod,desktop}` |
| **The product** | `iot-gw-image-prod`. `-dev` is the engineering image: a finding present only there is in scope for `-dev` and out of scope for the product, and that distinction is an S2 answer, never a recipe `CVE_STATUS` |
| Vendor-branch semantics | **mainline-stable.** Fix boundaries are per stable branch; a fix reaching mainline is not a fix reaching ours. There is no vendor backport arithmetic to reason around |
| Scanner set | `sbom-cve-check` over the SPDX image graph, target scope only. No second scanner is wired, so vulnerabilities inside vendored dependencies of a recipe are a known, unmeasured blind spot |
| `CVE_STATUS` homes | per-recipe `.bbappend`; distro-wide `conf/distro/include/iotgw-cve-ignores.inc` (every entry `cpe:`-scoped) |
| Mitigation inventory | [SECURITY.md](SECURITY.md), [THREAT_MODEL.md](THREAT_MODEL.md); on-target assertions in `scripts/security/exposure-target.sh`, off-device reachability in `scripts/security/exposure-probe-host.sh` — a device cannot prove its own external reachability |
| Ledger and register | not yet created; until they exist, reachability, mitigation and risk-acceptance findings have no durable home and must not be forced into `CVE_STATUS` |

## See also

- [SBOM & CVE Scanning — Field Guide](SBOM_CVE.md) — the pipeline, the readers,
  userspace triage
- [Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md) — S4 for the kernel
- [Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md) — carrying a backport
