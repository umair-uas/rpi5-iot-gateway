#!/usr/bin/env python3
"""
Shared cohort helpers for the sbom-cve report readers (cve-report.py,
sbom-report.py).

Yocto writes every image output with the same IMAGE_NAME stem, e.g.
  iot-gw-image-dev-raspberrypi5.rootfs-20260724073419
plus an un-dated *.rootfs.* symlink to the newest one. Provenance itself is
sound (testdata.IMAGE_NAME == SpdxDocument.name == the filename stem, and
buildhistory/DB pins record the rest); the only defect is that the readers
auto-locate the *newest* match, which resolves to the un-dated symlink and hides
which build was read. These helpers make the readers (a) resolve the newest
DATED report, and (b) confirm the selected scan and its companion image
artifacts belong to one — and the newest — build, catching the case where an
image was rebuilt but the scan was not re-run.

Read-only, stdlib-only; produces no build state. Note: testdata.json can carry
secrets, so only its IMAGE_NAME is ever read and it is never printed or copied.
"""

import glob
import json
import os
import re
import sys

# Cohort member suffixes on the shared IMAGE_NAME stem. Ordered longest-first so
# build_stem() strips the most specific one (the augmented SPDX also ends in
# ".spdx.json").
CVE_JSON_SUFFIX = ".sbom-cve-check.yocto.json"
AUG_SPDX_SUFFIX = ".sbom-cve-check.spdx.json"
BASE_SPDX_SUFFIX = ".spdx.json"
MANIFEST_SUFFIX = ".manifest"
TESTDATA_SUFFIX = ".testdata.json"
_STEM_SUFFIXES = sorted(
    (CVE_JSON_SUFFIX, AUG_SPDX_SUFFIX, BASE_SPDX_SUFFIX,
     MANIFEST_SUFFIX, TESTDATA_SUFFIX),
    key=len, reverse=True,
)

# The 14-digit BUILDNAME (a sortable datetime stamp) trailing an IMAGE_NAME stem.
_BUILDID_RE = re.compile(r"-(\d{14})$")


def die(msg):
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(1)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        die("input not found: %s" % path)
    except json.JSONDecodeError as e:
        die("malformed JSON in %s: %s" % (path, e))


def resolve_newest(deploy_glob):
    """Newest DATED report matching deploy_glob.

    Resolves symlinks and dedupes by real path so the un-dated *.rootfs.* symlink
    and its dated target do not tie on mtime — the result is always the real
    dated file.
    """
    reals = {os.path.realpath(h) for h in glob.glob(deploy_glob)}
    reals = {p for p in reals if os.path.exists(p)}  # drop dangling symlinks
    if not reals:
        die("no readable files match %s under the deploy tree. "
            "Pass -i explicitly or build an image first." % deploy_glob)
    # (mtime, path) so an mtime tie is broken deterministically by path rather
    # than by hash-seeded set iteration order.
    return max(reals, key=lambda p: (os.path.getmtime(p), p))


def build_stem(path):
    """The IMAGE_NAME stem of a deploy artifact (its cohort suffix stripped)."""
    name = os.path.basename(os.path.realpath(path))
    for suf in _STEM_SUFFIXES:
        if name.endswith(suf):
            return name[:-len(suf)]
    return name


def _build_id(stem):
    """The trailing 14-digit BUILDNAME of a stem, or None."""
    m = _BUILDID_RE.search(stem or "")
    return m.group(1) if m else None


def companions(report_path):
    """Map cohort role -> same-stem sibling path (None if absent)."""
    real = os.path.realpath(report_path)
    d = os.path.dirname(real)
    stem = build_stem(real)
    roles = {
        "manifest": MANIFEST_SUFFIX,
        "testdata": TESTDATA_SUFFIX,
        "base_spdx": BASE_SPDX_SUFFIX,
        "aug_spdx": AUG_SPDX_SUFFIX,
        "cve_json": CVE_JSON_SUFFIX,
    }
    out = {}
    for role, suf in roles.items():
        cand = os.path.join(d, stem + suf)
        out[role] = cand if os.path.exists(cand) else None
    return out


def _newer_build_id(stem, deploy_dir):
    """Newest same-image dated-manifest BUILDNAME strictly newer than `stem`'s.

    Restricted to the same image-link prefix so a newer build of a *different*
    image variant does not falsely flag this scan.
    """
    sel = _build_id(stem)
    if not sel:
        return None
    link = _BUILDID_RE.sub("", stem)  # image-link stem, timestamp removed
    ids = []
    for h in glob.glob(os.path.join(deploy_dir, link + "-*" + MANIFEST_SUFFIX)):
        bid = _build_id(build_stem(os.path.realpath(h)))
        if bid:
            ids.append(bid)
    newest = max(ids) if ids else None
    return newest if (newest and newest > sel) else None


def check_cohort(report_path):
    """Classify same-build issues for the selected report.

    Returns (integrity, freshness):

    - integrity: the selected scan's OWN cohort is broken — a required
      .manifest/.testdata.json companion is missing (the scan is a copy, or the
      image outputs were pruned), or testdata IMAGE_NAME disagrees with the stem
      (mismatched pairing). These are validation failures.
    - freshness: a newer image build exists than the selected scan. This is a
      staleness heads-up, not corruption — an explicitly chosen older build is
      legitimate, so it does not fail --strict (see --require-latest).

    Empty lists == a consistent, newest cohort.
    """
    integrity, freshness = [], []
    real = os.path.realpath(report_path)
    stem = build_stem(real)
    comp = companions(real)

    for role in ("manifest", "testdata"):
        if comp[role] is None:
            integrity.append(
                "no %s companion for %s (scan may be a copy, or the image "
                "outputs were pruned)" % (role, stem))

    if comp["testdata"]:
        image_name = None
        try:
            with open(comp["testdata"]) as f:
                testdata = json.load(f)
        except (OSError, ValueError):
            integrity.append("could not read testdata companion for %s" % stem)
        else:
            if isinstance(testdata, dict):
                image_name = testdata.get("IMAGE_NAME")
            if not (isinstance(image_name, str) and image_name):
                integrity.append(
                    "testdata companion for %s has no usable IMAGE_NAME "
                    "(cannot confirm pairing)" % stem)
            elif image_name != stem:
                integrity.append(
                    "testdata IMAGE_NAME %r != selected scan stem %r "
                    "(mismatched pairing)" % (image_name, stem))

    newer = _newer_build_id(stem, os.path.dirname(real))
    if newer:
        freshness.append(
            "a newer image build %s exists than the selected scan %s "
            "(re-run `make sbom-cve` for the latest, or select deliberately "
            "with -i)" % (newer, _build_id(stem)))

    return integrity, freshness


def report_provenance(path, strict, require_latest, label):
    """Print the resolved dated provenance line + any same-build warnings.

    Returns the real (dated) path. Exits non-zero when --strict and the cohort
    has integrity issues, or when --require-latest and a newer build exists.
    A stale-but-intact scan chosen with -i is not an error under --strict alone.
    """
    real = os.path.realpath(path)
    print("# %s: %s" % (label, os.path.basename(real)))
    integrity, freshness = check_cohort(real)
    for w in integrity + freshness:
        print("# WARNING: %s" % w, file=sys.stderr)
    reasons = []
    if strict and integrity:
        reasons.append("%d integrity" % len(integrity))
    if require_latest and freshness:
        reasons.append("%d freshness" % len(freshness))
    if reasons:
        die("cohort validation failed (%s issue(s))" % ", ".join(reasons))
    return real
