#!/bin/bash
# Seed an agent worktree with the operator's kas/local.yml, ISOLATE its layer
# checkout, and verify the shared Yocto caches are wired, so builds restore
# from sstate instead of compiling cold (minutes vs hours).
#
# WHAT MAY BE SHARED, AND WHAT MUST NOT:
#   SHARE  DL_DIR, SSTATE_DIR      — downloads and sstate objects. Concurrent
#                                    readers/writers are safe by design.
#   SHARE  KAS_REPO_REF_DIR        — bare-repo git alternates, read-only.
#   NEVER  KAS_WORK_DIR            — the layer CHECKOUT (.kas/). Two kas
#                                    invocations sharing it will check the
#                                    layers to different pins, and the second
#                                    one rewrites the metadata underneath the
#                                    first one's running build.
#   NEVER  KAS_BUILD_DIR           — one bitbake.lock per build tree.
#
# The failure mode when KAS_WORK_DIR is shared does not look like a
# coordination problem. The running build reports "the basehash value changed
# ... metadata is not deterministic" against innocent recipes, then dies on a
# FileNotFoundError for a recipe that exists at one pin and not the other.
# Observed 2026-08-31: a worktree seeded off an older commit reverted the main
# checkout's layers mid-build and cost ~3900 tasks of cold compile.
#
# scripts/env.sh alone does NOT protect you here. It derives KAS_WORK_DIR from
# its own location, which would be worktree-local, but it honours a pre-set
# value (`${KAS_WORK_DIR:-...}`) — so a shell that already carries the main
# checkout's export keeps pointing at the main .kas/. This script therefore
# sets both variables explicitly before sourcing it.
#
# Usage (from the MAIN checkout root):
#   .claude/skills/yocto-worktree/scripts/seed-and-verify.sh <worktree-dir>
#   e.g. ... .claude/worktrees/agent-abc123
#
# Exit codes:
#   0  seeded; layer checkout isolated to this worktree, and DL_DIR /
#      SSTATE_DIR resolve outside the worktree's build/
#   1  usage / missing prerequisites (fix before building)
#   2  cache verification failed — do NOT start a build

set -u

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <worktree-dir>"
WT=$1
[ -d "$WT" ] || die "worktree dir not found: $WT"
[ -f scripts/env.sh ] || die "scripts/env.sh not found — run this from the main checkout root"
# No local.yml means no shared-cache config exists to copy. Inventing cache
# paths here would silently produce an hours-long cold build; the operator
# owns this file (see kas/local.yml.example).
[ -f kas/local.yml ] || die "kas/local.yml missing in the main checkout — stop and ask the operator"

cp kas/local.yml "$WT/kas/local.yml" || die "failed to copy kas/local.yml into $WT/kas/"
echo "seeded: $WT/kas/local.yml"

cd "$WT" || die "cannot cd into $WT"
[ -f scripts/env.sh ] || die "$WT has no scripts/env.sh — not a checkout of this repo?"

# Isolate the layer checkout and build dir to THIS worktree before doing
# anything that runs kas. Setting them explicitly overrides any value inherited
# from a shell that previously sourced env.sh in the main checkout; env.sh's
# `${VAR:-default}` would otherwise preserve that inherited value and aim this
# worktree's kas at the main checkout's .kas/.
export KAS_WORK_DIR="$PWD/.kas"
export KAS_BUILD_DIR="$PWD/build"
mkdir -p "$KAS_WORK_DIR" || die "cannot create $KAS_WORK_DIR"

# Refuse to continue if the checkout is not actually inside this worktree.
# This is the check whose absence caused the 2026-08-31 incident.
case $KAS_WORK_DIR in
    "$PWD"/*) echo "OK: KAS_WORK_DIR=$KAS_WORK_DIR (isolated to this worktree)" ;;
    *)        die "KAS_WORK_DIR=$KAS_WORK_DIR is outside $PWD — refusing to run kas" ;;
esac

# env.sh must be sourced in the same shell as the kas call: agent shells do
# not get direnv, and bare kas would re-clone the layer stack into the CWD.
# The two exports above are already in this shell's environment, so env.sh
# leaves them alone.
vars=$(. scripts/env.sh && kas shell -c 'bitbake -e | grep -E "^(DL_DIR|SSTATE_DIR)="' kas/local.yml 2>&1 \
       | grep -E '^(DL_DIR|SSTATE_DIR)=')
[ -n "$vars" ] || { echo "ERROR: could not read DL_DIR/SSTATE_DIR via kas — inspect manually:" >&2
                    echo "  . scripts/env.sh && kas shell -c 'bitbake -e | grep -E \"^(DL_DIR|SSTATE_DIR)=\"' kas/local.yml" >&2
                    exit 2; }
echo "$vars"

# A cache dir under this worktree's own build/ means local.yml did not take
# effect (bitbake fell back to ${TOPDIR}-relative defaults) — cold build.
bad=0
for v in DL_DIR SSTATE_DIR; do
    val=$(printf '%s\n' "$vars" | sed -n "s/^$v=\"\(.*\)\"$/\1/p")
    case $val in
        "")             echo "ERROR: $v not set"; bad=1 ;;
        "$PWD"/build/*) echo "ERROR: $v=$val is inside the worktree build dir — shared cache NOT wired"; bad=1 ;;
        *)              echo "OK: $v=$val" ;;
    esac
done
[ "$bad" -eq 0 ] || exit 2
echo "shared caches wired, layer checkout isolated — safe to build"
echo "  isolated: KAS_WORK_DIR=$KAS_WORK_DIR"
echo "  isolated: KAS_BUILD_DIR=$KAS_BUILD_DIR"
echo
echo "Every kas/make/bitbake call in this worktree MUST carry those two"
echo "exports. They are not persisted anywhere — a fresh shell that sources"
echo "scripts/env.sh without them can inherit the main checkout's .kas/."
