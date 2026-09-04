# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-09-04

Adds a DEEPX DX-M1 NPU accelerator stack and a desktop lab image that runs
on-screen inference, plus a persistent kernel module-signing key.

**Read this before deploying anything from this release.** The accelerator and
module-signing work is validated on hardware but is explicitly *not*
production-complete. Specifically:

- The module-signing key is a plain file on the build host with **no hardware
  protection**. It is appropriate for development and lab images. A production
  key belongs in the same HSM/YubiKey handling as the FIT signing key.
- The kernel/module pairing guard in `bundle-hooks-fit.sh` is **fail-open** when
  a bundle carries no bootfiles archive, so a mismatch is not caught.
  **Rootfs-only OTA is unsupported for DX-M1; use full-FIT bundles.**
- SELinux domains for the accelerator remain **permissive**. Acceptance records
  denials as findings, not failures.
- `iot-gw-image-desktop` is a lab/bench variant: **not hardened, not for
  shipping.** It accepts commercial-flagged codecs and ships developer tooling.
- **Production FIT release images cannot currently be produced.** The
  release-trust profile trusts only the YubiKey FIT key, and that key material
  is not currently available, so `bundle-prod-full-fit-resign` cannot run. The
  build guard catches this and warns that the produced prod `.wic.zst` is not a
  release artifact and is known-unbootable for initial SD flash. Base, dev and
  desktop images and the dev OTA path are unaffected. Re-establishing the
  signing trust anchor is prerequisite to any production release.
- Accelerator firmware is upgraded out of band. This layer ships no firmware
  payload, updater, rollback or fleet policy.

### Added
- DEEPX DX-M1 accelerator integration: out-of-tree `dx-driver`, the DX-RT
  runtime under an unprivileged `dxrt` service account, and a device policy for
  `/dev/dxrt*`. The BCM2712 PCIe host bridge is built in rather than modular so
  the bridge cannot probe after the driver has looked for its device.
- Desktop lab image with the DX-Stream GStreamer elements
  (`dxpreprocess`/`dxinfer`/`dxpostprocess`/`dxosd`) rendering to Weston over
  HDMI, including the H.264 software decode path the demo payload requires.
- Persistent kernel module-signing key, opt-in via `IOTGW_MODULE_SIG_KEY_FILE`.
  Without it Kbuild auto-generates a throwaway key per kernel build, so modules
  built against one kernel cannot load on the next. See docs/KERNEL.md.
- On-target DX-M1 acceptance suite producing evidence from the board rather than
  from build metadata: module identity and signature, PCIe binding, device
  policy, daemon identity, SELinux denials, and an inference run with a
  CPU-fallback discriminator.
- Documentation: DX-M1 field guide, AI-acceleration primers, a module-signing
  runbook, and a boundary section on what can and cannot be taken from a newer
  vendor suite checkout.

### Changed
- The headless dev image takes the base accelerator packagegroup rather than the
  demo one; DX-Stream needs a Wayland compositor the headless profile does not
  have.
- The Xwayland server is no longer built for the desktop image. `weston-init`
  derived it from `DISTRO_FEATURES` and injected `xwayland=true` above the
  configured `xwayland=false`, so an X server shipped in an image whose own
  configuration forbade it.
- Disk-space guards raised from poky's 1G/100M defaults, which only fire once a
  build has already filled the disk.

### Fixed
- Weston could not start on this distro at all (`status=224/PAM`). Accounts
  created during rootfs assembly inherit `PASS_MAX_DAYS` from the hardened
  `login.defs` and reproducible builds pin `lastchg` to the epoch, so the
  compositor's account was born expired and PAM refused the session permanently.
- `root`'s shadow entry shipped already expired by the same mechanism. The
  exemption is scoped to root's `/etc/shadow` entry, not to `login.defs`, so the
  hardening posture and all later accounts are unchanged.
- The screen blanked mid-demo: `idle-time` was set in an `[idle]` section, which
  Weston does not have, so the key was ignored and the 300s default applied.
- `/etc/gshadow` drifted out of sync with supplementary group writes.

## [0.5.0] - 2026-07-15

Migration from scarthgap to wrynose (Yocto 6.0 LTS). This is a reflash, not an
OTA — the RAUC compatible string does not guard the release-track jump.

### Added
- Yocto 6.0 LTS (wrynose) base: U-Boot 2026.01, mainline kernel 6.18.37,
  systemd 259, GCC 15.2. Layers are SHA-pinned and checked out by kas into a
  gitignored `.kas/` via bare-mirror alternates.
- Signed FIT-only boot (split model): a plain kernel image plus a separate FIT
  assembly/signing recipe; U-Boot boots the FIT's signed `default` config, and
  the config name is removed from the environment and OTA hooks. Three signing
  paths validated end-to-end — build-time file key, SoftHSM, and YubiKey
  (PIN+touch), including on-target boot of a YubiKey-signed FIT.
- OTA U-Boot env self-heal: a bundle install reconciles the boot-critical env
  vars from a canonical `uboot-env.txt` it ships, so an OTA that changes the
  kernel boots the correct per-slot FIT without a manual env reset (production
  is already immune via `CONFIG_ENV_WRITEABLE_LIST`).
- Host-side target-checks runner (`scripts/run-target-checks.sh`) that drives
  the on-target smoke/check scripts over SSH.
- Additive SBOM/CVE overlay (`kas/cve.yml`) gated by `IOTGW_CREATE_SPDX_DISABLE`.

### Changed
- systemd-networkd replaces NetworkManager (br0 bridge + wlan0 via
  `wpa_supplicant@`, systemd-resolved); provisioning drop-ins move to
  `/data/iotgw/{network,wpa}`.
- Containers enabled: podman/crun/netavark/aardvark-dns from
  meta-virtualization, nftables firewall driver, persistent graphroot on `/data`.
- Host tooling reorganized under `scripts/` by subsystem; FIT signing is driven
  by `scripts/fit-signing/sign_fit.py`.
- Wi-Fi association MAC defaults to the permanent hardware MAC (stable across
  reboots for a fixed appliance) instead of per-association randomization.
- `IOTGW_WIFI_IFACE` is now a single source of truth in `iotgw-common.inc`,
  consumed by network-units, hardening, and the RAUC managed-path.
- `scripts/release/release-manifest.sh` auto-detects the Yocto deploy directory
  instead of hardcoding it, and records `deploy_root` for traceability
  (override with `IOTGW_DEPLOY_ROOT`).

### Fixed
- U-Boot A/B failover: a slot whose partition-UUID lookup fails now marks itself
  non-bootable and fails over to the other slot instead of looping forever (the
  attempt-counter decrement is persisted before reset).
- FIT signing: every configuration signature node must be signed, not just one;
  verification and the already-signed check match by key-name-hint so non-default
  hash/signature algorithms are not rejected.

### Removed
- The non-FIT bundle path (bundle recipes, hook, and bootfiles archive) and the
  corresponding Make targets — FIT signed boot is the only flow.
- Layers meta-security, meta-lts-mixins, and meta-rust-bin; meta-rauc-community
  is absorbed into meta-iot-gateway.

## [0.4.0] - 2026-05-09

### Added
- U-Boot hardening framework with feature-gated posture tokens:
  `surface_reduce`, `fit_enforce`, `appliance_lockdown`.
- Production U-Boot lockdown profile with env write allowlist and
  force-bypass blocking (`CONFIG_ENV_ACCESS_IGNORE_FORCE=y`).
- Production build guard for U-Boot FIT signing key policy
  (`iotgw-uboot-prod-key-guard.bbclass`).
- Optional crash-debug kernel profile (`IOTGW_ENABLE_CRASH_DEBUG_DEV`) layered
  on pstore persistence for deterministic reboot-on-oops/panic lab workflows.
- Optional dedicated kernel BTF/CO-RE metadata lane
  (`IOTGW_ENABLE_BTF_CORE_DEV` -> `igw_btf_core_dev`) with
  `pahole-native` dependency gating.
- U-Boot defconfig patch raising `CONFIG_SYS_BOOTM_LEN=0x8000000` for larger
  FIT kernel decompression envelopes.
- LSM/IMA feature gates and RPi EEPROM/VCIO integration switches.
- OTA/RAUC PKCS#11 and encrypted-bundle feature-gated plumbing.
- Release tooling: `docs/RELEASE.md`, `scripts/release/release-build.sh`,
  `scripts/release/release-manifest.sh`, and a `release-hygiene` GitHub Actions
  workflow running `shellcheck` on tracked scripts and `yamllint`
  (config: `.yamllint`) on tracked kas configs and workflows, plus
  changelog/version-variable sanity gates.

### Changed
- RAUC install/reconcile flow hardened; clean `fstab` preservation improved.
- OTA updater/cert runtime behavior gated with shared OTA user model.
- U-Boot `iotgw_set_bootargs` now honors `EXTRA_KERNEL_ARGS`; provisioning
  automation applies boot policy (`IOTGW_UBOOT_BOOTDELAY`,
  `IOTGW_UBOOT_EXTRA_KERNEL_ARGS`) with lockdown-aware behavior.
- Recovery kernel feature set alignment tightened by removing unconditional
  observability-dev coupling.
- Telegraf startup now gates on non-empty credential files.
- RAUC environment handling tightened with enforced `/etc/fw_env.config`
  via overlay reconciliation.

### Fixed
- OTA updater key/cert preflight sequencing and key-option initialization fixes.
- OTA polling TPM updater gating and preflight behavior fixes.
- OTA cert provisioning behavior decoupled from PKCS#11 readiness checks.
- `tpm2` packaging/runtime fixes for offline `pytss` build and PKCS#11 tools.
- Corrected patch metadata author attribution in `otbr-socket-dir.patch`.

### Documentation
- Added/expanded U-Boot hardening architecture reference.
- OTA/RAUC docs refactored and provisioning script guidance updated.
- Kernel driver backport field guide added.
- U-Boot hardening and kernel configuration references updated for current
  bootargs policy automation, `SYS_BOOTM_LEN` rationale, and
  `igw_btf_core_dev` semantics.

## [0.3.1] - 2026-04-08

### Changed
- Release metadata alignment:
  - distro default version bumped to `igw.0.3.0` in `iotgw-common.inc`
  - build documentation release override example updated to `0.3.0`
- `v0.3.0` changelog entry amended to include observability stack rollout notes
  (`influxdb`, `telegraf`, `mosquitto`).

## [0.3.0] - 2026-04-08

### Added
- U-Boot bootstage userspace collector service (`iotgw-bootstage`) with structured logging and environment export.
- Stable RAUC slot udev links (`/dev/disk/by-rauc-slot/*`) for early boot partition resolution.
- Native observability service stack integration for gateway telemetry:
  - InfluxDB
  - Telegraf
  - Mosquitto

### Changed
- Raspberry Pi 5 U-Boot boot path optimized for appliance flow with script-first behavior.
- U-Boot boot interaction refined to a 2s keyed stop string (`igw`) with image-variant bootdelay policy.
- U-Boot diagnostics expanded with stage markers and bootstage reporting path for fleet timing analysis.
- Startup critical path improved by removing `udev-settle` dependency from `rauc-grow-data-partition`.
- Network boot wait behavior hardened by masking `NetworkManager-wait-online` at rootfs build time.
- Systemd preset installation path corrected to `${libdir}/systemd/system-preset` for deterministic application during image build.
- Observability provisioning and OTA reconciliation flow hardened for native services and credential paths.

### Fixed
- Resolved RPi5 U-Boot init/probe regressions encountered during EFI/video/DM path tuning.
- Audit rule deployment moved away from fragile `pkg_postinst` flow to deterministic rootfs deployment.
- AArch64 audit rule compatibility fixed (invalid syscall usage removed), with reliable `augenrules` load.
- File/dir audit monitoring switched to watch-form rules for stable boot-time rule activation.
- `devel` account password aging policy adjusted to avoid forced expiry lockouts on first login after OTA.
- Overlay reconcile policy updated to enforce `/etc/login.defs` consistency across slot switches.

### Security
- Login policy hardening moved to `shadow` package build-time patching (`/etc/login.defs`) for OTA-consistent behavior.
- Audit policy profile clarified with image-profile lock mode handling (`-e 1` dev/base, stricter prod policy support).

### Documentation
- Security documentation updated for current audit rules path and Lynis baseline workflow.
- Partition documentation updated for current grow-data detection/stamp behavior.

## [0.2.0] - 2026-04-01

### Added
- TPM 2.0 (Infineon SLB9672) integration with build-time gating across kernel/device-tree/userspace packaging.
- FIT recovery-kernel flow for signed multi-config boot updates.
- Rootfs-only dev bundle target for faster OTA iteration (`bundle-dev` path).

### Changed
- FIT custom ITS flow expanded to dual-kernel + dual-config policy (`conf-primary`/`conf-recovery`).
- OTA cert provisioning and RAUC install wrapper flow reconciled for HTTPS-driven installs.
- WIC/OTA layout moved to 128G default with 16G A/B rootfs slots and hardened streaming preflight behavior.

### Fixed
- Raspberry Pi 5 RTC support backported behind build-time gate (`IOTGW_ENABLE_RPI_RTC`).
- U-Boot boot path adjusted to skip unused EFI boot method probes for this product flow.

### Documentation
- Security and FIT signing documentation refreshed for current runtime policy and operator workflow.
- OTA follow-up notes and repository references aligned with merged implementation state.

## [0.1.0] - 2026-03-04

### Added
- Mainline Linux `6.18` integration and FIT bundle flow for Raspberry Pi 5.
- Signed FIT boot path support with runtime verification plumbing and key injection flow.
- RAUC bundle-hook bootfiles update path with U-Boot environment tracking.
- RAUC HTTPS streaming support in system config, including TLS paths and operator runbook coverage.
- OTA updater service/timer and OTA certificate provisioning pipeline with dev-CA support.
- Dedicated `uboot-env` partition support and RAUC slot/layout handling updates.
- Adaptive OTA slot-alignment build validation gate for rootfs slots.
- Deterministic RAUC streaming preflight stages with TLS profile selection (`system`/`data`).
- RAUC D-Bus integration across updater, manual wrapper, and banner observability.
- Persistent machine-id flow for immutable rootfs (`/data/machine-id` -> `/etc/machine-id`) with consumer fallbacks.
- OTBR host integration improvements, including hardened services, system user setup, telemetry flags, and `iotgw-otbrctl`.
- OTBR web UI integration and default/network policy gating by `IOTGW_ENABLE_OTBR`.
- Edge monitoring integration (`edge-healthd`) with packagegroup gating and refactor to `.inc + versioned .bb`.
- Platform support additions for container-host tuning and mosquitto security integration.

### Changed
- Build workflow expanded with FIT-focused bundle targets (`bundle-dev-full-fit`, `bundle-base-full-fit-fast`).
- OTA cert trust source aligned to a single CA source-of-truth with runtime chain validation.
- RAUC config recipe selection hardened to avoid filename and `FILESPATH` collisions.
- `iotgw-rauc-install` execution model hardened under `systemd-run` with explicit transient unit controls.
- Wrapper audit behavior improved with dispatch profile and writable-path assumption logs.
- Image defaults updated to mask legacy `vconsole` and legacy `rauc-mark-good` behavior in favor of updated flow.
- Packagegroups and image composition updated for OTA dependencies and developer tooling.

### Fixed
- First-boot bootargs regression that could carry stale static root arguments.
- Post-`uboot-env` follow-up service/image integration issues.
- FIT boot reliability issues around stale bootfiles payload and signed image/runtime DTB consistency.
- U-Boot FIT hash verification compatibility (`sha256`) path.
- OTA overlay reconciliation reliability in slot hooks (`pre-install`/`post-install`) and migration behavior.
- OTBR web UI regressions (missing frontend assets, tested defaults, nft init behavior).
- SSH per-connection hardening side effect that blocked expected sudo usage.
- Build/QA issues in OTBR path (including buildpath QA and telemetry enablement).

### Security
- Broader service hardening and sandboxing coverage (systemd hardening drop-ins, namespace controls).
- NVMe module loading restrictions and related hardening updates.
- RAUC/manual install-path hardening for namespace-constrained contexts.
- OTA/update-path reliability hardening to reduce unsafe manual recovery scenarios.
- Firewall rule gating improvements for OTBR-enabled deployments.

### Documentation
- Expanded runbooks for build, security, partitions, RAUC OTA, FIT signing, and OTBR operation.
- Added adaptive OTA benchmark and troubleshooting guidance for field validation.
- Added HTTPS streaming OTA notes and refreshed operational docs for build/partition/security flows.

[Unreleased]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/umair-as/rpi5-iot-gateway/releases/tag/v0.1.0
