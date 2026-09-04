# Kernel Configuration

This document describes the kernel configuration system and available feature sets.

## Overview

The distribution uses **modular kernel configuration** based on feature fragments.

**Kernel provider:** `linux-iotgw-mainline-fit` (Linux 6.18 series) — the only
provider. FIT signed boot is mandatory (see `docs/FIT_BOOT_SIGNING.md`); there is
no non-FIT / `linux-raspberrypi` option.

**Always Enabled:**
- `branding.cfg` — Kernel version suffix (`-v8-igw`)
- `trim.cfg` — disable non-required subsystems for appliance profile
- `storage-filesystems.cfg` — OverlayFS, dm-verity, SquashFS (SquashFS xattr required for RAUC bundle mount under SELinux)
- `ikconfig.cfg` — runtime kernel config introspection support
- `audit.cfg` — audit framework plumbing
- `panic-recovery.cfg` — `CONFIG_PANIC_TIMEOUT=30`. Always applied.
  Closes the early-boot "kernel hangs requiring power cycle" failure
  class — any panic auto-reboots within 30s, applies from the first
  instruction the kernel runs.
- `panic-on-oops.cfg` — `CONFIG_PANIC_ON_OOPS=y`. Gated by
  `IOTGW_ENABLE_PANIC_ON_OOPS` (default `"1"`); set to `"0"` in
  `kas/local.yml` for dev/bring-up builds where you want tainted-but-
  running kernels for triage instead of immediate panic+reboot. Together
  with `panic-recovery.cfg` this covers kernel-thread/driver oopses, not
  just init-killing ones.
- `rtc-rpi.cfg` — Raspberry Pi RTC support (gated by `IOTGW_ENABLE_RPI_RTC`)

**Optional Feature Sets:** Controlled via `IOTGW_KERNEL_FEATURES` variable

**Fragment Location:** `meta-iot-gateway/recipes-kernel/linux/files/fragments/`

---

## Available Feature Sets

### `igw_compute_media`

Graphics, video, and media processing support.

**Features:** DRM/KMS, V4L2, camera support, huge pages

**Use for:** GPU acceleration, camera/video processing, display output

**CMA Configuration:**
```bash
# Increase CMA for camera/video if needed (dev images only — see note below)
fw_setenv EXTRA_KERNEL_ARGS "cma=256M"
reboot
```

> **Note:** `EXTRA_KERNEL_ARGS` is honoured on **dev images** only. Production
> images with `appliance_lockdown` reject writes to this variable via the
> U-Boot env writeable-list (intentional — runtime cmdline tuning is a
> boot-policy override). See [U-Boot Hardening](UBOOT_HARDENING.md) for the
> full dev/prod asymmetry and OTA env-refresh caveat.

---

### `igw_containers`

Container runtime support (Podman, Docker).

**Features:** Namespaces, cgroups, overlay filesystem, seccomp

**Required for:** Podman, Docker, LXC

---

### `igw_networking_iot`

IoT networking protocols and features.

**Features:** WireGuard VPN, SocketCAN, VLANs, netfilter/nftables

**Includes:**
- WireGuard VPN
- CAN bus (MCP2515 SPI controller)
- VLAN 802.1Q
- nftables for firewall/NAT (required for OTBR)

**CAN Bus Setup:**
```bash
modprobe can_mcp251x
ip link set can0 type can bitrate 500000
ip link set can0 up
```

---

### `igw_observability_dev`

Kernel debugging and tracing (development only).

**Features:** BPF/eBPF, ftrace, kprobes, perf events, debug symbols

**⚠️ WARNING:** Development only! Do not use in production.

This lane intentionally excludes heavyweight DWARF/BTF metadata knobs so
general observability and CO-RE metadata can be toggled independently.

**Usage:**
```bash
# Confirm eBPF kernel plumbing is available (installed by default in dev images)
bpftool feature probe kernel

# Inspect loaded BPF programs and maps
bpftool prog show
bpftool map show

# Function tracing
echo function > /sys/kernel/debug/tracing/current_tracer
cat /sys/kernel/debug/tracing/trace
```

---

### `igw_btf_core_dev`

Dedicated BTF/CO-RE lab metadata lane (development only).

**Features:** DWARF4 debug info + BTF + BTF modules metadata, with
`pahole-native` build dependency enabled only when this lane is active.

**Enable via gate:**

```bash
IOTGW_ENABLE_BTF_CORE_DEV=1
```

This appends `igw_btf_core_dev` to `IOTGW_KERNEL_FEATURES` and enables:
- `CONFIG_DEBUG_INFO=y`
- `CONFIG_DEBUG_INFO_DWARF4=y`
- `CONFIG_DEBUG_INFO_BTF=y`
- `CONFIG_DEBUG_INFO_BTF_MODULES=y`

**Use for:** libbpf CO-RE workflows where `/sys/kernel/btf/vmlinux` and module
BTF availability are required.

**Verification:**

```bash
test -r /sys/kernel/btf/vmlinux && echo "vmlinux BTF present"
bpftool btf show | head
```

---

### `igw_pstore_persist`

Kernel pstore RAM backend for persisting oops/panic state across reboot.
**Production-safe; on by default in all images.**

This is the *capture infrastructure* — no behavior change at runtime, just
ensures that when the kernel does crash, the post-mortem evidence survives
the reboot. Pairs with the systemd hardware watchdog so a stuck-kernel
event becomes a watchdog reset → record landing on `/data` → recoverable
unit on next boot.

**Features (kernel):**
- `CONFIG_PSTORE`, `CONFIG_PSTORE_RAM`, `CONFIG_PSTORE_CONSOLE`,
  `CONFIG_PSTORE_PMSG`

Reboot-on-panic semantics live in the always-applied `panic-recovery.cfg`
fragment, not here — pstore is the post-mortem capture stack, panic
recovery is the system-wide reboot policy. They're orthogonal: pstore can
be disabled without losing panic recovery, and vice versa.

**BSP wiring (RPi5):** patch
`0007-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch`
reserves a 1 MiB region at `0x13000000` and binds a `compatible = "ramoops"`
node to it. The patch is gated on the same toggle.

**Userspace wiring:**
- `systemd` is built with the `pstore` PACKAGECONFIG, so PID1 ships
  `systemd-pstore.service`.
- The `iotgw-pstore-persist` recipe ships
  `var-lib-systemd-pstore.mount` (a systemd `.mount` unit, not a helper
  service) which bind-mounts `/data/crash/pstore` onto
  `/var/lib/systemd/pstore`. PID1 performs the mount, so it is host-visible
  before `systemd-pstore.service` runs and writes records.
- `systemd-pstore.service` gets a drop-in adding
  `RequiresMountsFor=/var/lib/systemd/pstore`, which auto-orders it after
  the bind mount.
- A `tmpfiles.d` entry creates `/data/crash/pstore` on first boot.
- `iotgw-pstore-prune.service` enforces retention by file count and total
  bytes (defaults `IOTGW_PSTORE_MAX_FILES=20`, `IOTGW_PSTORE_MAX_BYTES=100M`)
  and `xz`-compresses older records to keep the archive bounded.

**Layer gate:** `IOTGW_ENABLE_PSTORE_PERSIST` (default `"1"`). The feature
token is auto-appended to `IOTGW_KERNEL_FEATURES`; you do not normally list
it explicitly.

**Verification on target:**
```bash
# Reserved memory + ramoops registration
dmesg | grep -E "reserved mem.*ramoops|pstore: Registered ramoops"

# Bind mount visible to PID1
findmnt /var/lib/systemd/pstore   # SOURCE should be /data/crash/pstore

# Trigger a panic (lab only — requires sysrq, see igw_crash_debug_dev)
echo c > /proc/sysrq-trigger
# After reboot:
ls /data/crash/pstore/            # console-ramoops-0, dmesg-ramoops-0, …
```

---

### `igw_crash_debug_dev`

**Aggressive lab-only debug** layered on top of `igw_pstore_persist`. Adds
runtime detectors and kernel knobs that turn recoverable conditions into
deterministic panics — useful in a debug campaign, **unsafe for fleet
deployments**.

**Features (kernel):**
- `CONFIG_PSTORE_FTRACE` — function tracing into pstore for post-mortem
  trace replay
- `CONFIG_DYNAMIC_DEBUG`, `CONFIG_DYNAMIC_DEBUG_CORE` — runtime
  pr_debug enablement via `/sys/kernel/debug/dynamic_debug/control`
- `CONFIG_MAGIC_SYSRQ` — kernel control surface (security-relevant)
- `CONFIG_DETECT_HUNG_TASK`, `CONFIG_SOFTLOCKUP_DETECTOR`
- `CONFIG_HARDLOCKUP_DETECTOR` is intentionally **not** set — backend
  support varies per platform/watchdog

**Userspace wiring:**
- `iotgw-crash-debug-sysctl` drops `/etc/sysctl.d/95-iotgw-crash-debug.conf`:
  `kernel.panic = ${IOTGW_CRASH_PANIC_TIMEOUT}`,
  `kernel.panic_on_oops = 1`, `kernel.sysrq = 1`.
- `IOTGW_UBOOT_EXTRA_KERNEL_ARGS` sets the U-Boot runtime cmdline policy:
  `panic=${IOTGW_CRASH_PANIC_TIMEOUT} oops=panic sysrq_always_enabled=1`
  (the cmdline value governs the kernel phase before `sysctl.d` applies;
  both are driven by the same variable).

**Layer gates:**
- `IOTGW_ENABLE_CRASH_DEBUG_DEV` (default `"0"`) — opt-in.
  Setting this to `"1"` implies `IOTGW_ENABLE_PSTORE_PERSIST=1`.
- `IOTGW_CRASH_PANIC_TIMEOUT` (default `"5"`) — seconds.

**What ships where:**

| Component | prod default | dev (`IOTGW_ENABLE_CRASH_DEBUG_DEV=1`) |
|---|:-:|:-:|
| DT ramoops reserved-memory patch | ✓ | ✓ |
| Kernel `PSTORE` family (RAM/CONSOLE/PMSG) | ✓ | ✓ |
| `systemd` `pstore` PACKAGECONFIG + `systemd-pstore.service` | ✓ | ✓ |
| `iotgw-pstore-persist` (`.mount` + tmpfiles + prune) | ✓ | ✓ |
| `CONFIG_DYNAMIC_DEBUG`, `MAGIC_SYSRQ`, `DETECT_HUNG_TASK`, `SOFTLOCKUP_DETECTOR`, `PSTORE_FTRACE` | ✗ | ✓ |
| `iotgw-crash-debug-sysctl` (panic/oops/sysrq sysctls) | ✗ | ✓ |
| U-Boot cmdline policy `panic= oops=panic sysrq_always_enabled=1` | ✗ | ✓ |

---

### `igw_security_prod`

Comprehensive kernel hardening for production.

**Features:** KSPP-aligned security configuration

**Categories:**
- Memory protection (FORTIFY, INIT_ON_ALLOC, SLAB hardening)
- Stack protection (canaries, VMAP_STACK, randomization)
- GCC plugins (STACKLEAK, STRUCTLEAK, LATENT_ENTROPY)
- Access restrictions (dmesg, devmem, kcore disabled)
- ASLR (increased entropy)
- Module signing (SHA256, enforced)
- SELinux LSM (active MAC; lockdown/yama/bpf/landlock stacked)
- Audit framework

**See:** [SECURITY.md](SECURITY.md) for full details

---

### `igw_tpm_slb9672`

TPM2 baseline for SPI-attached Infineon SLB9672 class devices.

**Features:** Built-in (`=y`) TPM core/TIS/TIS-SPI stack and SPI host path.

**Developer note:** `SPI_SPIDEV` is intentionally left commented in the
fragment. Avoid enabling spidev on the same SPI chip-select used by TPM.

**Runtime wiring:** enabling `IOTGW_ENABLE_TPM_SLB9672 = "1"` appends:
- `dtoverlay=${IOTGW_TPM_DTO_OVERLAY}` (default `tpm-slb9670`)

If board wiring requires a different overlay parameterization, override
`IOTGW_TPM_DTO_OVERLAY` in `kas/local.yml`.

**Mainline RPi5 note (important):**
- `dtparam=` keys work only when exported in DTB `__overrides__`.
- On our current mainline `bcm2712-rpi-5-b.dtb`, classic keys such as
  `spi`, `i2c1`, and `i2c_arm` are not exported, so firmware logs
  `Unknown dtparam ... - ignored`.
- Use explicit `dtoverlay=` and DTS changes for peripheral enablement on
  this path instead of relying on generic `ENABLE_SPI_BUS`/`ENABLE_I2C`.
- `dtparam=rtc_bbat_vchg=...` is valid here because the RTC overlay exports it.

**TPM reset via GPIO (dev only):** If the TPM enters a bad state during
development, toggle the reset pin (GPIO 24 on LetsTrust-style wiring):
```bash
pinctrl set 24 op && pinctrl set 24 dl && sleep 0.1 && pinctrl set 24 dh
tpm2_startup -c
```

---

### `igw_no_efi`

Opt-in kernel EFI surface reduction for non-UEFI Raspberry Pi boot flow.

**Features:** disables EFI runtime/stub/efivar paths in the kernel build.

**Use for:** appliance deployments that boot via Raspberry Pi firmware + U-Boot
`bootm` flow and do not require kernel EFI interfaces.

**Important:** this feature intentionally does **not** disable
`CONFIG_EFI_PARTITION`, since GPT partition parsing relies on it.

**Layer gate:** `IOTGW_ENABLE_KERNEL_NO_EFI` (defaults to `1`).

---

## Enabling Feature Sets

### Via KAS Overlay

In `kas/local.yml`:

```yaml
local_conf_header:
  kernel_features: |
    IOTGW_KERNEL_FEATURES = "igw_containers igw_networking_iot igw_security_prod"
```

### Via Environment Variable

```bash
IOTGW_KERNEL_FEATURES="igw_containers igw_networking_iot" make dev
```

### RTC Backport Gate (Mainline Providers)

Raspberry Pi firmware RTC backport can be toggled with:

```yaml
local_conf_header:
  rtc_gate: |
    IOTGW_ENABLE_RPI_RTC = "1"   # set to "0" to disable rtc-rpi patch/fragment
```

### Raspberry Pi EEPROM / VCIO Gate

Enable/disable EEPROM maintenance tooling and VCIO carry patch:

```yaml
local_conf_header:
  rpi_eeprom_gate: |
    IOTGW_ENABLE_RPI_EEPROM = "1"  # set to "0" to exclude rpi-eeprom tooling packages
    IOTGW_ENABLE_VCIO = "1"        # default follows IOTGW_ENABLE_RPI_EEPROM
```

### TPM SPI Gate

Enable TPM2-over-SPI profile and firmware overlay:

```yaml
local_conf_header:
  tpm_spi: |
    IOTGW_ENABLE_TPM_SLB9672 = "1"
    # Optional override (default "tpm-slb9670")
    # IOTGW_TPM_DTO_OVERLAY = "tpm-slb9670"
```

### Kernel EFI Surface Gate

Enable/disable EFI surface reduction fragment:

```yaml
local_conf_header:
  kernel_efi_gate: |
    IOTGW_ENABLE_KERNEL_NO_EFI = "1"   # set to "0" to keep kernel EFI options enabled
```

## DTB Selection

For `MACHINE = "raspberrypi5"`, DTB packaging follows `RPI_KERNEL_DEVICETREE` policy:

- Default: ship only `bcm2712-rpi-5-b.dtb` (Pi 5 Model B focused build)
- Optional: include CM5 DTBs for shared/fleet images

Enable CM5 DTBs in `kas/local.yml` (or product config):

```yaml
local_conf_header:
  dtb_policy: |
    IOTGW_RPI5_INCLUDE_CM5_DTBS = "1"
```

Runtime checks on target:

```bash
cat /proc/device-tree/model
cat /proc/device-tree/compatible | tr '\0' '\n'
```

---

## Recommended Configurations

### Development Image

```yaml
IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_observability_dev"
```

### Production Image (Minimal)

```yaml
IOTGW_KERNEL_FEATURES = "igw_containers igw_networking_iot igw_security_prod"
```

### Production Image (Full-featured)

```yaml
IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_security_prod"
```

---

## Runtime Kernel Parameters

### U-Boot Environment

```bash
# View current args
fw_printenv bootargs

# Add custom args (dev images only — see U-Boot Hardening doc)
fw_setenv EXTRA_KERNEL_ARGS "cma=256M quiet loglevel=3"

# Clear custom args
fw_setenv EXTRA_KERNEL_ARGS ""

# Reboot to apply
reboot
```

> **OTA-updated devices**: if `fw_setenv EXTRA_KERNEL_ARGS=...` doesn't
> appear in `/proc/cmdline` after reboot, the persisted env still has an
> older `iotgw_set_bootargs` from before the fix landed. One-time recovery
> from the U-Boot prompt: `env default iotgw_set_bootargs; saveenv`.
> Fresh WIC flashes pick up the new behaviour automatically.

### Common Parameters

```
cma=256M              # For camera/video applications
quiet                 # Suppress kernel messages
loglevel=3            # Errors only (3), Info (6), Debug (7)
console=tty1          # Enable console on HDMI
console=serial0,115200  # Enable serial console
```

---

## Kernel Branding

Custom version suffix for identification:

```
CONFIG_LOCALVERSION="-v8-igw"
```

---

## Fragment Selection Policy (Implementation Notes)

The fragment list is owned by `meta-iot-gateway/classes/iotgw-kernel-fragments.bbclass`
via the single variable `IOTGW_KERNEL_FRAGMENTS`. `SRC_URI` is derived from
that list so the two cannot drift, and `do_configure:append` enforces two
invariants with `bbfatal`:

1. Every name in `IOTGW_KERNEL_FRAGMENTS` must be present in `${WORKDIR}/fragments/`
   (fetch guard — catches missing `file://fragments/<name>` entries).
2. Every `.cfg` file in `${WORKDIR}/fragments/` must appear in `IOTGW_KERNEL_FRAGMENTS`
   (stale-residue guard — catches fragments left over from a previous build
   with different `IOTGW_ENABLE_*` / `IOTGW_KERNEL_FEATURES` gates).

The second guard is the one that matters most in practice: without it, a
gated fragment (e.g. `btf-core-dev.cfg` from a prior BTF-on build) silently
lingers in the workdir and is re-merged into `.config` even when the gate
is off, inverting the gate and inflating the kernel module footprint. The
guard's `bbfatal` names the offending path so regressions are obvious in
the build log; the recovery is `bitbake -c cleansstate <kernel-recipe>`.

### Adding a fragment

Add a `file://fragments/<name>.cfg` to `meta-iot-gateway/recipes-kernel/linux/files/fragments/`,
then add the bare filename to `IOTGW_KERNEL_FRAGMENTS` in the bbclass under
the appropriate gate. **Do not** add a parallel `SRC_URI:append` — the
bbclass derives `SRC_URI` from the tracked list. Adding both produces a
duplicate fetch entry.

A recipe-specific unconditional fragment (e.g. `thermal-rpi5.cfg` in
`linux-iotgw-mainline-common.inc`) uses `IOTGW_KERNEL_FRAGMENTS:append`
in the recipe `.inc`, not the bbclass.

### BitBake gotcha: `+=` vs `:append` on `SRC_URI`

The bbclass derives `SRC_URI` with `:append`, not `+=`. The reason matters
for anyone extending it:

- `+=` is **parse-time**: it appends to the variable's value at the moment
  the line is parsed.
- `:append =` is **expansion-time**: it's applied every time the variable
  is expanded.

Kernel recipe `.bb` files commonly do a hard `SRC_URI = "..."` set inside
the recipe body (each kernel provider declares its own upstream URLs).
A `set` after a `+=` wipes everything the `+=` contributed; a `:append`
line survives because it runs after the set, at expansion time.

```bitbake
# In the bbclass:
SRC_URI:append = " ${@' '.join('file://fragments/' + f for f in \
    (d.getVar('IOTGW_KERNEL_FRAGMENTS') or '').split() if f)}"
# Not  SRC_URI += "..."  — would be wiped by  SRC_URI = "..."  in the .bb.
```

Verify with `bitbake -e <kernel-recipe> | grep -B2 -A60 '^# \$SRC_URI'` —
the ordered operation list shows whether a `set` follows your contribution.
The Python expression itself is fine in either form: it reads the
fully-expanded `IOTGW_KERNEL_FRAGMENTS` (including any `:append` from the
`.inc`) at expansion time.

---

## Persistent module-signing key

Every image is built with `CONFIG_MODULE_SIG_FORCE=y` and
`CONFIG_MODULE_SIG_ALL=y` (`security-prod.cfg`), so the kernel refuses any
module it cannot verify against a key in its builtin trusted keyring.

By default `CONFIG_MODULE_SIG_KEY` is `certs/signing_key.pem`, which Kbuild
**auto-generates** whenever that file is absent from the kernel build
directory. The kernel then trusts only that throwaway key, which has one
practical consequence:

> A module built against kernel build *N* cannot load on kernel build *N+1*.

That is what blocks rootfs-only RAUC bundles — a bundle that ships new modules
without the matching kernel produces a device that cannot load its own
drivers. On target the symptom is a module that refuses to load with no
obvious reason; `modinfo -F signer <module>` reporting
`Build time autogenerated kernel key` is the tell.

### Generating a key

The PEM must contain **both** the private key and its certificate — Kbuild
reads the key from `CONFIG_MODULE_SIG_KEY` and extracts the certificate from
the same file into `certs/signing_key.x509`.

```bash
mkdir -p keys/dev/module-signing
cd keys/dev/module-signing

cat > x509.genkey <<'EOF'
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
O = iotgw
CN = iotgw module signing key (development)

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF

openssl req -new -nodes -utf8 -sha256 -days 36500 -batch -x509 \
    -config x509.genkey -outform PEM \
    -out iotgw-module-signing-dev.pem -keyout iotgw-module-signing-dev.pem
chmod 0600 iotgw-module-signing-dev.pem
```

`keys/` is gitignored and the `pre-commit` hook refuses anything staged from
it, so the key cannot be committed by accident.

Then point the build at it in `kas/local.yml`:

```
IOTGW_MODULE_SIG_KEY_FILE = "${TOPDIR}/../keys/dev/module-signing/iotgw-module-signing-dev.pem"
```

Leaving the variable unset is supported and restores the auto-generated-key
behaviour, so a fresh clone still builds with no operator key material.

### How it is wired

`meta-iot-gateway/classes/iotgw-kernel-module-sig-key.bbclass` adds
`module-signing-key.cfg` to the tracked fragment list and installs the key
into the kernel build directory as a `do_configure` postfunc.

Two details are deliberate:

- **The configured path is relative to the kernel objtree, not absolute.**
  `CONFIG_MODULE_SIG_KEY` is compiled into `.config`, and `CONFIG_IKCONFIG`
  publishes that as `/proc/config.gz` on the target — an absolute path would
  ship the build host's home directory to every device.
- **The filename is not `certs/signing_key.pem`.** `certs/Makefile` gates its
  auto-generation rule on exactly that name, so reusing it would leave a make
  rule that can overwrite a pre-placed key. Any other name disables the rule.

The class hard-fails rather than degrading quietly if the key is missing or
unreadable, if the PEM lacks either half, or if the fragment did not reach
`.config` — that last one being the case that would otherwise succeed, ignore
the operator key, and silently auto-generate.

The key file is registered in `do_configure[file-checksums]`, so changing the
key content invalidates the kernel's `do_configure` taskhash and every task
downstream of it. Without that, swapping a key on disk left every taskhash
unchanged and BitBake would return modules signed by the retired key from
sstate.

### The out-of-tree module trap

The class also appends to `do_shared_workdir` to publish the key into
`STAGING_KERNEL_BUILDDIR`, and that step is **not optional**. `kernel.bbclass`
populates the shared kernel directory that external module recipes build
against with a hardcoded glob:

```bash
if [ -e certs/signing_key.x509 ]; then
        mkdir -p $kerneldir/certs
        cp certs/signing_key.* $kerneldir/certs/
fi
```

`signing_key.*` matches the default key name and nothing else. Because our key
is deliberately named differently, the certificate reached the shared directory
and the private key did not, so `scripts/sign-file` ran against a missing key.

What makes this dangerous is that the failure is **silent**.
`scripts/Makefile.modinst` reads:

```make
# Don't stop modules_install even if we can't sign external modules.
cmd_sign = ... $(if $(KBUILD_EXTMOD),|| true)
```

Kbuild swallows signing errors for out-of-tree modules. `modules_install`
reports success and emits unsigned `.ko` files, which install cleanly and then
fail to load at runtime with `EKEYREJECTED` under `CONFIG_MODULE_SIG_FORCE=y`
(`ENOKEY` is only the internal verification result; the errno userspace sees
under `sig_enforce` is `EKEYREJECTED` — `kernel/module/signing.c`).

Nothing in the kernel or module build catches this. The only thing that does is
the verification gate in
`meta-iot-gateway/classes/iotgw-kernel-module-signing.bbclass`, which failed
`dx-driver:do_install` on the first build after the key was introduced — which
is precisely the job that class exists to do. **Do not weaken or skip that gate
to get a build through.**

Note that publishing the key this way places a private key in
`build/tmp/work-shared/<machine>/kernel-build-artifacts/certs/`. That is not a
new exposure — the glob above already copied the auto-generated
`signing_key.pem`, private half included, to the same location — but it is one
more reason the dev key is not a production key.

### What this does not solve

This is one of three prerequisites for production-grade module signing; the
other two remain open. See the header of
`meta-iot-gateway/classes/iotgw-kernel-module-signing.bbclass` for the current
status of each. In particular the dev key above is a plain file on the build
host with no hardware protection — appropriate for lab and development
images, not a production posture. A production key belongs in the same
HSM/YubiKey handling as the FIT signing key (`docs/FIT_BOOT_SIGNING.md`).

### Verifying on target

```bash
modinfo -F signer /lib/modules/$(uname -r)/updates/pci_deepx/dx_dma.ko
# expect: iotgw module signing key (development)
# NOT:    Build time autogenerated kernel key
```

Read the module you actually shipped. The build tree's
`certs/signing_key.x509` is regenerated whenever a kernel task re-runs, while
the packaged modules may come from sstate signed by an earlier key, so it is
not a trustworthy source for what the image contains.

---

## Additional Resources

- [Yocto Kernel Development](https://docs.yoctoproject.org/kernel-dev/)
- [Linux Stable Kernel](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git)
- [Raspberry Pi Kernel (alternative provider path)](https://github.com/raspberrypi/linux)
- [KSPP Recommendations](https://kspp.github.io/)
- [Linux Kernel Configuration](https://www.kernel.org/doc/html/latest/admin-guide/README.html)
