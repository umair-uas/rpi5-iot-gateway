"""Fixture-based tests for kernel-cve-normalize.py.

Exercises the actual CLI (subprocess), not just the internal functions, so
exit-code and "fails loudly" behaviour is verified the same way an operator
would see it. Synthetic report fixtures only; no Yocto build required.
"""
import hashlib
import json
import pathlib
import subprocess
import sys

SBOM_DIR = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = SBOM_DIR / "kernel-cve-normalize.py"

PKG_NAME = "linux-iotgw-mainline-fit"

# The real Yocto AUTOREV/git PV that crashes
# packaging.version.Version(pkg["version"].split("-")[0]) in OE-Core's
# improve_kernel_cve_report.py — the regression case this tool exists for.
REAL_DIRTY_PV = "6.18.37+gitAUTOINC+0c503cf3dd_307ef96123"


def make_report(version=REAL_DIRTY_PV, cpes=None, pkg_name=PKG_NAME):
    if cpes is None:
        cpes = ["cpe:2.3:*:*:linux_kernel:6.18.37:*:*:*:*:*:*:*"]
    return {
        "version": "1",
        "package": [
            {
                "name": pkg_name,
                "layer": "meta-iot-gateway",
                "version": version,
                "products": [
                    {"product": "linux_kernel", "cvesInRecord": "Yes"}
                ],
                "issue": [
                    {"id": "CVE-2024-12345", "status": "Patched",
                     "detail": "fixed-version"}
                ],
                "cpes": cpes,
            },
            {
                "name": "some-other-recipe",
                "version": "1.2.3",
                "products": [{"product": "some-other", "cvesInRecord": "No"}],
                "issue": [],
                "cpes": ["cpe:2.3:*:*:some-other:1.2.3:*:*:*:*:*:*:*"],
            },
        ],
    }


def run(args):
    return subprocess.run(
        [sys.executable, str(SCRIPT)] + args,
        cwd=str(SBOM_DIR),
        capture_output=True, text=True,
    )


def write_report(tmp_path, report, name="old-cve-report.json"):
    p = tmp_path / name
    p.write_text(json.dumps(report, indent=2))
    return p


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def test_real_dirty_pv_normalizes_to_clean_cpe_version(tmp_path):
    report_path = write_report(tmp_path, make_report())
    out_path = tmp_path / "normalized.json"
    before = sha256(report_path)

    result = run(["-i", str(report_path), "-o", str(out_path)])

    assert result.returncode == 0, result.stderr
    assert sha256(report_path) == before, "input report was modified"

    out = json.loads(out_path.read_text())
    kernel_pkg = next(p for p in out["package"] if p["name"] == PKG_NAME)
    assert kernel_pkg["version"] == "6.18.37"
    # Untouched fields: issue list and the sibling package are carried
    # through unchanged.
    assert kernel_pkg["issue"] == make_report()["package"][0]["issue"]
    other_pkg = next(p for p in out["package"] if p["name"] == "some-other-recipe")
    assert other_pkg == make_report()["package"][1]


def test_expect_version_match_succeeds(tmp_path):
    report_path = write_report(tmp_path, make_report())
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path),
                  "--expect-version", "6.18.37"])

    assert result.returncode == 0, result.stderr


def test_expect_version_mismatch_fails_loudly(tmp_path):
    report_path = write_report(tmp_path, make_report())
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path),
                  "--expect-version", "6.18.42"])

    assert result.returncode != 0
    assert "disagrees" in result.stderr
    assert not out_path.exists()


def test_ambiguous_multiple_cpe_versions_fails_loudly(tmp_path):
    report = make_report(cpes=[
        "cpe:2.3:*:*:linux_kernel:6.18.37:*:*:*:*:*:*:*",
        "cpe:2.3:*:*:linux_kernel:6.18.42:*:*:*:*:*:*:*",
    ])
    report_path = write_report(tmp_path, report)
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path)])

    assert result.returncode != 0
    assert "ambiguous" in result.stderr
    assert not out_path.exists()


def test_dirty_cpe_version_rejected(tmp_path):
    # A CPE version that is itself not clean (e.g. an -rc suffix that slipped
    # through) must not be silently truncated or guessed at.
    report = make_report(cpes=[
        "cpe:2.3:*:*:linux_kernel:6.18.37-rc1:*:*:*:*:*:*:*",
    ])
    report_path = write_report(tmp_path, report)
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path)])

    assert result.returncode != 0
    assert "not a clean" in result.stderr
    assert not out_path.exists()


def test_no_matching_cpe_for_product_fails_loudly(tmp_path):
    report = make_report(cpes=[
        "cpe:2.3:*:*:some_other_product:6.18.37:*:*:*:*:*:*:*",
    ])
    report_path = write_report(tmp_path, report)
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path)])

    assert result.returncode != 0
    assert "no cpes entry" in result.stderr
    assert not out_path.exists()


def test_package_not_found_fails_loudly(tmp_path):
    report_path = write_report(tmp_path, make_report())
    out_path = tmp_path / "normalized.json"

    result = run(["-i", str(report_path), "-o", str(out_path),
                  "--pkg-name", "no-such-package"])

    assert result.returncode != 0
    assert "not found" in result.stderr
    assert not out_path.exists()


def test_out_same_as_input_rejected(tmp_path):
    report_path = write_report(tmp_path, make_report())

    result = run(["-i", str(report_path), "-o", str(report_path)])

    assert result.returncode != 0
    assert "must not be the same path" in result.stderr
