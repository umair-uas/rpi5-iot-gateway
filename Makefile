.PHONY: help base dev prod \
        bundle-dev-full-fit sign-bootfiles-fit-yk sign-bootfiles-fit-softhsm bundle-dev-full-fit-resign bundle-prod-full-fit bundle-prod-full-fit-resign \
        tools-venv test-sign-fit test-sign-fit-softhsm test-sbom-cve \
        sbom-cve cve-report sbom-report layers parse clean-lock hooks

KAS ?= kas

# === Shared-layer build mechanism (git-alternates; see kas/local.yml.example) ===
# KAS_REPO_REF_DIR points at a shared bare-repo cache scoped per Yocto release
# (layers-wrynose). kas clones each layer into .kas/ (gitignored) using those
# repos as git alternates — near-instant setup, zero extra disk, and the SHA
# pins in rpi5.yml/kas/*.yml are still enforced. A mirror missing from the
# ref-dir is auto-created on first use; an absent ref-dir falls back to full
# clones (no error). KAS_WORK_DIR keeps upstream layer clones out of the repo
# root; KAS_BUILD_DIR keeps the bitbake build dir at the conventional ./build.
# KAS_REPO_REF_DIR is an optional shared layer cache (git alternates) — it is
# host-specific, so it is NOT committed. Set it in the gitignored
# scripts/env.local.sh (direnv/.envrc exports it into this make invocation),
# or export it yourself. Unset => kas does full clones (correct, just slower).
KAS_REPO_REF_DIR ?=
KAS_WORK_DIR     ?= $(CURDIR)/.kas
KAS_BUILD_DIR    ?= $(CURDIR)/build
export KAS_WORK_DIR KAS_BUILD_DIR
ifneq ($(strip $(KAS_REPO_REF_DIR)),)
export KAS_REPO_REF_DIR
endif

RAUC ?= kas/rauc.yml
LOCAL ?= kas/local.yml
UBOOT_PROD_HARDENING_KAS ?= kas/uboot-prod-hardening.yml
FIT_RELEASE_TRUST_KAS ?= kas/fit-release-trust.yml
# SBOM/CVE reporting overlay + the image it scans (see the `sbom-cve` target)
CVE_KAS ?= kas/cve.yml
SBOM_CVE_IMAGE ?= iot-gw-image-dev
# Default to RAUC builds always; prefer local RAUC config if present
BASE ?= $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

# Export optional toggles so users can do:
#   IOTGW_ENABLE_OTBR=1 make dev|prod|bundle-*
export IOTGW_ENABLE_OTBR
export IOTGW_ENABLE_CONTAINERS
export IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
export IOTGW_ENABLE_BTF_CORE_DEV
export IOTGW_ENABLE_DEEPX_DXM1

# kas refuses to run if KAS_WORK_DIR is absent (it does not mkdir it). Order-only
# prereq so every kas-invoking target creates .kas/ on demand, while
# help / tools-venv / test / clean-lock touch nothing on a fresh tree.
$(KAS_WORK_DIR):
	@mkdir -p $@

help:
	@echo "Targets (RAUC-enabled by default):"
	@echo "  -- Images --"
	@echo "  make dev                          # Developer image"
	@echo "  make prod                         # Production image (WIC intermediate under release-trust)"
	@echo "  make base                         # Base image"
	@echo "  -- Bundles (rootfs + signed FIT boot assets) --"
	@echo "  make bundle-dev-full-fit          # FIT bundle from dev image"
	@echo "  make bundle-dev-full-fit-resign   # Re-assemble dev bundle around HSM-signed FIT (unattended)"
	@echo "  make bundle-prod-full-fit         # FIT bundle from prod image (release trust)"
	@echo "  make bundle-prod-full-fit-resign  # Re-assemble prod bundle around YK-signed FIT [FINAL RELEASE ARTIFACT]"
	@echo "  -- HSM detached signing (operator; PIN/touch) --"
	@echo "  make sign-bootfiles-fit-yk        # Re-sign FIT in deploy tarball on YubiKey (interactive)"
	@echo "  make sign-bootfiles-fit-softhsm   # Re-sign FIT in deploy tarball via SoftHSM (dev only)"
	@echo "  -- Host-side signing env (uv-based) --"
	@echo "  make tools-venv                   # Sync .venv via uv (run once or after dep bumps)"
	@echo "  make test-sign-fit                # Run signing-tool tests (no SoftHSM required)"
	@echo "  make test-sign-fit-softhsm        # Run full suite incl. SoftHSM integration tests"
	@echo "  -- SBOM/CVE --"
	@echo "  make sbom-cve                     # Build dev image with wrynose SBOM+CVE reports"
	@echo "  make cve-report                   # Summarise the CVE report (buckets, kernel split, CVE_STATUS scaffold)"
	@echo "  make sbom-report                  # Summarise the SBOM (license inventory + HIGH-risk review)"
	@echo "  make test-sbom-cve                # Run sbom-cve report/cohort tests (fixtures, no build)"
	@echo "  -- Utilities --"
	@echo "  make hooks                        # Enable the repo git hooks (run once per clone)"
	@echo "  make layers                       # Show layers for RAUC stack"
	@echo "  make parse                        # Parse-only for RAUC stack"
	@echo "  make clean-lock                   # Remove stale bitbake.lock"

# One kas + bitbake invocation for every image / bundle / report target.
# Forwards the IOTGW_ENABLE_* feature toggles into the kas shell env (and
# whitelists them — plus BUNDLE_IMAGE_NAME for bundle targets — for bitbake
# passthrough), then composes the kas overlay chain.
#   $(1) = bitbake invocation       (e.g. "bitbake iot-gw-image-dev",
#                                     "bitbake -C do_configure iot-gw-bundle-full-fit")
#   $(2) = kas overlay chain        (e.g. $(BASE), $(PROD_KAS_OVERLAYS), $(BASE):$(CVE_KAS))
#   $(3) = BUNDLE_IMAGE_NAME value  (optional; empty for plain image / report builds)
define iotgw_bitbake
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS$(if $(3), BUNDLE_IMAGE_NAME) IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV IOTGW_ENABLE_DEEPX_DXM1" \
                   $(if $(3),BUNDLE_IMAGE_NAME=$(3)) IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
                   $(1)' $(2)
endef

PROD_KAS_OVERLAYS = $(BASE)$(if $(wildcard $(UBOOT_PROD_HARDENING_KAS)),:$(UBOOT_PROD_HARDENING_KAS))$(if $(wildcard $(FIT_RELEASE_TRUST_KAS)),:$(FIT_RELEASE_TRUST_KAS))

base: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-image-base,$(BASE))

dev: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-image-dev,$(BASE))

prod: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-image-prod,$(PROD_KAS_OVERLAYS))

bundle-dev-full-fit: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-bundle-full-fit,$(BASE),iot-gw-image-dev)

# Detached HSM signing flow. The build and the HSM-signing step run in
# separate processes — possibly on separate machines — so CI runners
# can drive the unattended steps without ever needing a PIN/touch.
#
# Three stages, each runnable independently:
#
#   Stage 1 — file-key signed build (UNATTENDED, CI-friendly):
#       make bundle-dev-full-fit
#     Produces the deploy tarball and a file-key-signed .raucb. No HSM,
#     no PIN, no touch. Suitable for GitHub Actions, GitLab runners, or
#     any unattended pipeline.
#
#   Stage 2 — re-sign FIT in the deploy tarball (OPERATOR-ONLY):
#       make sign-bootfiles-fit-yk [SIGN_FIT_ARGS='...']
#     Takes the deploy tarball produced by Stage 1 and re-signs the
#     embedded FIT against the PKCS#11 token. Requires PIN entry and a
#     touch on the YubiKey. Only runs on a machine with the HSM
#     physically attached (operator workstation or a hardened signing
#     server). Never runs in CI.
#
#   Stage 3 — re-assemble bundle from signed tarball (UNATTENDED):
#       make bundle-dev-full-fit-resign
#     Re-runs the bundle recipe from do_configure so the assembled
#     .raucb carries the HSM-signed FIT. No HSM interaction. Can run
#     in CI on a runner that has the signed tarball deployed to
#     DEPLOY_DIR_IMAGE (or be invoked locally by the operator after
#     Stage 2).
#
# Typical release pipeline:
#   - CI:        make bundle-dev-full-fit             → publish unsigned artifacts
#   - Operator:  fetch artifacts → make sign-bootfiles-fit-yk → publish signed tarball
#   - CI/Op:     make bundle-dev-full-fit-resign      → publish final signed .raucb
#
# SIGN_BOOTFILES_ARGS  → bootfiles-archive specific flags
#                       (e.g. --force, --archive PATH).
# SIGN_FIT_ARGS        → signing flags (e.g. --verify, --verbose,
#                       --key-name-hint NAME, --uri URI). Defaults to '--verify'.
#                       Both are passed to `sign_fit.py sign-bootfiles`
#                       which now accepts them inline (no '--' separator).
SIGN_BOOTFILES_ARGS ?=
SIGN_FIT_ARGS ?= --verify
UV ?= uv
sign-bootfiles-fit-yk:
	$(UV) run python scripts/fit-signing/sign_fit.py sign-bootfiles --profile yubikey-9a $(SIGN_BOOTFILES_ARGS) $(SIGN_FIT_ARGS)

# Dev signing variant for engineers without a YubiKey. Requires a
# provisioned SoftHSM token holding the iotgw-fit-softhsm-dev keypair;
# see docs/FIT_BOOT_SIGNING.md for the provisioning runbook. Only
# usable against an image that enables IOTGW_FIT_TRUST_SOFTHSM_KEY in
# kas/local.yml — never against a production Image C build.
#
# libsofthsm2 locates its token store via SOFTHSM2_CONF. Default it to the
# in-repo dev token so the target works without a sourced shell env; an
# operator SOFTHSM2_CONF already in the environment still wins.
sign-bootfiles-fit-softhsm: export SOFTHSM2_CONF ?= $(CURDIR)/keys/dev/softhsm/softhsm2.conf
sign-bootfiles-fit-softhsm:
	$(UV) run python scripts/fit-signing/sign_fit.py sign-bootfiles --profile softhsm-dev $(SIGN_BOOTFILES_ARGS) $(SIGN_FIT_ARGS)

# Host-side Python environment (uv-based). Used by the operator signing
# tools and tests; Yocto/BitBake builds do not depend on this venv.
tools-venv:
	$(UV) sync

test-sign-fit:
	$(UV) run pytest scripts/fit-signing/tests/

test-sign-fit-softhsm:
	SOFTHSM_AVAILABLE=1 $(UV) run pytest scripts/fit-signing/tests/

# sbom-cve report/cohort readers: fixture-based tests, no Yocto build required.
# The readers are stdlib-only; only this test suite uses the uv venv.
test-sbom-cve:
	$(UV) run pytest scripts/sbom-cve/tests/

bundle-dev-full-fit-resign: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake -C do_configure iot-gw-bundle-full-fit,$(BASE),iot-gw-image-dev)

# Release bundles. PROD_KAS_OVERLAYS composes kas/fit-release-trust.yml,
# so iot-gw-image-prod builds with the release FIT trust profile
# (YubiKey-only DTB). bundle-prod-full-fit is the release FIT artifact —
# the prod-image equivalent of bundle-dev-full-fit, and the bundle to
# flash for issue #73 on-target validation.
bundle-prod-full-fit: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-bundle-full-fit,$(PROD_KAS_OVERLAYS),iot-gw-image-prod)

# Reassemble the release FIT bundle around an already YubiKey-signed
# bootfiles-fit.tar.gz. Run after `make sign-bootfiles-fit-yk`; re-runs the
# bundle recipe from do_configure so the .raucb picks up the HSM-signed FIT.
# Prod equivalent of bundle-dev-full-fit-resign; keeps PROD_KAS_OVERLAYS so
# kas/fit-release-trust.yml stays active.
bundle-prod-full-fit-resign: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake -C do_configure iot-gw-bundle-full-fit,$(PROD_KAS_OVERLAYS),iot-gw-image-prod)

# SBOM + CVE reporting. Builds SBOM_CVE_IMAGE with the kas/cve.yml overlay
# composed onto BASE, emitting wrynose SPDX SBOM + cve-check reports into the
# deploy dir. Split out from the image/bundle targets because CVE/SBOM report
# generation is slow and should be opt-in, not on every build.
# DX-M1 accelerator development image: composes the DeepX overlay and enables
# the feature. Exists so nobody has to hand-roll a raw kas invocation — passing
# IOTGW_ENABLE_DEEPX_DXM1 as a bare env var to `kas shell` silently does
# nothing, because bitbake filters the environment unless the variable is also
# in BB_ENV_PASSTHROUGH_ADDITIONS (which iotgw_bitbake handles).
#
# Produces a dev image whose kernel and DX-M1 modules come from the SAME build.
# That matters: the module signing key is autogenerated per kernel build, so a
# module is only loadable by the kernel it was built alongside.
DEEPX_KAS ?= kas/deepx.yml
dev-deepx: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake iot-gw-image-dev,$(BASE):$(DEEPX_KAS))

sbom-cve: | $(KAS_WORK_DIR)
	$(call iotgw_bitbake,bitbake $(SBOM_CVE_IMAGE),$(BASE):$(CVE_KAS))

# Host-side report readers over the sbom-cve-check deploy artifacts. Stdlib-only
# Python (no venv), read-only — run after `make sbom-cve` produced the reports.
# Convention: a scan and its image outputs (manifest/testdata/SPDX/CVE JSON)
# share one IMAGE_NAME stem (e.g. iot-gw-image-dev-raspberrypi5.rootfs-<BUILDNAME>)
# and belong together — archive/reference them by that stem. The readers resolve
# the dated file (not the un-dated symlink) and warn when the selected scan is a
# mismatched/incomplete cohort or not the newest build. Pass --strict (fail on a
# broken cohort) and/or --require-latest (fail if a newer image exists), e.g.
# CVE_REPORT_ARGS='--strict --require-latest'.
CVE_REPORT_ARGS  ?=
SBOM_REPORT_ARGS ?=
cve-report:
	python3 scripts/sbom-cve/cve-report.py $(CVE_REPORT_ARGS)
sbom-report:
	python3 scripts/sbom-cve/sbom-report.py $(SBOM_REPORT_ARGS)

layers: | $(KAS_WORK_DIR)
	$(KAS) shell -c 'bitbake-layers show-layers' $(BASE)

parse: | $(KAS_WORK_DIR)
	$(KAS) shell -c 'bitbake -p' $(BASE)

clean-lock:
	rm -f build/bitbake.lock

# The hooks live in scripts/hooks (tracked), but core.hooksPath is per-clone
# local config — a fresh clone has the private-key guard and the commit-msg
# check silently disabled until this runs. Idempotent.
hooks:
	@git config core.hooksPath scripts/hooks
	@echo "core.hooksPath -> scripts/hooks"
	@echo "  pre-commit  : refuse staged private-key / keys/ material"
	@echo "  commit-msg  : enforce the Conventional Commit subject (AGENTS.md)"
