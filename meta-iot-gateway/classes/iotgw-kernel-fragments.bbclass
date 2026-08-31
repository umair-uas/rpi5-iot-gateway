# Shared IoT Gateway kernel fragment policy for all kernel providers.
#
# IOTGW_KERNEL_FRAGMENTS is the single source of truth for which fragments
# are expected in ${UNPACKDIR}/fragments/.  SRC_URI is derived from it, so
# the two lists cannot drift.  do_configure:append enforces the invariant
# in both directions:
#   - every fragment named here must exist (fetch failure guard)
#   - every .cfg present in the workdir must be named here (stale-residue guard)
#
# Recipes that add their own unconditional fragments (e.g. thermal-rpi5.cfg)
# must pair the SRC_URI:append with a matching IOTGW_KERNEL_FRAGMENTS:append
# so the guard stays consistent.

# Gate Raspberry Pi firmware RTC support for providers that carry the backport.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Gate Raspberry Pi EEPROM tooling stack (shared with packagegroup gating).
IOTGW_ENABLE_RPI_EEPROM ?= "1"

# Gate VCIO mailbox chardev (/dev/vcio) needed by vcgencmd and rpi-eeprom-update.
# Default follows EEPROM tooling gate; developers can override independently.
IOTGW_ENABLE_VCIO ?= "${IOTGW_ENABLE_RPI_EEPROM}"

# ---------------------------------------------------------------------------
# Base fragments — always applied.
# ---------------------------------------------------------------------------
IOTGW_KERNEL_FRAGMENTS = "branding.cfg trim.cfg \
    storage-filesystems.cfg ikconfig.cfg \
    audit.cfg panic-recovery.cfg"

# panic-on-oops.cfg is gated so dev builds can disable CONFIG_PANIC_ON_OOPS
# (default-on) from kas/local.yml without source edits.
IOTGW_KERNEL_FRAGMENTS += "${@'panic-on-oops.cfg' if d.getVar('IOTGW_ENABLE_PANIC_ON_OOPS') == '1' else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'rtc-rpi.cfg' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'vcio-rpi.cfg' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"

# Optional fragments toggled via IOTGW_KERNEL_FEATURES (space/comma-separated).
IOTGW_KERNEL_FRAGMENTS += "${@'compute-media.cfg' if 'igw_compute_media' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
# DX-M1 accelerator: widen the exported-symbol set by exactly two symbols so
# the out-of-tree NPU driver can link. Scoped to the feature so every other
# image keeps TRIM_UNUSED_KSYMS at full strength.
IOTGW_KERNEL_FRAGMENTS += "${@'deepx-dxm1-ksyms.cfg' if 'igw_deepx_dxm1' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'containers-cgroups.cfg' if 'igw_containers' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'networking-iot.cfg' if 'igw_networking_iot' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'observability-dev.cfg' if 'igw_observability_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'btf-core-dev.cfg' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'pstore-persist.cfg' if 'igw_pstore_persist' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'debug-crash-dev.cfg' if 'igw_crash_debug_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'security-prod.cfg' if 'igw_security_prod' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'tpm-slb9672.cfg' if 'igw_tpm_slb9672' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'efi-surface-reduction.cfg' if 'igw_no_efi' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'ima.cfg' if 'igw_ima' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Derive SRC_URI from IOTGW_KERNEL_FRAGMENTS so the two lists cannot diverge.
# Use :append (expansion-time) — kernel providers reset SRC_URI with `=`
# inside the recipe body, which would wipe out a parse-time `+=`.
SRC_URI:append = " ${@' '.join('file://fragments/' + f for f in (d.getVar('IOTGW_KERNEL_FRAGMENTS') or '').split() if f)}"

# Merge tracked fragments into the active kernel .config.
# Two invariants are enforced via bbfatal to catch regressions immediately:
#   1. Every fragment in IOTGW_KERNEL_FRAGMENTS must be present in the workdir.
#   2. No .cfg file in ${UNPACKDIR}/fragments/ may exist outside IOTGW_KERNEL_FRAGMENTS
#      — this is the stale-residue guard that prevents leftover files from a
#      previous build with different gates from silently altering the config.
do_configure:append() {
    # Build the allowed set and the ordered merge list from IOTGW_KERNEL_FRAGMENTS.
    tracked="${IOTGW_KERNEL_FRAGMENTS}"
    frags=
    for fname in $tracked; do
        fpath="${UNPACKDIR}/fragments/$fname"
        if [ ! -f "$fpath" ]; then
            bbfatal "iotgw-kernel-fragments: expected fragment missing: $fpath (check SRC_URI fetch)"
        fi
        frags="$frags $fpath"
    done

    # Stale-residue guard: reject any .cfg not in the tracked list.
    if [ -d "${UNPACKDIR}/fragments" ]; then
        for present in "${UNPACKDIR}/fragments/"*.cfg; do
            [ -f "$present" ] || continue
            bname=$(basename "$present")
            found=0
            for fname in $tracked; do
                if [ "$bname" = "$fname" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" = "0" ]; then
                bbfatal "iotgw-kernel-fragments: stale fragment not in IOTGW_KERNEL_FRAGMENTS: $present -- cleansstate the recipe and rebuild"
            fi
        done
    fi

    if [ -n "$frags" ] && [ -x "${S}/scripts/kconfig/merge_config.sh" ]; then
        oe_runmake -C ${S} O=${B} olddefconfig
        ${S}/scripts/kconfig/merge_config.sh -m -O ${B} ${B}/.config $frags || die "merge_config failed"
        oe_runmake -C ${S} O=${B} olddefconfig
    fi
}
