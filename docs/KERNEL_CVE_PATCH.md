# Kernel CVE Patch — Field Guide

How to turn a Linux kernel CVE into a backport patch carried in this
Yocto layer, when the upstream fix isn't yet in your pinned `SRCREV`.

**Worked example (illustrative):** CVE-2026-31431 (`crypto: algif_aead`
write-to-page-cache, CISA KEV), stable backport `fafe0fa2` for `linux-6.18.y`,
applied against an example pin of `v6.18.13`. The commands and workflow are
real; the specific CVE, SRCREV, and the `0011-…` patch are a teaching example,
not shipped in the tree. Substitute the current pin (see
`linux-iotgw-mainline-common.inc`) and your actual CVE.

---

## When to use this approach

| Situation | Use |
|-----------|-----|
| CVE is fixed in a stable release past your `SRCREV` but you can't bump the kernel right now | **This guide** |
| You can bump `SRCREV_machine` forward to a release that includes the fix | Bump and drop any open backport patches for that CVE |
| The CVE is not yet patched upstream (no commit to backport) | Hold; track the kernel mailing list — out of scope here |
| Userspace CVE (openssl, glibc, etc.) | Bump the recipe `PV`/`SRCREV` or carry a `.bbappend` patch — same mechanics, different recipe |

For the scanning and triage that *finds* applicable CVEs, see
[SBOM & CVE Scanning](SBOM_CVE.md) (`make sbom-cve`, `make cve-report`). This
field guide is what you do **after** triage has established that a CVE applies
to your pin and you have decided to carry a fix.

> **Era note — read before following the steps below.** This guide was written
> against scarthgap, where OE-Core's `cve-check` was the tool and CVE work was
> done by hand. The wrynose migration replaced that flow wholesale with
> `sbom-cve-check` over the SPDX 3.0 image SBOM, and `cve-check` is no longer
> inherited anywhere in this repo. Two consequences:
>
> - **Steps 2 and 3 have been retracted in place.** They described the manual
>   identification method of that era; parts of it are now known to give wrong
>   answers. The retractions say what replaced them.
> - **The decision framework and the patch mechanics (§§4–8) are unaffected**
>   by the tooling change and remain current — they are about carrying a commit
>   into a recipe, which wrynose did not alter.

### Patch vs `SRCREV` bump — picking between them

When the fix has landed in a stable release **and** your branch tip is
ahead of that release, you have two valid options. They aren't
equivalent — pick deliberately:

| Factor | Carry a backport patch | Bump `SRCREV_machine` to a release containing the fix |
|---|---|---|
| Blast radius | One commit, one file, byte-clean revert | Hundreds of commits across the kernel — every stable backport since your pin |
| Verification effort | Targeted: `do_patch` clean + smoke test the affected subsystem | Broader smoke pass: boot, all live subsystems, regression watch over time |
| Time to remediation | Hours | Days (validation, regression triage) |
| Maintenance | Technical debt — must be dropped on next bump | None once landed |
| Other CVEs / regressions in the window | Not addressed | Picked up "for free" |
| Reproducibility of the in-flight release | Preserved (same kernel as last validated state) | Changed (now a different validated state) |

**Use the patch path when:**
- There's a hard deadline (CISA KEV `cisaActionDue`, customer SLA).
- You just shipped a release on the current `SRCREV` and don't want to
  invalidate its validation envelope.
- The vulnerable subsystem is narrow and easy to smoke-test in isolation.

**Use the `SRCREV` bump path when:**
- You're between releases (no in-flight validation to preserve).
- The gap between your pin and stable tip is large enough that you're
  almost certainly missing other security fixes.
- You have time for a broader smoke pass.

**Use both, in sequence**, when both apply:
1. Ship the carry-patch immediately for fast remediation.
2. Open a follow-up issue to bump `SRCREV_machine` to (or past) the
   stable release that contains the upstream fix, dropping the carry
   patch in the same commit.

The CVE-2026-31431 work in this repo took option (1) under CISA-KEV
pressure with the v0.4.0 release fresh, and queued a follow-up for the
6.18.13 → current-tip bump. Both moves are valid; the failure mode is
treating the carry-patch as permanent.

---

## 1. Pin down what you're patching

Before touching anything, two facts:

```bash
# (a) Kernel branch and pinned commit in the layer
grep -rE "BRANCH|SRCREV_machine|LINUX_VERSION" meta-iot-gateway/recipes-kernel/linux/

# (b) What's actually running on the device
ssh iotgw "uname -r"
```

For our example: `linux-6.18.y`, `SRCREV_machine = 25e0b1c2…` (= `v6.18.13`).

## 2. Read the CVE record as JSON, not prose

The instinct is right and still stands. The **source** has changed.

> **Retracted: NVD as the version-range oracle.** This step previously read
> `configurations[].nodes[].cpeMatch[]` from the NVD REST API to learn "which
> release closes it", and reported a single range like `6.13 ≤ x < 6.18.22`.
> For kernel CVEs, NVD flattens every stable branch into one crude span and
> hides the per-branch boundaries that actually decide whether *your* pin is
> affected. A record can present as "6.6.48 up to excluding 6.19.4" while the
> real fix boundaries are 6.12.101 and 6.18.42 on their respective branches —
> a pin sitting between them is scored wrong in either direction depending on
> which number you read.
>
> **The kernel CNA record, not NVD, carries per-branch fix boundaries.**
> Establishing whether your pin is affected, and which release closes it, is
> the applicability question and is answered before you reach this guide — see
> [Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md). Do not re-derive it
> here from a flattened range.

What this step is still good for, and why you are here: the CVE record lists
the **fix commit SHAs**, one mainline plus N stable backports, as
`git.kernel.org/stable/c/<sha>` reference URLs. Read them from the CVE record
in the shared CVE-data clone rather than fetching over the network. Which of
those SHAs is *yours* is step 3.

## 3. Identify which backport is for your branch

The stable backports for one CVE all carry the same `Subject:` and an
`[ Upstream commit <sha> ]` trailer — you can't tell them apart from the
patch headers alone. This part is unchanged and is the reason the step exists.

> **Retracted: identifying the branch by grepping a cgit file log.** This step
> previously fetched
> `.../log/<file>?h=linux-6.18.y` and treated a SHA appearing in both that log
> and the CVE references as "your backport". Do not rely on it. A closely
> related cgit URL form carrying `?h=<branch>` was found **not to filter by
> branch at all**, which produced several confidently wrong "already fixed"
> conclusions before it was caught. Whether the `/log/` endpoint shares that
> defect has not been established — which is precisely why it should not be
> the basis of a security decision.
>
> **Require ancestry proof instead.** The question is not "does this SHA appear
> in a listing" but "is this commit an ancestor of my branch". Ask git that
> directly. The bitbake download mirror already holds the stable tree, so this
> is offline and authoritative:
>
> **Resolve `DL_DIR` from the build configuration, never from your shell.** An
> ambient `$DL_DIR` may be a leftover export pointing at a mirror this project
> no longer uses — on this host it has pointed at an abandoned clone stopping
> at a release *older than the current pin*. Derive it, print it, and print the
> branch tip before making any claim:
>
> `DL_DIR` is a **bitbake** variable set in `kas/local.yml`, not a shell
> variable. Ask the build for it:
>
> ```bash
> . scripts/env.sh && kas shell kas/local.yml -c 'bitbake -e | grep "^DL_DIR"'
> # => DL_DIR="/path/to/DL_SHARED"
>
> M="<that path>/git2/git.kernel.org.pub.scm.linux.kernel.git.stable.linux.git"
> git -C "$M" log -1 --format='tip: %h %ci %s' refs/heads/<branch>
> ```
>
> Sourcing `scripts/env.sh` is not optional outside an interactive shell.
> Interactive shells pick it up via direnv; **agent tool-shells and CI do not**,
> and a bare `kas shell` without it re-clones the whole layer stack into the
> repo root (`AGENTS.md`).
>
> Then ask git the ancestry question:
>
> ```bash
> git -C "$M" merge-base --is-ancestor <sha> refs/heads/<branch> 2>/dev/null
> case $? in
>   0) echo "ON branch" ;;
>   1) echo "NOT on branch" ;;
>   *) echo "INCONCLUSIVE: commit not in this clone — refetch before concluding" ;;
> esac
> ```
>
> **Test all three exit codes, never `&& … || …`.** `--is-ancestor` returns 0
> for yes and 1 for no, but **128 when the commit is not in the clone at all** —
> and a two-branch idiom collapses 128 into the "no" arm. That turns "I have not
> fetched this commit" into "this commit is not on your branch", which is a
> confident false negative and the same shape of error as the retracted method
> above.
>
> This is not hypothetical. A download mirror is only as fresh as its last
> fetch, which tracks your *pinned* `SRCREV` — so the fix commit you are
> researching, being newer than your pin by definition, is exactly the commit
> most likely to be missing. Verified on this repo's mirror: its `linux-6.18.y`
> tip was `v6.18.38` while the commits under investigation landed in `v6.18.42`,
> so both were absent and the naive idiom reported them as "not on branch".
> Confirm the mirror actually reaches past your target before trusting a
> negative:
>
> ```bash
> git -C "$M" log -1 --format='%h %ci %s' refs/heads/<branch>   # how fresh is it?
> ```
>
> **`git.kernel.org` may be unreachable** for a top-up fetch. Its cgit interface
> has served a bot-protection interstitial rather than content to both `curl`
> and automated fetchers, and fetching a single SHA from the combined stable
> tree can time out against a repository that large. A maintained mirror answers
> the same ancestry question over HTTP — a `compare` of `<sha>` against the
> branch returns `ahead` when the SHA is an ancestor of the branch tip and
> `diverged` when it is not on that branch's linear history. The commit that is
> on *no* stable branch is the mainline original.

> If you don't know the affected file, take any one of the backport commits and
> read its diff headers — they tell you which files changed.

### Is your fix self-contained?

Ask this **before** fetching anything. A stable backport is often one commit in
a short series, and the CVE is tagged on the last one. Applying it alone can be
worse than not applying it: if the earlier commits made individual code paths
safe so the final commit could remove a lock that was covering for them, then
landing only the final commit removes the lock without the safety — reopening
the race under the appearance of a fix.

The commit message usually admits it, in words like *"previous patches made it
safe to … so <lock> is no longer required"*. Treat that phrasing as a stop
sign, and confirm by reading the commit's actual parent chain rather than
inferring from subject lines.

If the fix has prerequisites, all of them land together, in upstream order, or
none do. This is also the case where a `SRCREV` bump is usually the better
instrument — it absorbs the whole series atomically and the ordering risk
disappears. See the bump-vs-patch table above.

## 4. Fetch the patch in `git format-patch` form

**Take it from the mirror you just verified, not over the network.** Step 3
already proved the commit is present and on your branch in the local clone, so
generating the mail there is offline, deterministic, and immune to the
`git.kernel.org` availability problem described above:

```bash
git -C "$M" format-patch -1 --stdout <sha> > /tmp/fix.patch
```

**If the commit is not in any local clone, you do not yet have the right to
import it.** Absence is exactly the `INCONCLUSIVE` case from step 3 — it means
the ancestry check could *not* establish that this SHA is your branch's
backport. Downloading the patch at that point imports a commit whose branch
identity is unproven, which is the failure step 3 exists to prevent.

Re-establish branch identity first, by one of:

- **fetch the commit into the mirror** and re-run the step 3 ancestry check —
  preferred, since it restores the offline, authoritative answer;
- **prove it against a maintained mirror**, where a `compare` of `<sha>`
  against your branch returns `ahead` (ancestor) rather than `diverged`.

Only once the branch is established, and only if the object still isn't local,
fall back to cgit's `/patch/` endpoint — and expect it to fail closed rather
than serve content:

```bash
curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/patch/?id=<sha>" \
  > /tmp/fix.patch
```

Either way the result is exactly what Yocto's `do_patch` (git am / Quilt)
expects.
**Do not post-process the diff** — leave it byte-identical to upstream.
Hand-editing the hunks is a sign you grabbed the wrong backport.

## 5. Annotate for Yocto QA

`oe-core` requires two lines for `cve-check.bbclass` and the patch-status
QA to recognise the patch:

```
Upstream-Status: Backport [https://git.kernel.org/.../?id=<sha>]
CVE: CVE-XXXX-XXXXX
```

Place them **above** the `---` diff separator (so `git am` doesn't choke).
Easiest is an awk one-liner:

```bash
awk 'BEGIN{a=0} /^---$/ && !a {
       print "Upstream-Status: Backport [https://git.kernel.org/.../?id=<sha>]"
       print "CVE: CVE-XXXX-XXXXX"
       print ""
       print; a=1; next
     } {print}' /tmp/fix.patch \
  > meta-iot-gateway/recipes-kernel/linux/files/0011-CVE-2026-31431-...patch
```

Valid `Upstream-Status:` values: `Backport`, `Pending`, `Inappropriate`,
`Submitted`, `Denied`, `Inactive-Upstream`. For a stable backport, always
**`Backport`** with the URL of the cherry-pick commit.

## 6. Wire it into the recipe

The `linux-iotgw-mainline-fit` provider consumes patches via the shared
`linux-iotgw-mainline-common.inc`. Add the patch there once:

```bitbake
# Security: CVE-2026-31431 (algif_aead in-place write-to-page-cache; CISA KEV).
# Stable 6.18.y backport (fafe0fa2) lands in 6.18.22; we pin 6.18.13 so apply
# the patch directly. Drop this line on the next SRCREV bump past v6.18.22.
SRC_URI:append = " file://0011-CVE-2026-31431-crypto-algif_aead-revert-to-out-of-place.patch"
```

Unconditional — security patches don't go behind feature flags. Even if
the vulnerable kconfig is off in today's image (e.g. our
`# CONFIG_CRYPTO_USER_API_AEAD is not set`), patching the source means a
developer who flips the kconfig on later picks up the fixed code.

The inline `# Drop on next SRCREV bump past vX.Y.Z` note prevents the
patch from ossifying after the next kernel update.

## 7. Verify the patch applies

Follow the repo's progressive validation model (`AGENTS.md` §"Working
economically"): cheapest check first, and **never a bare `bitbake`** — a raw
kas/bitbake call outside `make` re-clones the layer stack into the repo root
unless the environment is sourced in the same command.

```bash
# 1. Parse-level sanity — cheapest, catches SRC_URI/FILESEXTRAPATHS mistakes
make parse

# 2. Re-run just do_patch for the kernel recipe
. scripts/env.sh && kas shell kas/local.yml \
  -c "bitbake linux-iotgw-mainline-fit -c patch -f"

grep -E "Applying patch|FAILED|Hunk" \
  build/tmp/work/*-poky-linux/linux-iotgw-mainline*/*/temp/log.do_patch
```

If `do_patch` misbehaves in a way that looks like stale state, use
`-c clean` first — it drops WORKDIR and any poisoned pseudo DB while leaving
sstate intact, so the rebuild usually restores from cache. Reach for
`-c cleansstate` only if that fails: on a kernel it forces a full recompile
(`.claude/rules/yocto-patterns.md`).

A clean `Applying patch 0011-...` with **no** `FAILED` / `Hunk` lines
proves the diff matched your tree exactly.

Belt-and-suspenders after a full build — grep the patched source for a
string unique to the fix:

```bash
grep -l "operating out-of-place" \
  build/tmp/work/*-poky-linux/linux-iotgw-mainline*/*/git/crypto/algif_aead.c
```

For CVE-2026-31431 specifically, the AEAD path isn't compiled into our
production kernel (`# CONFIG_CRYPTO_USER_API_AEAD is not set`), so no
runtime test exercises it on the default config. See the [Security
guide](SECURITY.md) for the live crypto surface (`dm-crypt`,
TPM/openssl, RAUC bundle decrypt) — none of those touch `algif_aead`.

## 8. Track the sunset

Every backport patch is technical debt. Track it in three places:

1. **Inline recipe comment** — *"drop on next SRCREV bump past vX.Y.Z"*.
2. **Patch filename** — prefix with `CVE-<id>` so a `git grep CVE-`
   surfaces all of them.
3. **CHANGELOG** — note the CVE under "Security" for the next release.

When you bump `SRCREV_machine`, sanity-check:

```bash
# Does the new SRCREV already contain the upstream fix?
# $M is the mirror resolved in step 3 — never a shell $DL_DIR.
git -C "$M" log <old_SRCREV>..<new_SRCREV> -- <affected-file>
```

Here `<old>..<new>` is the right question — "what did the bump pick up" — and
seeing the cherry-pick means the new pin **has** the fix. That is the opposite
sense from asking whether your *current* pin contains a commit; for that, use
the ancestry test from step 3.

If you see the cherry-pick in the log, delete the patch file and the
`SRC_URI:append` line in the same commit as the bump.

---

## Anti-patterns

- **Don't hand-edit the diff** to force hunks to apply. If a hunk fails,
  you grabbed the wrong backport — redo step 3.
- **Don't gate security patches behind feature flags.** Even if the
  vulnerable kconfig is off today, ship the patched source.
- **Don't skip `Upstream-Status:`.** It looks pedantic, but the
  `patch-status` QA gate fails the build without it.
- **Make the patch declare its own CVE.** Name the file `CVE-<id>.patch` **and**
  put a `CVE: CVE-<id>` line in the header. The SPDX/VEX side reads the CVE id
  from the filename or that header only — a patch that carries the id solely in
  its `Subject:` line is credited to nothing, and the CVE keeps reporting as
  unpatched even though the fix ships.
- **Don't combine multiple CVEs into one patch.** The "drop when SRCREV
  passes vX.Y.Z" tracking only works if each patch closes exactly one CVE.
- **Put the patch in the shared include.** Put the
  `SRC_URI:append` in `linux-iotgw-mainline-common.inc`, not in the
  provider `.bb`.

## Cheat-sheet

| Task | Command |
|---|---|
| What CVEs affect me? | `make sbom-cve` then `make cve-report` — see [SBOM & CVE Scanning](SBOM_CVE.md) |
| Is the fix in my `SRCREV`? | `git merge-base --is-ancestor <fix-sha> <SRCREV>` — exit 0 = the fix **is** in your pin. Do **not** use `git log <SRCREV>..`: that lists commits *after* the pin, so seeing the fix there means you are **not** patched |
| Which stable branch a SHA is on | `git merge-base --is-ancestor <sha> refs/heads/<branch>` — ancestry, not a log listing. Exit 0 yes / 1 no / **128 commit absent**; check the mirror's freshness before believing a "no" |
| Raw patch in `git am` form | `git -C "$M" format-patch -1 --stdout <sha>` from the verified local mirror. The kernel.org `/patch/?id=<sha>` URL is a **fallback only**, valid after branch identity is re-established (step 4) |
| Mailing-list context | `oss-security` archive URLs in the NVD references — usually best for PoC links and disclosure timeline |

---

## See also

- [Kernel CVE Applicability](KERNEL_CVE_APPLICABILITY.md) — the stage before this one: whether the CVE applies to your pin at all, the build-object oracle, CNA re-derivation
- [CVE Applicability — Decision Model](CVE_APPLICABILITY.md) — the generic stage model and what may suppress a finding
- [Security guide](SECURITY.md) — distribution-wide security posture, KSPP alignment, audit framework
- [Kernel driver backport — field guide](KERNEL_DRIVER_BACKPORT.md) — sibling guide for backporting *drivers* (not CVE fixes) into the mainline kernel recipe
- [Operations guide](OPERATIONS.md) — runbook for rolling a security fix to fleet (build → bundle → RAUC OTA → verify)
