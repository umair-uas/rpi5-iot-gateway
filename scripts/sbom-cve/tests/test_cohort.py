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
    integrity, freshness = cohort.check_cohort(
        tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert integrity == [] and freshness == []


def test_testdata_image_name_mismatch_is_integrity(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      image_name="other-image.rootfs-20260101000000")
    integrity, _ = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("mismatched pairing" in w for w in integrity)


def test_testdata_empty_object_is_integrity(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      roles=("cve", "manifest"))
    (tmp_path / (stem + cohort.TESTDATA_SUFFIX)).write_text(json.dumps({}))
    integrity, _ = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("no usable IMAGE_NAME" in w for w in integrity)


def test_testdata_non_object_is_integrity_not_a_crash(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      roles=("cve", "manifest"))
    (tmp_path / (stem + cohort.TESTDATA_SUFFIX)).write_text(json.dumps([]))
    integrity, _ = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("no usable IMAGE_NAME" in w for w in integrity)


def test_testdata_empty_image_name_is_integrity(tmp_path):
    stem = make_build(tmp_path, "20260724073419",
                      roles=("cve", "manifest"))
    (tmp_path / (stem + cohort.TESTDATA_SUFFIX)).write_text(
        json.dumps({"IMAGE_NAME": ""}))
    integrity, _ = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("no usable IMAGE_NAME" in w for w in integrity)


def test_missing_companion_is_integrity(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("cve",))
    integrity, _ = cohort.check_cohort(tmp_path / (stem + cohort.CVE_JSON_SUFFIX))
    assert any("no manifest companion" in w for w in integrity)
    assert any("no testdata companion" in w for w in integrity)


def test_newer_image_is_freshness_not_integrity(tmp_path):
    old = make_build(tmp_path, "20260722113844")  # full, intact cohort
    make_build(tmp_path, "20260724073419")        # newer build present in dir
    integrity, freshness = cohort.check_cohort(
        tmp_path / (old + cohort.CVE_JSON_SUFFIX))
    assert integrity == []  # the older scan's own cohort is intact
    assert any("newer image build 20260724073419" in w for w in freshness)


def test_newer_image_of_other_variant_does_not_warn(tmp_path):
    dev = make_build(tmp_path, "20260722113844")
    # a newer build of a DIFFERENT image variant must not flag the dev scan
    prod = "iot-gw-image-prod-raspberrypi5.rootfs-20260724073419"
    (tmp_path / (prod + cohort.MANIFEST_SUFFIX)).write_text("x 1.0\n")
    _, freshness = cohort.check_cohort(tmp_path / (dev + cohort.CVE_JSON_SUFFIX))
    assert freshness == []


def test_resolve_newest_skips_dangling_symlink(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("cve",))
    dated = tmp_path / (stem + cohort.CVE_JSON_SUFFIX)
    stale = tmp_path / (LINK_STEM + cohort.CVE_JSON_SUFFIX)
    os.symlink("gone" + cohort.CVE_JSON_SUFFIX, stale)  # dangling symlink
    got = cohort.resolve_newest(str(tmp_path / ("*" + cohort.CVE_JSON_SUFFIX)))
    assert os.path.basename(got) == dated.name  # dangling link skipped, no crash


def test_resolve_newest_tie_is_deterministic(tmp_path):
    a = tmp_path / (LINK_STEM + "-20260724070000" + cohort.CVE_JSON_SUFFIX)
    b = tmp_path / (LINK_STEM + "-20260724080000" + cohort.CVE_JSON_SUFFIX)
    a.write_text("{}")
    b.write_text("{}")
    os.utime(a, (1000, 1000))
    os.utime(b, (1000, 1000))  # identical mtime -> tie broken by path
    got = cohort.resolve_newest(str(tmp_path / ("*" + cohort.CVE_JSON_SUFFIX)))
    assert os.path.basename(got) == b.name  # greater path wins, stably


def test_cve_reader_strict_tolerates_stale_but_intact(tmp_path):
    old = make_build(tmp_path, "20260722113844")  # full cohort
    make_build(tmp_path, "20260724073419")        # newer image present
    cve = tmp_path / (old + cohort.CVE_JSON_SUFFIX)
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "--strict", "-i", str(cve)],
        capture_output=True, text=True)
    assert r.returncode == 0                    # freshness-only: not a failure
    assert "newer image build" in r.stderr      # but still warned


def test_cve_reader_require_latest_fails_on_newer_image(tmp_path):
    old = make_build(tmp_path, "20260722113844")
    make_build(tmp_path, "20260724073419")
    cve = tmp_path / (old + cohort.CVE_JSON_SUFFIX)
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"),
         "--require-latest", "-i", str(cve)],
        capture_output=True, text=True)
    assert r.returncode != 0


def test_cve_reader_strict_fails_on_missing_companion(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("cve",))  # no companions
    cve = tmp_path / (stem + cohort.CVE_JSON_SUFFIX)
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "--strict", "-i", str(cve)],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "WARNING" in r.stderr


def test_sbom_reader_strict_fails_on_missing_companion(tmp_path):
    stem = make_build(tmp_path, "20260724073419", roles=("aug_spdx",))
    spdx = tmp_path / (stem + cohort.AUG_SPDX_SUFFIX)
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "sbom-report.py"), "--strict", "-i", str(spdx)],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "WARNING" in r.stderr
