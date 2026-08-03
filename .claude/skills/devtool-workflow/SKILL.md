---
name: devtool-workflow
description: "Modify, build, and export patches for a recipe in meta-iot-gateway using devtool. Use when iterating on recipe source (U-Boot, kernel, app) instead of hand-editing patch files. Covers modify, build, commit, finish, and patch verification on Yocto 6.0 wrynose."
metadata:
  argument-hint: "<recipe-name> [modify|build|finish|reset]"
allowed-tools: "Read, Edit, Grep, Glob, Bash(. scripts/env.sh*), Bash(kas *), Bash(bitbake*), Bash(devtool *), Bash(git *), Bash(make *), Bash(find *), Bash(ls *)"
---

# devtool workflow (rpi5-iot-gw)

Read `.claude/rules/recipe-conventions.md` first — patch identity,
`Upstream-Status` taxonomy, and the sstate patch-header rebuild cost all
apply to every patch this workflow emits.

## Wrynose changed how devtool handles local files

**`oe-local-files` no longer exists.** It was removed upstream in
OE-Core `ce8190c5190` ("devtool: Drop oe-local-files and simplify",
2024-05-01) — after scarthgap, so it is gone in wrynose. Guidance
written for scarthgap or earlier (including older versions of this
skill) is wrong on this point.

Do **not** look for `build/workspace/sources/<recipe>/oe-local-files/`.
It is never created. Its absence means nothing and destroys nothing.
The old "devtool reads that directory as the file list, so an absent
directory means delete them from the layer" failure mode disappeared
with the `_ls_tree` code path that caused it.

What `devtool finish` does now (`_export_local_files` in
`scripts/lib/devtool/standard.py`):

- **Committed** changes in the workspace source tree → extracted as
  numbered `.patch` files into the layer.
- **Uncommitted but tracked** changes (literally `git status
  --porcelain`, untracked `??` entries excluded) → classified against
  the recipe's non-patch `file://` list and copied directly over the
  files in recipe space.

For BSP recipes here (`u-boot`, `linux-iotgw-mainline-fit`) the
workspace source tree is the upstream git checkout. Your layer's `.cfg`
fragments unpack to `UNPACKDIR`, not into that tree, so devtool neither
sees nor rewrites them — **edit fragments directly in the layer**. That
makes "commit everything before finishing" the right habit here, but for
a plain reason: uncommitted work does not become a patch.

## 1. Enter the build environment

There is no `make shell` target in this repo. A bare `kas shell` sets
`KAS_WORK_DIR = CWD` and re-clones the whole upstream layer stack into
the repo root (AGENTS.md, "Standalone `kas` invocations"). Agent shells
do not get direnv. Always source the env in the same command:

```bash
. scripts/env.sh && kas shell kas/local.yml
```

`kas/local.yml` is the Makefile's `BASE` when present; it falls back to
`kas/rauc.yml`.

**U-Boot has a hard signing gate.** `iotgw-fit-signing-guard.bbclass`
fails `u-boot:do_configure` unless an operator signing key is configured
in `kas/local.yml`. `devtool build u-boot` hits this. If you only need
metadata, `make parse` and `bitbake -e` are not blocked.

## 2. Check workspace state

```bash
devtool status
devtool reset <recipe>    # only if you want a clean start
```

## 3. Modify

Conditional `SRC_URI` operations break override-branch handling. Check
first:

```bash
bitbake-getvar -r <recipe> SRC_URI | grep -E '(:append:|:prepend:|:remove:)' || true
```

If any are present, or a previous `devtool modify` complained about
override branches:

```bash
devtool modify --no-overrides <recipe>     # -O
```

Otherwise `devtool modify <recipe>`.

This is not cosmetic: `_export_local_files` returns empty on any
override branch, so finishing from one silently exports nothing.

Verify immediately:

```bash
cd build/workspace/sources/<recipe>
git branch          # must show: * devtool  (or your --branch name)
git log --oneline   # upstream base + existing layer patches as commits
```

## 4. Build

```bash
devtool build <recipe>
```

Full image rebuild goes through the Makefile, not raw bitbake:

```bash
make dev      # or base | prod
```

## 5. Edit and commit

```bash
cd build/workspace/sources/<recipe>
git branch                  # confirm before every commit
git add -p
git commit -m "component: what and why"
```

- One logical change per commit — `devtool finish` emits one numbered
  patch per commit.
- The commit body becomes the patch header. Write the *why* there; it
  has to satisfy the `Upstream-Status` rules in
  `.claude/rules/recipe-conventions.md`.
- Never `git commit --amend` here — it moves the commit boundary devtool
  uses to decide what becomes a patch.
- Never `git format-patch` by hand — it bypasses numbering and
  `SRC_URI` wiring.

## 6. Finish

```bash
devtool finish <recipe> meta-iot-gateway/
```

Writes patches to the layer, updates `SRC_URI` in the recipe or
bbappend, removes the workspace bbappend, and resets the workspace
entry.

Destinations in this layer:

| Recipe | Patches land in |
|---|---|
| `u-boot` | `meta-iot-gateway/recipes-bsp/u-boot/files/` |
| `linux-iotgw-mainline-fit` | `meta-iot-gateway/recipes-kernel/linux/files/` |

Kernel config fragments live in
`meta-iot-gateway/recipes-kernel/linux/files/fragments/` and are edited
in the layer directly — not through devtool.

## 6a. Verify the generated patches (mandatory)

Do not rebuild or commit the layer until these pass.

```bash
L=meta-iot-gateway/recipes-bsp/u-boot/files      # adjust per recipe

# Only expected files touched in the layer
git status --short $L

# Each patch touches only intended files (u-boot defconfig example)
grep '^---\|^+++' $L/00*.patch | grep -v 'configs/rpi_arm64_defconfig\|/dev/null'
# Expected: empty. Non-empty means the patch is contaminated.

# No upstream release artifacts crept in
grep -lE 'Makefile|CHANGELOG|release notes' $L/00*.patch
# Expected: no output.

# Patch count matches commit count
ls $L/00*.patch | wc -l
git -C build/workspace/sources/<recipe> log --oneline devtool ^devtool-base | wc -l
```

If any check fails: `devtool reset <recipe>`, `devtool modify
<recipe>`, re-apply cleanly, finish, re-verify.

Every emitted patch needs an `Upstream-Status:` header before it builds
— and note from `.claude/rules/recipe-conventions.md` that editing a
patch header alone invalidates sstate and reruns
`do_patch → do_compile → do_install → do_deploy`. Batch header edits
before kicking off a build.

## 7. Reset

```bash
devtool reset <recipe>
```

Workspace bbappend removed; the layer recipe takes over again. Source is
left in place under `build/workspace/sources/<recipe>/`. With `-r`,
devtool may preserve a modified tree under
`build/workspace/attic/sources/<recipe>.<timestamp>/`; reuse it with
`devtool modify <recipe> <attic-path>` or delete it manually.

## Defconfig workflow (U-Boot)

Kconfig dependency resolution means the effective config delta is larger
than a raw fragment declares. Capture the resolved truth:

```bash
cd build/workspace/sources/u-boot
git branch                       # confirm first

make rpi_arm64_defconfig
make savedefconfig
cp defconfig defconfig.upstream

scripts/kconfig/merge_config.sh .config \
  <repo>/meta-iot-gateway/recipes-bsp/u-boot/files/iotgw-uboot.cfg
# "value redefined" warnings are expected — upstream Kconfig already
# resolved those symbols.

make savedefconfig
grep -c CONFIG_OPTION_YOU_EXPECT defconfig

git add configs/rpi_arm64_defconfig      # ONLY this file
git commit -m "defconfig: apply iotgw base hardening"
```

Then finish + 6a. The existing `0003-defconfig-iotgw-base.patch` was
produced this way; regenerate it the same way on a U-Boot version bump
rather than rebasing hunks by hand.

Head the patch with its regeneration recipe:

```
# Generated by savedefconfig against u-boot <version>.
# Regenerate on version bump: devtool modify u-boot →
#   make rpi_arm64_defconfig → merge_config.sh + iotgw-uboot*.cfg →
#   make savedefconfig → devtool finish
```

## Pitfalls

- **Wrong branch** — `git branch` before every `git add`. Committing on
  `master` puts upstream content in your diff.
- **Override branch** — finishing from one exports nothing at all. Use
  `--no-overrides` when `SRC_URI` has conditional operations.
- **Uncommitted work** — does not become a patch.
- **`AUTOREV` recipes** — pin `SRCREV` explicitly after finishing.
- **"already in your workspace"** — `devtool reset <recipe>` first.
- **U-Boot build fails at `do_configure`** — that is the FIT signing
  guard, not your patch. Configure a key in `kas/local.yml`.
- **Version bump breaks a defconfig patch** — regenerate via the
  defconfig workflow. Do not rebase hunks manually.
