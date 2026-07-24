"""Fixture-based tests for cohort selection + same-build validation.

Synthetic deploy dirs only; no Yocto build required.
"""
import json
import os
import pathlib
import subprocess
import sys

# Make the hyphen-free shared module importable (the report scripts are
# hyphenated and can't be imported; done here rather than in a conftest.py to
# avoid a top-level `conftest` module clash with scripts/fit-signing/tests).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import cohort  # noqa: E402

SBOM_DIR = pathlib.Path(cohort.__file__).resolve().parent
LINK_STEM = "iot-gw-image-dev-raspberrypi5.rootfs"

_ROLE_SUFFIX = {
    "cve": cohort.CVE_JSON_SUFFIX,
    "aug_spdx": cohort.AUG_SPDX_SUFFIX,
    "base_spdx": cohort.BASE_SPDX_SUFFIX,
    "manifest": cohort.MANIFEST_SUFFIX,
    "testdata": cohort.TESTDATA_SUFFIX,
}


def make_build(d, buildid,
               roles=("cve", "aug_spdx", "base_spdx", "manifest", "testdata"),
               image_name=None):
    """Write a synthetic build cohort into dir `d`; return its stem."""
    stem = "%s-%s" % (LINK_STEM, buildid)
    for role in roles:
        p = d / (stem + _ROLE_SUFFIX[role])
        if role == "cve":
            p.write_text(json.dumps({"version": "1", "package": []}))
        elif role in ("aug_spdx", "base_spdx"):
            p.write_text(json.dumps({"@graph": []}))
        elif role == "manifest":
            p.write_text("some-pkg 1.0 aarch64\n")
        elif role == "testdata":
            name = stem if image_name is None else image_name
            p.write_text(json.dumps({"IMAGE_NAME": name}))
    return stem


def test_resolve_newest_returns_dated_not_symlink(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("cve",))
    dated = tmp_path / (stem + cohort.CVE_JSON_SUFFIX)
    link = tmp_path / (LINK_STEM + cohort.CVE_JSON_SUFFIX)
    os.symlink(dated.name, link)  # undated symlink -> dated file
    got = cohort.resolve_newest(str(tmp_path / ("*" + cohort.CVE_JSON_SUFFIX)))
    assert os.path.basename(got) == dated.name


def test_build_stem_strips_each_suffix():
    for suf in _ROLE_SUFFIX.values():
        assert cohort.build_stem("/x/" + LINK_STEM + "-20260724073419" + suf) == \
            LINK_STEM + "-20260724073419"


def test_companions_present_and_missing(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      roles=("cve", "manifest", "testdata"))
    comp = cohort.companions(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert comp["cve_json"] and comp["manifest"] and comp["testdata"]
    assert comp["aug_spdx"] is None and comp["base_spdx"] is None


def test_clean_cohort_has_no_warnings(tmp_path):
    stem = make_build(tmp_path, "20260724073419")
    assert cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX)) == []


def test_testdata_image_name_mismatch_warns(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      image_name="other-image.rootfs-20260101000000")
    warns = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("mismatched pairing" in w for w in warns)


def test_missing_companion_warns(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("cve",))
    warns = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("no manifest companion" in w for w in warns)
    assert any("no testdata companion" in w for w in warns)


def test_newer_image_warns(tmp_path):
    old = make_build(tmp_path, "20260722113844")
    make_build(tmp_path, "20260724073419")  # newer build present in same dir
    warns = cohort.check_cohort(tmp_path / (old + cohort.CVE_JSON_SUFFIX))
    assert any("newer image build 20260724073419" in w for w in warns)


def test_newer_image_of_other_variant_does_not_warn(tmp_path):
    dev = make_build(tmp_path, "20260722113844")
    # a newer build of a DIFFERENT image variant must not flag the dev scan
    prod = "iot-gw-image-prod-raspberrypi5.rootfs-20260724073419"
    (tmp_path / (prod + cohort.MANIFEST_SUFFIX)).write_text("x 1.0\n")
    warns = cohort.check_cohort(tmp_path / (dev + cohort.CVE_JSON_SUFFIX))
    assert not any("newer image build" in w for w in warns)


def test_strict_mode_exits_nonzero_on_stale_scan(tmp_path):
    old = make_build(tmp_path, "20260722113844")
    make_build(tmp_path, "20260724073419")  # newer image => stale selection
    cve = tmp_path / (old + cohort.CVE_JSON_SUFFIX)
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "--strict", "-i", str(cve)],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "WARNING" in r.stderr
