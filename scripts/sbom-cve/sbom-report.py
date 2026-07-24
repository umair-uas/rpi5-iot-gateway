#!/usr/bin/env python3
"""
Summarise the SBOM produced by the sbom-cve-check class (wrynose).

Reads *.sbom-cve-check.spdx.json (SPDX 3.0.1 JSON-LD @graph): a typed node
graph joined by spdxId. Emits a package/recipe/license inventory, a
license-category breakdown, top license expressions, gap counts (packages
missing a license or a download URL), and a HIGH-risk license review list.

Read-only over the deploy tree; produces no build state.

Usage:
  scripts/sbom-cve/sbom-report.py                # auto-locate newest SBOM
  scripts/sbom-cve/sbom-report.py -i path.spdx.json
  scripts/sbom-cve/sbom-report.py --csv dl.csv   # package/license/download CSV
"""

import argparse
import csv
import os
import re
import sys

from cohort import load, report_provenance, resolve_newest

# Newest matching SBOM under the standard deploy tree when -i is absent.
DEPLOY_GLOB = "build/tmp/deploy/images/*/*.sbom-cve-check.spdx.json"

# License classification works on the SPDX expression string only, so it is
# format-independent (SPDX 2.2 or 3.0.1). Risk is tuned for an embedded image:
# v3 / AGPL anti-tivoization + network clauses are HIGH; v2 copyleft (GPL-2.0,
# the kernel license, ubiquitous) is the informational copyleft-weak tier,
# not HIGH.
STRONG_COPYLEFT = ("AGPL-3.0", "GPL-3.0", "LGPL-3.0", "AGPL", "EUPL")
WEAK_COPYLEFT = ("GPL-2.0", "GPL-1.0", "LGPL-2", "MPL", "EPL", "CDDL",
                 "CPL", "OSL", "GPL", "LGPL")
PERMISSIVE = ("MIT", "BSD", "APACHE", "ISC", "ZLIB", "LIBPNG", "AFL",
              "ARTISTIC", "BSL", "NCSA", "X11", "BOOST", "CURL", "FTL",
              "OPENSSL", "PSF", "UNICODE")
PUBLIC_DOMAIN = ("CC0", "PUBLICDOMAIN", "PUBLIC-DOMAIN", "UNLICENSE", "0BSD")
PROPRIETARY = ("PROPRIETARY", "COMMERCIAL", "LICENSEREF-PROPRIETARY")

_LIC_OPS = ("AND", "OR", "WITH", "(", ")")


def license_tokens(expr):
    """Individual license identifiers in an SPDX expression (no operators)."""
    parts = re.split(r"(\s+AND\s+|\s+OR\s+|\s+WITH\s+|\(|\))", expr or "")
    out = []
    for part in parts:
        part = part.strip()
        if part and part not in _LIC_OPS:
            out.append(part)
    return out


def classify_license(expr):
    """Return (category, risk) for an SPDX license expression.

    category: proprietary | copyleft-strong | copyleft-weak | permissive |
              public_domain | custom | unknown
    risk    : HIGH | MEDIUM | LOW
    """
    if not expr or expr.upper() in ("NOASSERTION", "NONE", ""):
        return "unknown", "MEDIUM"
    upper = expr.upper()
    if any(m in upper for m in PROPRIETARY):
        return "proprietary", "HIGH"
    tokens = [t.upper() for t in license_tokens(expr)] or [upper]
    if any(any(s in t for s in (m.upper() for m in STRONG_COPYLEFT))
           for t in tokens):
        return "copyleft-strong", "HIGH"
    if any(any(w in t for w in (m.upper() for m in WEAK_COPYLEFT))
           for t in tokens):
        return "copyleft-weak", "MEDIUM"
    if any(any(p in t for p in PERMISSIVE) for t in tokens):
        return "permissive", "LOW"
    if any(any(d in t for d in PUBLIC_DOMAIN) for t in tokens):
        return "public_domain", "LOW"
    if "LICENSEREF-" in upper:
        return "custom", "MEDIUM"
    return "unknown", "MEDIUM"


def recipe_key(spdx_id):
    """The per-recipe document segment after /spdxdocs/ — the node join key.

    A recipe's package, source, file and license nodes all share this
    segment but differ in the content-hash segment that follows it, so
    relationships whose 'from' is a source/file node still map back to the
    recipe package by this key.
    """
    if not spdx_id or "/spdxdocs/" not in spdx_id:
        return None
    return spdx_id.split("/spdxdocs/", 1)[1].split("/", 1)[0]


def write_sbom_csv(path, packages, licenses_by_recipe):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["package", "version", "license", "category", "risk",
                    "downloadLocation", "packageUrl", "homePage"])
        for pkg in packages:
            key = recipe_key(pkg.get("spdxId", ""))
            exprs = sorted(licenses_by_recipe.get(key, set()))
            licenses = " | ".join(exprs) or "NOASSERTION"
            category, risk = classify_license(exprs[0] if exprs else "")
            w.writerow([
                pkg.get("name", ""), pkg.get("software_packageVersion", ""),
                licenses, category, risk,
                pkg.get("software_downloadLocation", ""),
                pkg.get("software_packageUrl", ""),
                pkg.get("software_homePage", ""),
            ])


def main(argv):
    ap = argparse.ArgumentParser(
        description="Summarise the sbom-cve-check SPDX 3.0.1 SBOM.")
    ap.add_argument("-i", "--input", help="path to *.sbom-cve-check.spdx.json")
    ap.add_argument("--top", type=int, default=25, help="license rows to show")
    ap.add_argument("--all", action="store_true", help="show every license")
    ap.add_argument("--csv", help="write package/license/download CSV to path")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero on a cohort integrity failure "
                         "(missing/mismatched companion)")
    ap.add_argument("--require-latest", action="store_true",
                    help="also fail if a newer image build exists than the SBOM")
    args = ap.parse_args(argv)

    path = args.input or resolve_newest(DEPLOY_GLOB)
    path = report_provenance(path, args.strict, args.require_latest, "sbom")
    print("# loading %s (large graph; a moment) ..." % os.path.basename(path),
          file=sys.stderr)
    graph = load(path).get("@graph", [])

    packages = [n for n in graph if n.get("type") == "software_Package"]
    license_expr = {
        node["spdxId"]: node.get("simplelicensing_licenseExpression", "")
        for node in graph
        if node.get("type") == "simplelicensing_LicenseExpression"
    }

    # recipe-key -> set(license expression strings), via hasDeclaredLicense.
    licenses_by_recipe = {}
    for node in graph:
        if (node.get("type") == "Relationship" and
                node.get("relationshipType") == "hasDeclaredLicense"):
            key = recipe_key(node.get("from", ""))
            if key is None:
                continue
            for target in node.get("to", []):
                expr = license_expr.get(target)
                if expr:
                    licenses_by_recipe.setdefault(key, set()).add(expr)

    # SPDX 3.0 splits package nodes by software_primaryPurpose: 'source' nodes
    # are the fetched upstream artifacts (they carry the download URL); 'install'
    # / 'specification' nodes are the locally-built packages and recipes (which
    # correctly have no download URL). A download-coverage gap is only meaningful
    # over 'source' nodes.
    license_counts = {}
    no_license = []
    source_no_url = []
    purpose = {}
    for pkg in packages:
        p = pkg.get("software_primaryPurpose", "unknown")
        purpose[p] = purpose.get(p, 0) + 1
        key = recipe_key(pkg.get("spdxId", ""))
        licenses = licenses_by_recipe.get(key, set())
        if licenses:
            for expr in licenses:
                license_counts[expr] = license_counts.get(expr, 0) + 1
        elif p != "source":
            no_license.append(pkg.get("name", "?"))
        if p == "source" and not pkg.get("software_downloadLocation"):
            source_no_url.append(pkg.get("name", "?"))

    # Per-package category tally (each package counted once by its license).
    packages_by_category = {}
    for pkg in packages:
        expr = next(iter(licenses_by_recipe.get(
            recipe_key(pkg.get("spdxId", "")), set())), "NOASSERTION")
        category, _ = classify_license(expr)
        packages_by_category[category] = packages_by_category.get(category, 0) + 1

    print("\n=== inventory ===")
    print("  recipes                  %5d" % purpose.get("specification", 0))
    print("  installed packages       %5d" % purpose.get("install", 0))
    print("  source artifacts         %5d  (fetched upstream sources)"
          % purpose.get("source", 0))
    print("  distinct licenses        %5d" % len(license_counts))
    print("  packages w/o license     %5d  (built packages only; source excluded)"
          % len(no_license))
    print("  source artifacts w/o URL %5d  (download-location coverage gap)"
          % len(source_no_url))

    print("\n=== license categories (by package) ===")
    for category in ("proprietary", "copyleft-strong", "copyleft-weak",
                     "permissive", "public_domain", "custom", "unknown"):
        if packages_by_category.get(category):
            print("  %-16s %5d" % (category, packages_by_category[category]))

    limit = len(license_counts) if args.all else min(args.top, len(license_counts))
    print("\n=== top %d license expressions ===" % limit)
    for expr, count in sorted(license_counts.items(),
                              key=lambda kv: kv[1], reverse=True)[:limit]:
        category, risk = classify_license(expr)
        mark = "  <<< %s" % category if risk == "HIGH" else ""
        print("  %4d  %s%s" % (count, expr, mark))

    review = sorted(e for e in license_counts
                    if classify_license(e)[1] == "HIGH")
    if review:
        print("\n=== HIGH-risk license expressions (embedded review) ===")
        print("# copyleft-strong = v3 / AGPL anti-tivoization + network "
              "clauses; proprietary = verify distribution rights.")
        for expr in review:
            print("  %-16s %s" % (classify_license(expr)[0], expr))

    if args.csv:
        write_sbom_csv(args.csv, packages, licenses_by_recipe)
        print("\n# wrote %d package rows to %s" % (len(packages), args.csv))


if __name__ == "__main__":
    main(sys.argv[1:])
