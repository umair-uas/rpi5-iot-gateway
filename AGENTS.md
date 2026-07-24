# AGENTS.md

Canonical orientation for AI coding agents working in this repository. Agent-agnostic — Claude Code, Codex, Cursor, Copilot, etc. Claude-specific extras (skills, MCP servers) live in `CLAUDE.md`.

## What this repo is

A Yocto/OpenEmbedded distribution (`iotgw`) for the Raspberry Pi 5, built with KAS. Produces hardened IoT-gateway images with RAUC A/B OTA, OpenThread Border Router, optional containers/observability/TPM, and a U-Boot FIT boot flow.

- Yocto release: **wrynose** (Yocto 6.0 LTS; colon-based override syntax — see `.claude/rules/yocto-patterns.md`, which applies to any agent regardless of name)
- Target machine: `raspberrypi5` (aarch64, hard-float)
- Distro: `iotgw` (defined in `meta-iot-gateway/conf/distro/`)
- KAS entry point: `rpi5.yml` (base) — composed with overlays in `kas/*.yml`

## Build commands

Everything goes through the `Makefile`, which wraps `kas shell -c bitbake ...` and forwards feature toggles through `BB_ENV_PASSTHROUGH_ADDITIONS`. **Always prefer `make` over raw `kas`/`bitbake`** — the env-passthrough wiring matters.

```bash
make help                # authoritative target catalogue — check before raw bitbake
make dev|prod|base       # image variants (desktop: kas build kas/desktop.yml)
make bundle-dev-full-fit # FIT-format RAUC bundle (file-key signed)
make parse               # bitbake -p (parse-only sanity — cheapest validation)
make layers              # bitbake-layers show-layers
make clean-lock          # remove stale build/bitbake.lock
```

`make help` is the source of truth for the full catalogue (prod bundles, HSM re-signing, signing-tool tests, uv venv). FIT/HSM signing is **operator-driven** (YubiKey PIN+touch, or SoftHSM for YK-less devs) — profiles, tooling (`scripts/fit-signing/sign_fit.py`), and the resign flow are documented in `docs/FIT_BOOT_SIGNING.md`; do not run HSM signing targets unattended. **FIT signed boot is the only flow and is mandatory:** the distro selects the FIT kernel unconditionally and image builds hard-fail (at u-boot `do_configure`, via `iotgw-fit-signing-guard.bbclass`) unless an operator signing key is configured in `kas/local.yml` (file-key, YubiKey, or SoftHSM). Metadata inspection (`make parse`, `bitbake -e`) is not blocked.

Feature toggles (env vars; default off unless an overlay sets them):

```
IOTGW_ENABLE_OTBR
IOTGW_ENABLE_CONTAINERS
IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
IOTGW_ENABLE_OBSERVABILITY
IOTGW_ENABLE_BTF_CORE_DEV
```

Example: `IOTGW_ENABLE_OTBR=1 make bundle-dev-full-fit`.

### KAS composition

The Makefile picks `BASE = kas/local.yml` if present, else `kas/rauc.yml` (RAUC is enabled by default). Other overlays under `kas/` are composed via `:`-separated paths:

- `kas/local.yml` — developer-local secrets/WiFi/RAUC keys and shared cache paths (gitignored; copy from `local.yml.example`)
- `kas/rauc.yml` — RAUC OTA stack
- `kas/otbr.yml`, `kas/containers.yml`, `kas/tpm.yml`, `kas/cve.yml`, `kas/spdx.yml` — feature overlays
- `kas/uboot-prod-hardening.yml` — applied to `prod` and `bundle-prod-full-fit` automatically when present
- `kas/desktop.yml` — desktop image variant

Shared layers are not cloned manually: kas checks them out into the gitignored `.kas/` (`KAS_WORK_DIR`) using bare-mirror alternates from `KAS_REPO_REF_DIR` (an operator-local layer cache set by `scripts/env.sh`), preserving the SHA pins in `rpi5.yml`. `kas/local.yml` supplies the shared `DL_DIR`/`SSTATE_DIR`.

### Standalone `kas` invocations — source the env first

The Makefile exports `KAS_WORK_DIR`/`KAS_BUILD_DIR`/`KAS_REPO_REF_DIR` only to
its own sub-processes. A bare `kas shell …` in any other shell falls back to
kas' default `KAS_WORK_DIR = CWD` and **re-clones the entire upstream layer
stack into the repo root**. When a raw kas call is unavoidable (e.g.
`bitbake -e` variable inspection), source the env in the same command:

```bash
. scripts/env.sh && kas shell -c 'bitbake -e rauc' kas/local.yml
```

Interactive shells get this automatically via `.envrc` (direnv, after a
one-time `direnv allow`). Non-interactive shells — including AI-agent tool
shells, CI steps, and scripts — do **not** trigger direnv and must source
`scripts/env.sh` explicitly or go through `make`. If the accident happens
anyway: the stray root clones are untracked; confirm
`build/conf/bblayers.conf` points at `.kas/` before deleting them.

Build artifacts land in `build/tmp/deploy/images/raspberrypi5/`. Flash the `.wic.zst` with `zstdcat … | dd` — or `bmaptool copy` plus deleting `uboot.env` from the `ubootenv` partition (p2); plain `bmaptool` can leave a stale U-Boot env file on reused cards. Never zero p2 itself — the vfat and its label must survive or the `/uboot-env` mount fails at boot. Full flashing/provisioning runbook: `docs/OPERATIONS.md`.

### Image variants

`iot-gw-image-base | -dev | -prod | -desktop` — recipes live in `meta-iot-gateway/recipes-core/images/`. The `.inc` is shared scaffolding.

### Releases & CI

- Release helper: `scripts/release/release-build.sh` + `scripts/release/release-manifest.sh` — process in `docs/RELEASE.md`
- CI: `.github/workflows/release-hygiene.yml` (release-hygiene lint only — no Yocto builds in CI)
- Changelog assembled in batches before release — do not add an entry for every trivial bump

## Repo layout (orient yourself fast)

```
rpi5.yml                     # KAS base config (layers + machine + distro)
kas/                         # KAS overlays (feature toggles, secrets, desktop, etc.)
Makefile                     # build entry point — use this, not raw kas/bitbake
meta-iot-gateway/            # the custom layer (everything project-specific lives here)
  conf/distro/               # iotgw distro definition
  recipes-bsp/               # u-boot, rpi-eeprom, bootfiles, bootlogo
  recipes-core/images/       # iot-gw-image-{base,dev,prod,desktop}.bb
  recipes-kernel/            # linux-iotgw* recipes, kernel fragments, bpftool
  recipes-ota/               # rauc, bundles, ota-updater, ota-certs, ota-user
  recipes-connectivity/      # mosquitto, openssh, otbr (custom OTBR overlay)
  recipes-containers/        # podman/buildah/skopeo wiring
  recipes-observability/     # logging/metrics
  recipes-security/          # nftables, apparmor, hardening bits
  recipes-support/           # misc project utilities
  files/wic/                 # partition layouts (RAUC A/B WKS variants)
docs/                        # OPERATIONS, SECURITY, KERNEL, PARTITIONS, RAUC_UPDATE,
                             #   OTBR, FIT_BOOT_SIGNING, OVERLAY_RECONCILIATION, …
scripts/                     # host-side tooling (release, OTA bench, signing, TPM utils)
.claude/
  rules/yocto-patterns.md    # wrynose syntax + parser limits + identity/rootfs patterns
  rules/recipe-conventions.md # read before authoring a recipe or shipping a patch
  rules/cross-compilation.md # aarch64-poky-linux SDK notes — read before app cross-builds
  skills/yocto-worktree/     # isolated-worktree workflow for parallel/build-heavy agents
```

## Conventions

- **Colon override syntax (Scarthgap+)** — `RDEPENDS:${PN}`, `do_install:append()`, `SRC_URI:append:raspberrypi5`. Never the deprecated underscore form. See `.claude/rules/yocto-patterns.md`.
- **No hardcoded paths in recipes** — use `${bindir}`, `${sysconfdir}`, `${systemd_system_unitdir}`, etc.
- **Recipe & patch conventions** — HOMEPAGE, patch identity/attribution, `Upstream-Status` taxonomy, `/root` paths, `SYSTEMD_AUTO_ENABLE`, and the sstate patch-header rebuild gotcha live in `.claude/rules/recipe-conventions.md`. Read it before authoring a recipe or shipping a patch.
- **Cross-compile target is aarch64-poky-linux** — `.claude/rules/cross-compilation.md` covers SDK setup, CMake/Rust/Go specifics, and verification commands.
- **Public-repo discipline** — committed files reference only repo-relative paths or public `docs/`; never absolute `/home/<user>/...` paths, device IPs, or home-lab topology. Operator-local material goes in `kas/local.yml` / `scripts/env.sh`-managed locations (gitignored).
- **Commit style**: `<type>(<scope>): <subject>` — imperative, lowercase, no period. Types: `feat|fix|docs|refactor|test|chore`. No `Co-Authored-By` or other trailers.
- **Branch naming**: `<type>-<scope>-<subject>`, matching commit style (e.g. `feat-rauc-pki-yubikey-stage1`).
- **PR scope**: bundle trivial recipe/version bumps into a related feature PR rather than landing them standalone.
- **Don't write CHANGELOG entries for trivial bumps** — changelog is assembled in batches before a release.

## Working economically

- Inspect narrowly before scanning broadly — a recipe name or `bitbake-getvar` beats a repo-wide grep.
- Validate progressively: `make parse` → the affected recipe's task → image build. Don't launch a full image build to test a parse-level change.
- On build failure, extract the **first causal error** from the task log and cite log files by path (`build/tmp/work/.../temp/log.do_*`); don't paste whole BitBake logs into the conversation.
- Don't re-run an equivalent failing command hoping for a different result — change one variable per retry.
- No speculative adjacent refactors; keep the diff scoped to the request.
- Subagents and isolated worktrees only when parallelism or build pollution justifies the cost (Claude: `yocto-worktree` skill).
- Stop at the requested milestone; report remaining work instead of continuing unprompted.

## Where detailed guidance lives

| Task | Read |
|---|---|
| Authoring recipes / shipping patches | `.claude/rules/recipe-conventions.md` |
| Yocto syntax, parser limits, identity/rootfs patterns | `.claude/rules/yocto-patterns.md` |
| Cross-compiling apps outside bitbake | `.claude/rules/cross-compilation.md` |
| FIT boot signing, HSM/YubiKey/SoftHSM | `docs/FIT_BOOT_SIGNING.md` |
| Flashing, provisioning, target ops, SSH-namespace caveat | `docs/OPERATIONS.md` |
| RAUC OTA install/rollback | `docs/RAUC_UPDATE.md`, `docs/OTA_UPDATE.md` |
| Kernel config / CVE & driver backports | `docs/KERNEL.md`, `docs/KERNEL_CVE_PATCH.md`, `docs/KERNEL_DRIVER_BACKPORT.md` |
| SBOM / CVE scanning, reading reports, userspace triage | `docs/SBOM_CVE.md` |
| Release workflow | `docs/RELEASE.md` |
| Partition layouts | `docs/PARTITIONS.md` |

One operational warning worth carrying everywhere: on running targets, an interactive SSH shell may sit in a service-hardening mount namespace where `/etc` looks read-only while PID1 sees it read-write — do **not** diagnose overlayfs as broken from an SSH-only check. Verification commands: `docs/OPERATIONS.md` §10.
