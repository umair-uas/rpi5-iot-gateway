# Ensure firmware-provided /chosen/bootargs uses the gateway serial console.
# U-Boot inherits these args and appends RAUC slot root=PARTUUID at runtime.
CMDLINE_SERIAL = "console=ttyAMA10,115200"

# Avoid embedding a static root= token from firmware cmdline.
# RAUC/U-Boot chooses the active slot and injects root=PARTUUID dynamically.
CMDLINE_ROOTFS = ""

# --- DX-M1: disable PCIe ASPM -----------------------------------------------
#
# REQUIRED FOR FUNCTION on DX-M1-enabled images, not a tuning knob.
#
# With ASPM active the BCM2712 root port lets the DX-M1 endpoint enter a
# low-power link state from which its PCI config space reads back as reset. The
# v2.6.0 driver's link-health worker correctly detects that ("endpoint config
# reset detected") and attempts recovery — but a config-space read to a
# momentarily inaccessible endpoint is escalated by BCM2712 into a fatal
# asynchronous SError rather than returning 0xffff. The result is a kernel
# panic from a workqueue, on a ~10s cadence, with no userspace involvement:
#
#   Workqueue: events dx_link_health_work_fn [dx_dma]
#   pci_generic_config_read -> el1h_64_error -> arm64_serror_panic
#   Kernel panic - not syncing: Asynchronous SError Interrupt
#
# Measured 2026-09-01 on this board, single variable changed:
#
#            ASPM on            ASPM off
#   resets   ~1 per 10s         0
#   CESta    RxErr+ Rollover+   all clear
#            Timeout+
#   result   5 panics / 6 boots acceptance passes, survives warm reboot
#
# This also matches the known-good reference: a stock Debian install on the
# same board and firmware reports `LnkCtl: ASPM Disabled` and never logs a
# single reset event.
#
# SCOPED to the DX-M1 feature deliberately. pcie_aspm=off is global — it would
# also disable ASPM for the RP1 south bridge carrying USB and Ethernet — so
# images without the accelerator keep their link power management.
#
# A more surgical fix (clearing ASPM for this endpoint alone, via a udev rule
# on driver bind) would avoid the global scope, but is UNPROVEN; the global
# switch is what was actually validated on hardware. Revisit if link-state
# power draw ever matters.
IOTGW_CMDLINE_DEEPX_ASPM ?= "${@'pcie_aspm=off' if d.getVar('IOTGW_ENABLE_DEEPX_DXM1') == '1' else ''}"
CMDLINE:append = " ${IOTGW_CMDLINE_DEEPX_ASPM}"
