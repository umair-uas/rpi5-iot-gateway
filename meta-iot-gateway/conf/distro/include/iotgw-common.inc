# IoT Gateway common distro include
# Centralizes vendor branding, versioning, SDK naming, QA policy, and RAUC defaults.

# Vendor branding
VENDOR_SHORT_NAME ?= "igw"
VENDOR_LONG_NAME ?= "IoT Gateway"

# Propagate vendor into target triplet and SDK names
TARGET_VENDOR ?= "-${VENDOR_SHORT_NAME}"

# Distro/versioning policy (override OE-Core default 'nodistro.0')
# Keep version components explicit so release policy can bump one field at a time.
IOTGW_VERSION_MAJOR ?= "0"
IOTGW_VERSION_MINOR ?= "5"
IOTGW_VERSION_PATCH ?= "0"
IOTGW_VERSION ?= "${IOTGW_VERSION_MAJOR}.${IOTGW_VERSION_MINOR}.${IOTGW_VERSION_PATCH}"
DISTRO_VERSION ?= "${VENDOR_SHORT_NAME}.${IOTGW_VERSION}"
# Default codename for this product line (override in CI if desired)
DISTRO_CODENAME ?= "rpi5"

# RAUC bundle version policy:
#   <distro-version>-<machine>-<image-track>-b<build-id>
# where image-track is derived from iot-gw-image-{dev,prod,base,...}.
# CI/release jobs may override IOTGW_BUILD_ID or RAUC_BUNDLE_VERSION directly.
IOTGW_RELEASE_TRACK ?= "${@((d.getVar('BUNDLE_IMAGE_NAME') or d.getVar('IMAGE_BASENAME') or 'iot-gw-image-unknown').replace('iot-gw-image-', ''))}"
IOTGW_BUILD_ID ?= "${@d.getVar('SOURCE_DATE_EPOCH') or '0'}"
RAUC_BUNDLE_VERSION ?= "${DISTRO_VERSION}-${MACHINE}-${IOTGW_RELEASE_TRACK}-b${IOTGW_BUILD_ID}"
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"
PREFERRED_RPROVIDER_virtual-rauc-conf ?= "rauc-conf-iotgw"

# libnss-mdns is RPROVIDED by both avahi-libnss-mdns and mdns (mDNSResponder,
# pulled in via otbr-rpi5's RDEPENDS). This distro standardises on avahi for
# mDNS/DNS-SD (avahi-daemon ships in the images, OTBR builds with
# -DOTBR_MDNS=avahi), so pin the NSS mDNS plugin to avahi's to match the
# running resolver and resolve the multiple-provider ambiguity deterministically.
PREFERRED_RPROVIDER_libnss-mdns ?= "avahi-libnss-mdns"

# Avoid parsing meta-rauc's reference rauc-conf which expects certs not present here
SKIP_RECIPE[rauc-conf] = "replaced with rauc-conf-iotgw"
PREFERRED_VERSION_rauc ?= "1.15.2"
PREFERRED_VERSION_rauc-native ?= "1.15.2"
PREFERRED_VERSION_nativesdk-rauc ?= "1.15.2"

# RAUC keyring default for device verification (bundle signing keys are set in bundle recipes or kas/local.yml)
RAUC_KEYRING_FILE ?= "dev-cert.pem"

# Build metadata exposure policy
# Keep host build system identifier in buildinfo by default for diagnostics.
# Production images can disable this in image recipes.
IOTGW_BUILDINFO_INCLUDE_BUILD_SYS ?= "1"

# SDK branding
SDK_VENDOR ?= "-${VENDOR_SHORT_NAME}sdk"
SDK_VERSION := "${DISTRO_VERSION}"
SDK_NAME ?= "${VENDOR_SHORT_NAME}-${DISTRO}-${TCLIBC}-${SDK_ARCH}-${IMAGE_BASENAME}-${TUNE_PKGARCH}"
SDKPATH ?= "/opt/${VENDOR_SHORT_NAME}-${DISTRO}/${SDK_VERSION}"

# Prefer Lynis 3.1.5 from our overlay
PREFERRED_VERSION_lynis ?= "3.1.5"

# Node.js binary provider/version policy
# Keep default on 20.x: the OTBR web UI is validated against this runtime.
# Override in local/product config when testing newer runtime, e.g.:
#   IOTGW_NODEJS_BIN_VERSION = "22.22.0"
PREFERRED_PROVIDER_nodejs ?= "nodejs-bin"
IOTGW_NODEJS_BIN_VERSION ?= "20.12.2"
PREFERRED_VERSION_nodejs-bin ?= "${IOTGW_NODEJS_BIN_VERSION}"
PREFERRED_VERSION_nodejs-bin-native ?= "${IOTGW_NODEJS_BIN_VERSION}"

# Policy and QA
INHERIT += "sanity"
INHERIT += "insane"
QA_LOG ?= "1"
ERROR_TO_WARN_QA ?= "version-going-backwards"

# ── FIT signed-boot policy (mandatory; the ONLY supported boot flow) ──────────
# Historically gated behind IOTGW_BOOT_FLOW / a ':fitflow' override that lived
# only in the gitignored kas/local.yml — so a clean checkout silently built the
# stock linux-raspberrypi kernel, unsigned. FIT is now unconditional and tracked;
# there is no non-FIT flow. Operator key *paths* stay in kas/local.yml.
PREFERRED_PROVIDER_virtual/kernel = "linux-iotgw-mainline-fit"
PREFERRED_VERSION_linux-iotgw-mainline-fit = "6.18%"
KERNEL_BOOTCMD = "bootm"

# Keep the FIT flow isolated from meta-raspberrypi's stock kernel recipes.
BBMASK:append = " .*/meta-raspberrypi/recipes-kernel/linux/linux-raspberrypi.*\\.(bb|bbappend)"
BBMASK:append = " .*/meta-raspberrypi/recipes-kernel/linux/linux-raspberrypi-v7.*\\.(bb|bbappend)"

# FIT signing algorithms (control-DTB pubkey injection + FIT config signature).
FIT_HASH_ALG = "sha256"
FIT_SIGN_ALG = "rsa2048"
FIT_GENERATE_KEYS = "0"

# Signing is REQUIRED. Default ON; iotgw-fit-signing-guard.bbclass hard-fails
# the build if this is off or no operator signing key is usable.
IOTGW_FIT_SIGNING ?= "1"
UBOOT_SIGN_ENABLE = "${@bb.utils.contains('IOTGW_FIT_SIGNING','1','1','0',d)}"

# ── U-Boot feature tokens ────────────────────────────────────────────────────
# IOTGW_UBOOT_FEATURES is read in three recipe datastores that do not share
# variables: the u-boot recipe (builds the matching cfg/patch), the
# rpi-bootfiles-archive-* recipe (self-heals the matching boot-critical env vars
# into the RAUC bundle), and the image recipes (write /etc/default/
# iotgw-uboot-policy). The default is set here, distro-wide, so all three see the
# same tokens; a per-recipe default would leave the bootfiles recipe (which has
# none of its own) blind to it.
#
#   surface_reduce  disable unused U-Boot commands
#   fit_enforce     require signed FIT, drop legacy image format (mandatory)
#   watchdog        BCM2712 wdt (watchdog@7d200000): armed across the U-Boot
#                   RAUC/FIT boot path and the exhausted-slot halt, stopped
#                   before bootm
#
# prod adds appliance_lockdown via kas/uboot-prod-hardening.yml (global, reaches
# the u-boot recipe) and iot-gw-image-prod.bb (image datastore).
IOTGW_UBOOT_FEATURES ?= "surface_reduce fit_enforce watchdog"


# Init system and features (single source of truth)
INIT_MANAGER ?= "systemd"
VIRTUAL-RUNTIME_init_manager ?= "systemd"
# Journald-only policy: do not pull classic syslog daemons from packagegroups.
VIRTUAL-RUNTIME_base-utils-syslog = ""
DISTRO_FEATURES:append = " systemd bluetooth virtualization usrmerge security"
# RAUC is mandatory in this distro
DISTRO_FEATURES:append = " rauc"
DISTRO_FEATURES:append = " luks"
# SELinux is the distro's active MAC (always on). This bit both flips
# PACKAGECONFIG[selinux] in oe-core recipes (systemd, PAM, ...) and fires
# the meta-selinux bbappends. Kernel-side LSM stack: security-prod.cfg.
# Userspace/policy: packagegroup-iot-gw-selinux. Primer: docs/SELINUX.md.
DISTRO_FEATURES:append = " selinux"

# MCS refpolicy variant: full module set plus the single non-hierarchical
# sensitivity level. The container runtime (podman/netavark/container-selinux)
# relabels netns/overlay dirs with 4-field :s0 contexts; a non-MCS (3-field)
# policy rejects those at lsetxattr() with EINVAL even in permissive mode,
# breaking rootless bridge/host networking. This concrete package name must
# stay in sync with packagegroup-iot-gw-selinux's refpolicy RDEPENDS.
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"

# Permissive floor: AVC denials log to audit, nothing is blocked. Flip to
# "enforcing" only after policy coverage is validated against the full image
# surface. Recovery escape stays the selinux=0 kernel param.
DEFAULT_ENFORCING = "permissive"

# openssl unblocks systemd-creds/cryptenroll crypto flows. The systemd `tpm2`
# PACKAGECONFIG (libtss2) is added by kas/tpm.yml, not here: tpm2-tss lives in
# meta-secure-core, which is composed only with the TPM overlay — adding the
# PACKAGECONFIG unconditionally would break non-TPM builds.
PACKAGECONFIG:append:pn-systemd = " openssl"
PACKAGECONFIG:append:pn-systemd = " pcre2 audit"
PACKAGECONFIG:append:pn-systemd = " cryptsetup cryptsetup-plugins"
PACKAGECONFIG:append:pn-cryptsetup = " luks2"

# Network management: systemd-networkd (not NetworkManager). networkd owns
# addressing/DHCP; systemd-resolved owns DNS and writes the resolv.conf stub.
# The topology (br0 bridge + eth0 port + wlan0 WiFi via wpa_supplicant) ships
# in iotgw-network-units. networkd/resolved are in systemd's default
# PACKAGECONFIG; keep them and enable via 90-iotgw.preset.
VIRTUAL-RUNTIME_net_manager = "systemd-networkd"
RESOLV_CONF = "stub-resolv"

# Always use U-Boot on Raspberry Pi for RAUC boot flow
RPI_USE_U_BOOT ?= "1"

# Trim unneeded distro features (conservative defaults).
# Wrynose (Yocto 6.0) auto-enables multiarch/opengl/ptest/vulkan/wayland by
# default (via DISTRO_FEATURES_DEFAULTS, the BACKFILL replacement). ptest and
# multiarch are stripped here for all image variants (no 32-bit userspace, no
# on-target ptest); opengl/vulkan/wayland are stripped per-profile below
# (:remove:headless), with the desktop variant re-adding them via :append:desktop.
DISTRO_FEATURES:remove = " pcmcia 3g nfc ptest multiarch debuginfod sysvinit nfs"

# Exclude unused RPC portmapper (pulled in by base packagegroups)
PACKAGE_EXCLUDE:append = " rpcbind"

# If product is headless, consider also removing windowing/graphics stacks:
# DISTRO_FEATURES:remove:append = " x11 wayland vulkan opengl pulseaudio"

# Root home
ROOT_HOME ?= "/root"

# Note: DEFAULTTUNE overrides for multiple SoCs can be added when needed.

# Wi-Fi interface — single source of truth. iotgw-network-units, iotgw-hardening
# (wpa_supplicant@<iface> drop-in) and the RAUC managed-path all derive from this,
# so overriding it in kas/local.yml keeps hardening + OTA management aligned.
IOTGW_WIFI_IFACE ?= "wlan0"

# Network-listening systemd socket units permitted in the image, as
# "<unit>=<address>" pairs. Enforced by iotgw-listen-guard.bbclass at rootfs
# assembly, by EXACT SET EQUALITY — so a listener that appears AND one that
# silently disappears both fail the build.
#
# sshd is pinned to IPv4 because upstream's sshd.socket ships a bare
# "ListenStream=22", which systemd binds dual-stack; with a global IPv6 address
# on any interface that makes SSH reachable off-link with no NAT in the path.
# The pin lives in recipes-connectivity/openssh/files/sshd.socket-iotgw.conf and
# rides inside openssh-sshd so no image can install sshd without it.
#
# Only covers socket-ACTIVATED units. A daemon that binds its own socket
# directly is asserted at runtime instead, by an on-target check.
IOTGW_NET_LISTEN_ALLOW ?= "sshd.socket=0.0.0.0:22"

# Allow injecting Wi-Fi credentials from the shell environment without committing them
# Usage: export IOTGW_WIFI_SSID=MySSID IOTGW_WIFI_PSK=Secret && bitbake iot-gw-image-rauc
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_WIFI_SSID IOTGW_WIFI_PSK IOTGW_WIFI_IFACE IOTGW_ENABLE_OTBR"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM_SLB9672 IOTGW_TPM_DTO_OVERLAY IOTGW_ENABLE_KERNEL_NO_EFI"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_OTA_TPM_MTLS IOTGW_OTA_TPM_KEY_URI IOTGW_OTA_TPM_KEY_ENGINE IOTGW_OTA_OPENSSL_CONF"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_RAUC_STREAMING_KEY_MODE IOTGW_RAUC_PKCS11_BACKEND IOTGW_RAUC_PKCS11_TLS_KEY IOTGW_RAUC_PKCS11_MODULE IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES IOTGW_TPM2_PKCS11_STORE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS IOTGW_RAUC_ENCRYPTION_KEY IOTGW_RAUC_ENCRYPTION_CERT"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_RAUC_KEYRING_CERTS IOTGW_RAUC_ALLOWED_SIGNER_CNS IOTGW_RAUC_CHECK_PURPOSE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RPI_EEPROM IOTGW_ENABLE_VCIO"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_IMA"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_BTF_CORE_DEV IOTGW_ENABLE_ENCRYPTED_STORE_DEV"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_PSTORE_PERSIST IOTGW_ENABLE_CRASH_DEBUG_DEV"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_HW_WATCHDOG IOTGW_ENABLE_SYSTEMD_HW_WATCHDOG"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_PANIC_ON_OOPS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_UBOOT_EXTRA_KERNEL_ARGS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " BUNDLE_IMAGE_NAME"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_BUILD_ID IOTGW_VERSION_MAJOR IOTGW_VERSION_MINOR IOTGW_VERSION_PATCH"

# Prune machine features that are not relevant on Raspberry Pi 5
# Keep qemu-usermode to allow gobject-introspection typelibs generation at build time
MACHINE_FEATURES:remove = " apm"

# Profile-based feature selection (headless vs desktop)
# Default profile is headless; switch via KAS/local.conf: IOTGW_PROFILE = "desktop"
IOTGW_PROFILE ?= "headless"
OVERRIDES .= ":${IOTGW_PROFILE}"

# Headless/serial-focused default: skip vconsole setup unit to avoid
# vtcon-related startup warnings on framebuffer-less deployments.
IOTGW_DISABLE_VCONSOLE_SETUP ?= "1"

# Headless profile trims windowing/graphics/audio stacks
DISTRO_FEATURES:remove:headless = " x11 wayland vulkan opengl pulseaudio"

# Desktop profile: enable graphics/audio stacks, PAM and polkit (Wayland/Weston)
DISTRO_FEATURES:append:desktop = " wayland opengl vulkan pulseaudio pam polkit"

# Desktop packages (consumed by image recipes via override)
# Upstream weston-init manages the service and user/groups; we don't duplicate it.
IOTGW_DESKTOP_PACKAGES ?= "weston wayland-utils mesa libdrm"


# Optional kernel feature sets (selected via IOTGW_KERNEL_FEATURES)
# Globally enabled: networking (WireGuard/CAN/VLAN) + security (SELinux LSM
# stack/Seccomp/KSPP/no-SCTP, always applied via igw_security_prod).
# Per-image additions via IOTGW_KERNEL_FEATURES (space or comma-separated):
#   igw_containers         - namespaces, cgroups (for podman/docker)
#   igw_compute_media      - GPU/V4L2/cameras/hugepages (for desktop/ML)
#   igw_observability_dev  - eBPF/ftrace/kprobes (dev builds only)
#   igw_btf_core_dev       - BTF/DWARF metadata for libbpf CO-RE lab workflows
#   igw_pstore_persist     - pstore ramoops capture stack (production-safe; default on)
#   igw_crash_debug_dev    - aggressive lab-only debug (sysrq, hung-task, panic-on-oops)
#   igw_no_efi             - disable kernel EFI runtime/stub surface (opt-in)
#   igw_ima                - IMA measurement (PCR10, SHA256, ima-ng template)
IOTGW_KERNEL_FEATURES ?= "igw_networking_iot igw_security_prod"

# pstore persistence layer — production-safe. Reserves a 1 MiB ramoops region
# in DT, builds the kernel pstore RAM backend, and bind-mounts /data-backed
# storage onto /var/lib/systemd/pstore so kernel oops/panic state survives
# reboot. No behavior change otherwise — capture infrastructure only.
IOTGW_ENABLE_PSTORE_PERSIST ?= "1"

# Aggressive crash-debug lab profile — opt-in. Adds sysrq, hung-task and
# softlockup detectors, panic-on-oops, short panic timeout, and ftrace into
# pstore. Implies pstore persistence. Not for production fleet.
IOTGW_ENABLE_CRASH_DEBUG_DEV ?= "0"

# Effective persistence flag: crash-debug-dev always implies pstore-persist.
IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE = "${@'1' if (d.getVar('IOTGW_ENABLE_CRASH_DEBUG_DEV') == '1' or d.getVar('IOTGW_ENABLE_PSTORE_PERSIST') == '1') else '0'}"

IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE', '1', ' igw_pstore_persist', '', d)}"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_CRASH_DEBUG_DEV', '1', ' igw_crash_debug_dev', '', d)}"

# Crash-debug panic timeout (seconds). Drives the lab sysctl + U-Boot
# cmdline policy for fast post-mortem turnaround. The kernel-baked default
# (CONFIG_PANIC_TIMEOUT=30 in panic-recovery.cfg, always applied) is the
# floor that covers early-boot/pre-sysctl panics. Lab sysctl overrides
# this downward to 5s once userspace is up.
IOTGW_CRASH_PANIC_TIMEOUT ?= "5"

# Escalate kernel oops to panic so the panic timeout above actually fires
# for kernel-thread/driver oopses (default-on for fleet posture). Override
# to "0" in kas/local.yml during BSP bring-up / bisect work to keep
# tainted-but-running kernels accessible for triage. Wires
# panic-on-oops.cfg into the kernel build.
IOTGW_ENABLE_PANIC_ON_OOPS ?= "1"

# Build-time U-Boot EXTRA_KERNEL_ARGS policy. Applied at first boot (and
# on every fresh OTA install) by iotgw-provision.sh::apply_uboot_policy
# via fw_setenv. Honoured by iotgw_set_bootargs in U-Boot, which appends
# the value to bootargs after `root=PARTUUID` and `rauc.slot=`.
#
# Default empty — no runtime cmdline injection. The crash-debug lab profile
# owns its panic/oops/sysrq cmdline through this policy so firmware
# cmdline.txt stays a stable Raspberry Pi baseline.
#
# Production images with `appliance_lockdown` reject EXTRA_KERNEL_ARGS
# writes via the env writeable-list, so this policy is dev-only at
# runtime — the prod posture stays "no runtime cmdline injection from
# anywhere". For prod-fleet cmdline tuning, change this variable in the
# image build (rebuild + RAUC OTA). The fw_setenv path is gated; the
# build-time path is signed.
IOTGW_UBOOT_EXTRA_KERNEL_ARGS ?= "${@('panic=%s oops=panic sysrq_always_enabled=1' % (d.getVar('IOTGW_CRASH_PANIC_TIMEOUT') or '5')) if d.getVar('IOTGW_ENABLE_CRASH_DEBUG_DEV') == '1' else ''}"

# BCM2712 hardware watchdog (default on). Mainline 6.18.37 carries BCM2712 PM
# support and exposes /dev/watchdog0 on RPi5 unconditionally, so this flag no
# longer gates a kernel patch — it is retained as the intent/dependency toggle
# for the systemd PID1 ping below. Independent of that ping, an unopened
# /dev/watchdog0 does not reboot.
IOTGW_ENABLE_HW_WATCHDOG ?= "1"

# systemd hardware watchdog integration (enabled by default; issue #56).
# PID1 opens /dev/watchdog and pings it at RuntimeWatchdogSec cadence, so a
# wedged kernel/PID1 self-recovers by hardware reset. Requires
# IOTGW_ENABLE_HW_WATCHDOG=1 (or another driver source) for /dev/watchdog to
# exist. Ships the vendor drop-in via recipes-support/iotgw-systemd-watchdog
# (packaged only when this is "1").
#
# RUNTIME must stay <= the BCM2712 HW max heartbeat (bcm2835_wdt
# max_hw_heartbeat_ms ~= 16s). At <=16s systemd programs the hardware timeout
# directly and pings at RUNTIME/2 (7.5s here) — validated stable on-target
# (issue #56). ABOVE 16s (e.g. 20s/30s) the kernel must *bridge* the software
# timeout past the HW max via the watchdog-core worker; the worker->PID1
# fd-open handoff is racy on BCM2712 and resets the board erratically
# (reproduced at 20s: reset in ~7-40s; 15s soaks clean). So keep RUNTIME <=15s.
# SHUTDOWN is only the shutdown-hang guard and is not on the runtime feed path,
# so >16s there is fine.
IOTGW_ENABLE_SYSTEMD_HW_WATCHDOG ?= "1"
IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC ?= "15s"
IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC ?= "30s"

# Optional TPM2 over SPI profile for Infineon SLB9672-class modules.
# Enable to pull built-in TPM kernel config and Raspberry Pi firmware overlay.
# Overlay default maps to Raspberry Pi's upstream TPM SPI overlay.
IOTGW_ENABLE_TPM_SLB9672 ?= "0"
IOTGW_TPM_DTO_OVERLAY ?= "tpm-slb9670"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672', '1', ' igw_tpm_slb9672', '', d)}"

# Optional TPM crypto provider stack (userspace integrations):
#  - tpm2-pkcs11
#  - tpm2-openssl
#  - tpm2-tss-engine
# Keep disabled by default until app/client integration is wired.
IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS ?= "0"

# Optional OTA mTLS TPM key mode (ota-updater + ota-certs behavior):
# - 0: default file-key flow (/etc/ota/device.key required)
# - 1: TPM key-handle flow (keyless cert provisioning allowed; updater uses TPM key URI)
IOTGW_ENABLE_OTA_TPM_MTLS ?= "0"
IOTGW_OTA_TPM_KEY_URI ?= "handle:0x81000001"
IOTGW_OTA_TPM_KEY_ENGINE ?= "tpm2tss"
IOTGW_OTA_OPENSSL_CONF ?= "/etc/ota/openssl-tpm2.cnf"
# Effective TPM mTLS gate: auto-disable when TPM hardware/profile is disabled.
IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE ?= "${@'1' if ((d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') == '1' and (d.getVar('IOTGW_ENABLE_OTA_TPM_MTLS') or '0') == '1') else '0'}"

# RAUC streaming TLS key mode:
# - file:   tls-key=/etc/ota/device.key (default)
# - pkcs11: tls-key=<pkcs11:...> via configured PKCS#11 backend
IOTGW_RAUC_STREAMING_KEY_MODE ?= "file"

# PKCS#11 backend selector used when IOTGW_RAUC_STREAMING_KEY_MODE=pkcs11:
# - tpm2:  tpm2-pkcs11 provider + TPM2 token/object
# - custom: externally supplied provider/token/object
IOTGW_RAUC_PKCS11_BACKEND ?= "tpm2"

# Built-in profile preset: TPM2-backed PKCS#11 token.
# Module selection is provided by PKCS11_MODULE_PATH env from rauc.service drop-in.
IOTGW_RAUC_PKCS11_TLS_KEY_TPM2 ?= "pkcs11:token=iotgw;object=rauc-client-key;type=private;pin-source=file:/etc/ota/pkcs11-pin"
# Module path is retained as profile metadata for tooling/provisioning flows.
# RAUC streaming itself relies on libp11 + p11-kit discovery.
IOTGW_RAUC_PKCS11_MODULE_TPM2 ?= "/usr/lib/pkcs11/libtpm2_pkcs11.so"
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_TPM2 ?= "tpm2-pkcs11"
# TPM2 PKCS#11 token DB location used by sandboxed RAUC streaming helper.
# On persistent /data (not volatile /var/lib) so the device OTA identity
# survives reboot and A/B updates.
IOTGW_TPM2_PKCS11_STORE ?= "/data/tpm2_pkcs11"

# Custom profile preset: override these in kas/local.yml for other backends.
IOTGW_RAUC_PKCS11_TLS_KEY_CUSTOM ?= ""
IOTGW_RAUC_PKCS11_MODULE_CUSTOM ?= ""
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_CUSTOM ?= ""

# Effective runtime values consumed by recipes/services.
IOTGW_RAUC_PKCS11_TLS_KEY ?= "${@d.getVar('IOTGW_RAUC_PKCS11_TLS_KEY_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
IOTGW_RAUC_PKCS11_MODULE ?= "${@d.getVar('IOTGW_RAUC_PKCS11_MODULE_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
# Provider package(s) for the active PKCS#11 backend profile.
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES ?= "${@d.getVar('IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
# Effective key mode: auto-disable TPM2 PKCS#11 path when TPM profile is off.
IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE ?= "${@'file' if ((d.getVar('IOTGW_RAUC_STREAMING_KEY_MODE') or 'file') != 'pkcs11' or (((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').lower() == 'tpm2') and (d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') != '1')) else 'pkcs11'}"
# Internal helper gate used by OTA/RAUC recipes for TPM-only behavior.
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "${@'1' if ((d.getVar('IOTGW_RAUC_STREAMING_KEY_MODE') or 'file') == 'pkcs11' and (d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').lower() == 'tpm2' and (d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') == '1') else '0'}"

# Single source of truth for "this build needs the iotgw-tpm-policy package
# (and therefore the iotgwtpm /etc/group entry)". Consumed by the
# iotgw-ota-user RDEPENDS, the ota-certs install branch that wires the
# keyless-device-certs env override, and the IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS
# entry below. Keeping these three sites in sync via one derived gate avoids
# the silent-skew failure mode where the supplementary-group reconciler
# bbfatals because iotgwtpm is missing from /etc/group.
#
# The ${@...} expression is lazy: it evaluates whenever the variable is
# queried, against the datastore at that moment. That works for the normal
# config path (local.conf / kas overlay / distro include sets the primitive
# gates, then recipes read the derived gate later). It does NOT work if a
# downstream layer sets IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE or
# IOTGW_RAUC_PKCS11_USES_TPM2 in a recipe-scoped .bbappend -- bbappends only
# mutate their own recipe's datastore, so this derived gate would evaluate
# differently in that recipe than in the image-rootfs / other-recipe context.
# Set the underlying primitives (IOTGW_ENABLE_TPM_SLB9672,
# IOTGW_ENABLE_OTA_TPM_MTLS, IOTGW_RAUC_STREAMING_KEY_MODE,
# IOTGW_RAUC_PKCS11_BACKEND) at distro / local.conf / kas-overlay level, not
# in a bbappend.
IOTGW_NEED_TPM_POLICY ?= "${@'1' if ((d.getVar('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE') or '0') == '1' or (d.getVar('IOTGW_RAUC_PKCS11_USES_TPM2') or '0') == '1') else '0'}"

# Cross-recipe supplementary group membership applied at rootfs-postprocess.
# See meta-iot-gateway/classes/iotgw-rootfs.bbclass for the mechanism. The
# 'ota:iotgwtpm' pair fires whenever the iotgw-tpm-policy package is pulled
# in (which is what causes iotgwtpm to exist in /etc/group at all).
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS ??= ""
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS += "${@'ota:iotgwtpm' if (d.getVar('IOTGW_NEED_TPM_POLICY') or '0') == '1' else ''}"

# Optional encrypted RAUC bundle support (disabled by default):
# - build side: create `crypt` bundles and encrypt to recipient cert set
# - target side: populate /etc/rauc/system.conf [encryption] for decrypt key
IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= ""
IOTGW_RAUC_ENCRYPTION_KEY ?= ""
IOTGW_RAUC_ENCRYPTION_CERT ?= ""

# Optional kernel EFI surface reduction profile for non-UEFI RPi5 boot flow.
# Enable to append igw_no_efi fragment set.
IOTGW_ENABLE_KERNEL_NO_EFI ?= "1"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_KERNEL_NO_EFI', '1', ' igw_no_efi', '', d)}"

# SELinux is the always-on default MAC — not an opt-in feature. The kernel
# LSM stack lives in security-prod.cfg (applied on every image via
# igw_security_prod), userspace/policy in packagegroup-iot-gw-selinux, and
# the DISTRO_FEATURES/refpolicy/enforcing wiring above. See docs/SELINUX.md.

# Optional IMA measurement support. Requires TPM for replay-protected log.
# Measurement-only by default (no appraise) — safe without signed xattrs.
IOTGW_ENABLE_IMA ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_IMA', '1', ' igw_ima', '', d)}"

# Optional Raspberry Pi EEPROM tooling stack (rpi-eeprom + policy wrapper).
# Keep enabled by default for gateway fleet maintenance; developers can disable
# it for lean bring-up images and when VCIO carry patches are not desired.
IOTGW_ENABLE_RPI_EEPROM ?= "1"

# VCIO (/dev/vcio) enables vcgencmd and full rpi-eeprom-update status path.
# Default follows EEPROM tooling gate, but can be overridden explicitly.
IOTGW_ENABLE_VCIO ?= "${IOTGW_ENABLE_RPI_EEPROM}"

# Mainline RPi5 DTB note:
# - Firmware `dtparam=` keys must exist in DTB `__overrides__`.
# - Current mainline bcm2712-rpi-5-b path exports rtc/rtc_bbat_vchg, but not
#   generic `spi`, `i2c1`, or `i2c_arm`.
# - Keep peripheral enablement explicit via DTO overlays and DTS changes.
# - Do not append `dtparam=spi=on` here; it is ignored on this path and adds
#   early-boot noise.
RPI_EXTRA_CONFIG:append = "${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672', '1', '\\ndtoverlay=%s\\n' % d.getVar('IOTGW_TPM_DTO_OVERLAY'), '', d)}"

# Optional BTF/CO-RE lab kernel metadata gate. Kept separate from generic
# observability so profiles can choose one or both without coupling.
IOTGW_ENABLE_BTF_CORE_DEV ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_BTF_CORE_DEV', '1', ' igw_btf_core_dev', '', d)}"

# Optional dev TPM/LUKS loopback store (/data/encstore). Keep opt-in to avoid
# boot-time/setup overhead on images where encrypted-store testing is not active.
IOTGW_ENABLE_ENCRYPTED_STORE_DEV ?= "0"

# Raspberry Pi 5 DTB policy by kernel provider:
# - Default to Model B only (smallest artifact set for rpi5 deployments).
# - Enable CM5 DTBs explicitly when building a shared/fleet image.
# - mainline bring-up providers currently ship only the rpi-5-b DTB.
IOTGW_RPI5_INCLUDE_CM5_DTBS ?= "0"
IOTGW_RPI5_KERNEL_DTBS_DEFAULT ?= "broadcom/bcm2712-rpi-5-b.dtb"
IOTGW_RPI5_KERNEL_DTBS_DEFAULT:append = "${@bb.utils.contains('IOTGW_RPI5_INCLUDE_CM5_DTBS', '1', ' broadcom/bcm2712-rpi-cm5-cm5io.dtb broadcom/bcm2712-rpi-cm5-cm4io.dtb broadcom/bcm2712-rpi-cm5l-cm5io.dtb broadcom/bcm2712-rpi-cm5l-cm4io.dtb', '', d)}"
IOTGW_RPI5_KERNEL_DTBS_MAINLINE ?= "broadcom/bcm2712-rpi-5-b.dtb"

# linux-iotgw-mainline-fit is the only kernel provider; it ships only the
# rpi-5-b DTB and none of meta-raspberrypi's overlay dtbo set.
RPI_KERNEL_DEVICETREE:raspberrypi5 = "${IOTGW_RPI5_KERNEL_DTBS_MAINLINE}"
RPI_KERNEL_DEVICETREE_OVERLAYS:raspberrypi5 = ""
