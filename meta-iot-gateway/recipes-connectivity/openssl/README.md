# openssl 3.5.7 — temporary version override

## Why this recipe is here

OE-Core is pinned at the `yocto-6.0` tag, which ships **openssl 3.5.6**. That
version is affected by 15 CVEs, all of which share a single fix boundary:
**3.5.7**. Among them one CRITICAL (CVSS 9.1) and eight HIGH.

Upstream OE-Core already moved: the `wrynose` branch carries
`openssl_3.5.7.bb`, added by a single commit
(`530fb9ea9ba openssl: upgrade 3.5.6 -> 3.5.7`). Our pin simply predates it.

Moving the whole OE-Core pin to `wrynose` HEAD was considered and rejected —
281 commits, with toolchain and libc movement, is a release-train decision and
not something to do while chasing one package. Taking openssl alone is a point
release inside the same ABI series, so this layer carries the upstream recipe
verbatim until the pin catches up.

## Evidence

The "fixed in 3.5.7" claim was **not** taken from the CVE scanner that produced
the finding. Each CVE's fix commits were checked for membership in the
`openssl-3.5.6..openssl-3.5.7` range via git ancestry:

    gh api repos/openssl/openssl/compare/openssl-3.5.6...openssl-3.5.7 \
      --jq '.commits[].sha'

159 commits in that range; all 15 CVEs have fix commits inside it, and
therefore demonstrably absent from 3.5.6. Full command log and per-CVE results
live with the CVE triage records.

Deliberately **not** taken: 3.6.x. It is the current feature series, no CVE in
this set requires it, and adopting it would put this layer permanently ahead of
OE-Core rather than temporarily.

## These files are verbatim upstream copies

Every file here is byte-identical to
`meta/recipes-connectivity/openssl/` on OE-Core's `wrynose` branch. Keep it that
way — the point is that a diff against upstream stays empty, so the override is
obviously inert rather than a fork. Project-specific changes belong in a
`.bbappend`, never edited into these files.

Verify with:

    for f in $(cd meta-iot-gateway/recipes-connectivity/openssl && find . -type f ! -name README.md | sed 's|^\./||'); do
      diff <(git -C .kas/openembedded-core show \
               "origin/wrynose:meta/recipes-connectivity/openssl/$f") \
           "meta-iot-gateway/recipes-connectivity/openssl/$f" > /dev/null \
        && echo "OK   $f" || echo "DIFF $f"
    done

## DELETE THIS DIRECTORY WHEN

The OE-Core pin in `rpi5.yml` moves to a revision whose openssl is **3.5.7 or
newer**. At that point this copy is redundant, and if the pinned version is
exactly 3.5.7 there would be two recipes providing the same version — an
ambiguity bitbake should not have to resolve.

Check with:

    git -C .kas/openembedded-core ls-tree --name-only HEAD \
      meta/recipes-connectivity/openssl/ | grep '\.bb$'

## How version selection works here

No `PREFERRED_VERSION` is set. BitBake selects the highest available version
across layers, so 3.5.7 (here) wins over 3.5.6 (OE-Core) regardless of
`BBFILE_PRIORITY`. Confirm before trusting it:

    . scripts/env.sh && kas shell kas/local.yml \
      -c "bitbake-getvar -q -r openssl --value PV"
