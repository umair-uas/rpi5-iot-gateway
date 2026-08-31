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
  skills/devtool-workflow/   # devtool modify→finish cycle, patch export + verification
  skills/yocto-worktree/     # isolated-worktree workflow for parallel/build-heavy agents
```

## Conventions

- **Colon override syntax (Scarthgap+)** — `RDEPENDS:${PN}`, `do_install:append()`, `SRC_URI:append:raspberrypi5`. Never the deprecated underscore form. See `.claude/rules/yocto-patterns.md`.
- **No hardcoded paths in recipes** — use `${bindir}`, `${sysconfdir}`, `${systemd_system_unitdir}`, etc.
- **Recipe & patch conventions** — HOMEPAGE, patch identity/attribution, `Upstream-Status` taxonomy, `/root` paths, `SYSTEMD_AUTO_ENABLE`, and the sstate patch-header rebuild gotcha live in `.claude/rules/recipe-conventions.md`. Read it before authoring a recipe or shipping a patch.
- **Cross-compile target is aarch64-poky-linux** — `.claude/rules/cross-compilation.md` covers SDK setup, CMake/Rust/Go specifics, and verification commands.
- **Public-repo discipline** — committed files reference only repo-relative paths or public `docs/`; never absolute `/home/<user>/...` paths, device IPs, or home-lab topology. Operator-local material goes in `kas/local.yml` / `scripts/env.sh`-managed locations (gitignored).
- **Commit style**: `<type>(<scope>): <subject>` — imperative, no period. Types: `feat|fix|docs|refactor|test|chore|build|ci|perf|style|revert` — the set `cliff.toml` parses; anything else lands in the changelog's "Other" bucket. Scopes may be hyphenated (`ota-certs`, `sbom-cve`) or comma-composed (`fit,uboot`). Enforced by the `commit-msg` hook. Prefer a lowercase subject, but leading initialisms (`CVE`, `FIT`, `TPM`) are fine and the hook does not block them. AI-assisted commits carry attribution trailers — see §"AI attribution in commits".
- **Branch naming**: `<type>-<scope>-<subject>`, matching commit style (e.g. `feat-rauc-pki-yubikey-stage1`).
- **PR scope**: bundle trivial recipe/version bumps into a related feature PR rather than landing them standalone.
- **Don't write CHANGELOG entries for trivial bumps** — changelog is assembled in batches before a release.

## Git hooks

Tracked in `scripts/hooks/`, activated per clone by `core.hooksPath`:

```bash
make hooks     # run once after cloning; idempotent
```

- `pre-commit` — refuses staged private-key material and anything under
  `keys/`. Defense-in-depth over `.gitignore`, which does not stop
  `git add -f` or a `git mv` into `keys/`. Checks renames too.
- `commit-msg` — enforces the Conventional Commit subject above, so the
  git-cliff release notes stay parseable. Merge/revert/fixup subjects
  pass through untouched.

`core.hooksPath` is local config, not a tracked file: a fresh clone has
**both hooks silently disabled** until `make hooks` runs. Neither hook is
a security control on its own — CI and review still are. Escape hatch for
a hook you are certain is wrong: `git commit --no-verify`.

## AI attribution in commits

Every commit an agent contributed to ends with an `Assisted-by:` trailer naming
the tool and the **exact model that did the work**:

```
Assisted-by: <tool>:<model-id>
```

Tool names in use: `claude-code`, `codex`, `kiro`. The model id half is
deliberately shown as a placeholder here and nowhere spelled out — see the first
rule below.

- **Never copy a model id out of this file, `CLAUDE.md`, or a past commit.**
  State the model the session is actually running as. A doc-pinned model string
  goes stale the moment the next release ships, and every agent that copies it
  writes a trailer that is quietly false.
- **One trailer per model that touched the change, in the order they touched
  it.** If Sonnet drafted and Opus later reviewed and amended, both lines stay.
  That is the whole point: a later reader — human or model — can see which model
  produced the original reasoning and which one revised it.
- **Never drop an earlier agent's trailer when amending.** The trailer records
  participation, not the largest share.
- Attribution is not certification. The operator remains the commit author and
  is responsible for having reviewed what the agent produced.

**Patches are not commits.** Shipped `.patch` files carry their own headers
and their own rules — including the hard rule that a `Backport` patch's header
is never touched. See `.claude/rules/recipe-conventions.md` §"AI attribution in
patch headers" before adding a trailer to anything under `files/`.

Rationale: this repo previously banned trailers. That was reversed because
provenance turned out to matter more than terse messages — commits originate
from several tools (Claude Code, Codex), and knowing which model reasoned about
a change is what makes a later review of it auditable.

## Validating behaviour changes

A green build and an approving review are not evidence. Both are produced by
reasoning over the same artifact with the same blind spots — an agent reviewing an
agent's change converges on *plausible*, not *correct*. Before claiming a change is
right, produce a check whose answer comes from something other than a model.

Applies to any change that decides something about real inputs:

- matching, filtering or classifying logic — parsers, regexes, globs, version
  comparisons, dedupe/merge rules
- security metadata that suppresses findings — `CVE_STATUS` dispositions, VEX
  claims, exclusion lists. These fail **silently**: a wrong entry removes a CVE from
  the report instead of turning something red, and downstream tooling that trusts
  `CVE_STATUS` inherits the mistake.
- anything whose failure mode is "the output looks fine but something is missing"

Ranked by what the evidence is worth:

1. **Differential run** — keep the old behaviour beside the new, run both over real
   data, diff the outputs. Every disagreement is a change you must be able to
   explain. Check **both** directions: what stopped matching, and what started.
2. **Per-claim verification against an independent source** — for metadata
   dispositions, check each claim (shipped version vs fixed boundary, product
   mismatch) against upstream CVE data, *not* against the scanner that produced the
   finding. What may suppress a finding and what may only deprioritise it:
   `docs/CVE_APPLICABILITY.md`; where each kind of statement is authored:
   `docs/SBOM_CVE.md`.
3. **On-target validation** — for runtime behaviour the board is the oracle.
4. A build, lint run, or test suite — necessary, but only covers what someone
   already thought of.

What makes it actually work:

- **Classify the whole delta, not the top N.** The tail is where the wrong ones hide.
- **Isolate the variable** — set local changes aside and re-measure the raw baseline
  first, so the delta is attributable to the change and not to image drift.
- **State which axis is clean** when the underlying data drifts, rather than quoting
  a total that mixes signal with feed noise.
- **Keep the commands re-runnable** and logged next to the work, so the numbers can
  be reproduced instead of believed.
- **Put the result in the commit body** — what was run, what it showed. When a claim
  could not be verified, say so plainly. "Unverified" is a valid state; a confident
  sentence covering for one is not.

## Working economically

- Inspect narrowly before scanning broadly — a recipe name or `bitbake-getvar` beats a repo-wide grep.
- Validate progressively: `make parse` → the affected recipe's task → image build. Don't launch a full image build to test a parse-level change.
- On build failure, extract the **first causal error** from the task log and cite log files by path (`build/tmp/work/.../temp/log.do_*`); don't paste whole BitBake logs into the conversation.
- Don't re-run an equivalent failing command hoping for a different result — change one variable per retry.
- No speculative adjacent refactors; keep the diff scoped to the request.
- Subagents and isolated worktrees only when parallelism or build pollution justifies the cost (Claude: `yocto-worktree` skill).
- **Long-running builds (>~10 min): launch detached, never via the agent harness's background-process mechanism.** A harness-spawned background process stays a child of the agent's tool runner and dies with it — the build gets SIGTERM'd mid-task (`make` exits 241 with no bitbake `ERROR:` lines, which reads like a mystery failure). Instead, from an ordinary foreground shell call:

  ```bash
  setsid nohup make <target> > scratch/<topic>.log 2>&1 &
  ```

  `setsid` gives the job its own session; once the launching shell exits it reparents to the init/user manager and nothing in the agent's process tree can signal it. Watch progress with a **separate** poller that only reads the log file — decouple the watcher from the work, so a killed poller is just re-armed while the build survives. For builds that matter, prefer handing the operator the one-liner to run in their own shell. A killed build is recoverable either way (bitbake resumes from sstate), but the detached form avoids the wasted hours and the misleading failure mode.
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
| DEEPX DX-M1 accelerator: build gates, module signing, device policy | `docs/DEEPX_DXM1.md` |
| AI accelerators — new to the domain, vocabulary, the host/target model | `docs/AI_ACCELERATION_101.md` |
| AI accelerators — pipeline diagram, what's built by whom, extending to a second vendor | `docs/AI_ACCELERATION_ARCHITECTURE.md` |
| Deciding whether a CVE applies: stages, evidence, what may suppress | `docs/CVE_APPLICABILITY.md` |
| Kernel applicability — build-object oracle, CNA re-derivation, the compiled-source blind spot | `docs/KERNEL_CVE_APPLICABILITY.md` |
| Release workflow | `docs/RELEASE.md` |
| Partition layouts | `docs/PARTITIONS.md` |

One operational warning worth carrying everywhere: on running targets, an interactive SSH shell may sit in a service-hardening mount namespace where `/etc` looks read-only while PID1 sees it read-write — do **not** diagnose overlayfs as broken from an SSH-only check. Verification commands: `docs/OPERATIONS.md` §10.
