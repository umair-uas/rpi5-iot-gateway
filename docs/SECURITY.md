# Security Hardening

This document describes the security features and hardening measures implemented in the IoT Gateway OS.

For gateway-wide STRIDE scope, trust boundaries, and documentation classification policy,
see [Threat Model](THREAT_MODEL.md).

## Overview

The distribution implements defense-in-depth security across multiple layers:

- **Kernel Hardening**: KSPP-aligned security configuration
- **Compiler Hardening**: PIE, RELRO, FORTIFY_SOURCE
- **Runtime Hardening**: Secure sysctl settings, module blacklist
- **Audit Framework**: auditd with project audit rules
- **Firewall**: nftables enabled by default
- **Read-only Root**: RAUC A/B slots mounted read-only

For FIT boot signing and verification chain setup, see the [FIT Boot and Signing Guide](FIT_BOOT_SIGNING.md).

SELinux is the active MAC — see the [SELinux Guide](SELINUX.md) for the concept
primer, local wiring, and the bring-up-to-enforcing roadmap. For historical IMA
and LSM bring-up field notes (from the earlier AppArmor-default era), see
[LSM and IMA Exploration](LSM_IMA_EXPLORATION.md).

---

## Device Identity and Build Metadata Policy

### `/etc/machine-id` Policy

- `machine-id` is a host/runtime instance identifier used by systemd/DBus and OTA correlation.
- It is **not** a cryptographic device identity and must not be used as a trust anchor for attestation, licensing, or anti-cloning.
- Images must avoid shipping a fixed `machine-id`; each unit should end up with a unique value after provisioning/first boot and persist it across OTA updates.

### `/etc/buildinfo` Policy

- `DISTRO_*`, `IMAGE_*`, and `RAUC_BUNDLE_*` metadata are intentionally exposed for supportability and fleet operations.
- Production images should avoid unnecessary host build disclosures.
- Policy in this layer:
  - default (`dev`/`base`): includes `BUILD_SYS` for diagnostics.
  - `prod`: omits `BUILD_SYS` from `/etc/buildinfo` via `IOTGW_BUILDINFO_INCLUDE_BUILD_SYS = "0"`.

### Raspberry Pi EEPROM/OTP Policy

- Raspberry Pi EEPROM/serial/OTP values are useful for inventory and manufacturing correlation.
- Treat EEPROM/OTP identifiers as **non-secret hardware metadata**, not proof of device trustworthiness.
- Avoid irreversible OTP security fusing in early product stages unless manufacturing process, recovery strategy, and rollback policy are finalized.
- Preferred long-term trust model: TPM-backed key material + device certificate chain for identity and attestation.

---

## Kernel Hardening

The kernel follows Kernel Self Protection Project (KSPP) recommendations.

**Configuration:** `meta-iot-gateway/recipes-kernel/linux/files/fragments/security-prod.cfg`

**Key Categories:**
- **Memory Protection** — FORTIFY_SOURCE, INIT_ON_ALLOC/FREE, SLAB hardening, page poisoning
- **Stack Protection** — Stack canaries, VMAP_STACK, randomization
- **GCC Plugins** — STACKLEAK, STRUCTLEAK, LATENT_ENTROPY
- **Access Restrictions** — dmesg restrict, /dev/mem disabled, no core dumps
- **ASLR** — Randomized kernel base, increased entropy
- **Attack Surface** — Debug interfaces disabled, staging drivers removed
- **Module Signing** — SHA256 signatures enforced
- **LSM** — SELinux mandatory access control (permissive default; see [SELINUX.md](SELINUX.md))
- **Audit** — Syscall auditing enabled

### CVE Response Workflow

When a kernel CVE affects a release between our pinned `SRCREV_machine`
and the next planned kernel bump, we carry the upstream stable backport
as a numbered patch in `meta-iot-gateway/recipes-kernel/linux/files/`.

See [Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md) for the
step-by-step workflow: identifying the right stable backport, annotating
for Yocto QA (`Upstream-Status:`, `CVE:`), wiring into `SRC_URI`, and
tracking the patch's sunset on the next `SRCREV` bump.

For image-wide scanning and userspace-package triage — generating the SBOM
and CVE report (`make sbom-cve`), reading it, and turning a scanner row into a
`CVE_STATUS` disposition — see [SBOM & CVE Scanning — Field Guide](SBOM_CVE.md).

---

## Compiler Hardening

Distribution-level compiler flags provide additional runtime protections.

**Configuration:** `meta-iot-gateway/conf/distro/include/iotgw-common.inc`

**Enabled Flags:**
- PIE (Position Independent Executables) — `-fPIE -pie`
- Full RELRO (GOT/PLT hardening) — `-Wl,-z,relro,-z,now`
- Stack canaries — `-fstack-protector-strong`
- Format string hardening — `-Wformat -Wformat-security`
- Buffer overflow detection — `-D_FORTIFY_SOURCE=2`

---

## Runtime Hardening

### System Configuration (sysctl)

**Configuration:** `meta-iot-gateway/recipes-support/iotgw-sysctl/files/90-iotgw.conf`

**Hardening overrides:** `meta-iot-gateway/recipes-security/iotgw-hardening/files/99-iotgw-hardening.conf`

**Network Security:**
- SYN flood protection (syncookies, retries, backlog)
- IP spoofing protection (rp_filter)
- ICMP/source route protection
- Martian packet logging

**Kernel Security:**
- dmesg restricted to root
- Kernel pointers hidden
- kexec disabled
- perf events restricted
- ASLR enabled

**Process Hardening:**
- ptrace restricted to parent processes

### Module Blacklist

Unnecessary kernel modules are blacklisted to reduce attack surface.

**Configuration:** `meta-iot-gateway/recipes-security/iotgw-hardening/files/blacklist.conf`

### Other Hardening

- **File Permissions:** Default umask `027` (no world access)
- **Login Security:** Password aging, secure directory creation (`/etc/login.defs`)

---

## Audit Framework

### auditd Configuration

The `iotgw-audit` package provides project audit rules aligned to CIS-style baselines.
Rules are staged under `/usr/share/iotgw-audit/iotgw.rules` and deployed into
`/etc/audit/rules.d/iotgw.rules` during rootfs post-processing to avoid package
ownership conflicts with `auditd`.

**Persistence and retention:** the package also ships an explicit `auditd.conf`
(deployed the same way). Audit logs persist on `/data` — `/var/log/audit` is a
bind mount from `/data/log/audit` — and rotate at `max_log_file=16` MiB with
`num_logs=5` (~80 MiB nominal budget). Disk-pressure actions are deliberately
non-fatal for an unattended gateway (`disk_full_action=ROTATE`,
`disk_error_action=SYSLOG`, `admin_space_left_action=SYSLOG`), so a full or
failing `/data` cannot wedge auditing. The full persistent-state layout is in
[Persistent State Architecture](PERSISTENT_STATE.md).

**What's Audited:**
- File integrity (critical system files)
- User/group modifications
- Network configuration changes
- Privilege escalation (sudo, su)
- Kernel module loading
- System calls (execve, mount, etc.)
- Failed authentication attempts

**Rules Location on target:**
``` 
/etc/audit/rules.d/iotgw.rules
```

**View Audit Logs:**
```bash
# Recent audit events
ausearch -ts recent

# Failed login attempts
ausearch -m USER_LOGIN -sv no

# Privilege escalation
ausearch -m USER_AUTH

# File access
ausearch -f /etc/passwd
```

---

## Firewall (nftables)

The distribution uses nftables (not iptables) for firewall configuration.

**Base Rules:**
Installed by the `nftables` package with IoT gateway defaults.

**Configuration:**
```
/etc/nftables.conf
```

**Basic Management:**
```bash
# View current ruleset
nft list ruleset

# Reload rules
systemctl reload nftables

# Enable at boot
systemctl enable nftables
```

---

## Security Validation

### Kernel Hardening Check

Validate kernel configuration against KSPP recommendations using the `kernel-hardening-checker` tool. The development image includes the tool through the dev package group; other variants can add it from meta-oe if needed.

**On the running device:**
```bash
kernel-hardening-checker -c /proc/config.gz -m verbose
```

Over SSH from the host:
```bash
ssh root@<device> 'zcat /proc/config.gz | kernel-hardening-checker -c - -m verbose'
```

> An automated host-side check that consumes Yocto build artifacts is a planned follow-up. Until then, run the check against a running device using the kernel's own `/proc/config.gz`.

**What It Checks:**
- Memory protection features
- Stack protection mechanisms
- Access restrictions
- Attack surface reduction
- GCC security plugins
- Module signing
- ASLR configuration

**Report Format:**
- ✅ OK — Security feature properly configured
- ⚠️ FAIL — Recommended feature missing
- ❌ ERROR — Configuration issue

### System Audit (Lynis)

Lynis performs comprehensive security audits of the running system.

**Quick Audit:**
```bash
lynis audit system --quick
```

**Full Audit:**
```bash
lynis audit system
```

**Output:**
- Log: `/var/log/lynis.log`
- Report: `/var/log/lynis-report.dat`

**What It Checks:**
- Boot and services
- Kernel configuration
- File permissions
- User accounts and authentication
- File integrity
- Networking
- Software packages
- Logging and monitoring

**Establishing Baseline:**
```bash
# First boot audit (full log + normalized summary)
lynis audit system --quick --no-colors > /data/lynis-baseline.log
grep -E 'hardening_index=|^warning\[\]=|^suggestion\[\]=' /var/log/lynis-report.dat \
  > /data/lynis-baseline.summary

# Compare over time
lynis audit system --quick --no-colors > /tmp/lynis-current.log
grep -E 'hardening_index=|^warning\[\]=|^suggestion\[\]=' /var/log/lynis-report.dat \
  > /tmp/lynis-current.summary
diff -u /data/lynis-baseline.summary /tmp/lynis-current.summary
```

Lynis has no test for listener address family or bind scope, which is why the
listening-socket check below exists as a separate, independent control — it is
not a Lynis finding this product tunes toward.

### Listening Socket Check

Asserts that only the intended sockets are listening, on the intended address
families, and that the firewall's rules are family-qualified.

```bash
scripts/run-target-checks.sh <device-ip> exposure
```

Two independent layers, because they catch different things:

| Layer | Runs | Catches |
|---|---|---|
| `iotgw-listen-guard.bbclass` | every image build, no board needed | a socket unit binding an unintended address; covers variants that have never been flashed |
| `scripts/security/exposure-target.sh` | on a running target | the resulting system, including daemons that bind their own sockets and the live firewall ruleset |
| `scripts/security/exposure-probe-host.sh` | from a second host | actual reachability — a device cannot prove its own |

**The socket-activation trap.** `sshd` on this image is socket-activated:
systemd binds the listening socket from `sshd.socket` and hands `sshd -i` an
already-connected fd. `ListenAddress` and `AddressFamily` in `sshd_config` are
therefore **inert** — sshd never opens a listening socket, so it never applies
them. Listen scope lives in `sshd.socket.d/override.conf`.

Upstream ships a bare `ListenStream=22`, which systemd binds **dual-stack**
(`*:22`). On a device holding a global IPv6 address that is an un-NATed,
publicly routable management port. The override pins it to `0.0.0.0:22`, and the
empty `ListenStream=` reset preceding it is required — `ListenStream=` is a
list, so without the reset the drop-in *adds* a listener and the dual-stack bind
survives. `systemctl show sshd.socket -p Listen` must return exactly one entry.

The same class applies to the firewall: in a `table inet`, a rule naming a port
with no family match admits it on IPv4 **and** IPv6. Every service rule in
`nftables.conf` carries an explicit `meta nfproto` match, enforced at build time
by `iotgw-firewall.bb` and at runtime by `exposure-target.sh`.

---

## TPM 2.0 (Infineon SLB9672)

For the TPM roadmap, see [TPM Requirements](TPM_REQUIREMENTS.md).

When `IOTGW_ENABLE_TPM_SLB9672=1`, the following TPM security components are included:

### Device Policy (`iotgw-tpm-policy`)
- Dedicated `iotgwtpm` system user/group for least-privilege TPM access
- udev rules enforce ownership on TPM device nodes:
  - `/dev/tpmrm0` (resource manager): `root:iotgwtpm 0660` — group-accessible for applications
  - `/dev/tpm0` (raw device): `root:root 0600` — root-only, prevents direct hardware access

### Userspace Tools
- **`tpm-ops`** — Rust CLI for TPM operations (info, TRNG, PCR reads, hashing, signing)
- **`tpm2-tools`** — Low-level TPM2 CLI (dev image only)
- Default TCTI policy is pinned to `device:/dev/tpmrm0` to avoid simulator/fallback ambiguity.

### Optional TPM Crypto Providers

Enable extra userspace integrations for PKCS#11/OpenSSL consumers:

- `tpm2-pkcs11`
- `tpm2-openssl`
- `tpm2-tss-engine`

Build-time gate:

```bash
IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS=1 make dev
```

Notes:
- Gate is additive and only effective when `IOTGW_ENABLE_TPM_SLB9672=1`.
- On OpenSSL 3 builds, provider-based integration is preferred; `openssl engine`
  output may stay minimal even when TPM crypto provider packages are installed.

### Kernel Support
- Fragment: `meta-iot-gateway/recipes-kernel/linux/files/fragments/tpm-slb9672.cfg`
- TIS-SPI stack over RP1 DesignWare SPI controller
- TPM TRNG feeds kernel entropy pool (`CONFIG_HW_RANDOM_TPM=y`)
- `/dev/spidev` intentionally disabled on TPM chip-select to prevent conflicts

### Build-Time Enablement
```bash
IOTGW_ENABLE_TPM_SLB9672=1 make dev
# Or via kas/tpm.yml include in kas/local.yml
```

---

## Security Checklist

### Production Deployment

Before deploying to production:

- [ ] Change default passwords (`root`, `devel`)
- [ ] Generate unique RAUC signing keys (per deployment/fleet)
- [ ] Review and customize firewall rules
- [ ] Enable kernel security features (`igw_security_prod`)
- [ ] Run `kernel-hardening-checker -c /proc/config.gz` on the deployed device and review the report
- [ ] Regenerate the Lynis baseline and review the diff against `docs/security-baselines/`
- [ ] Verify only expected TCP/UDP listeners are present (`run-target-checks.sh <ip> exposure`)
- [ ] Confirm reachability from a second host on every zone the device attaches to, over **both** IPv4 and IPv6 (`exposure-probe-host.sh`) — a device cannot prove its own reachability
- [ ] Disable unused network services
- [ ] Configure audit log forwarding (if applicable)
- [ ] Set up SSH key-based authentication
- [ ] Disable root password login via SSH
- [ ] Review sysctl settings for your use case
- [ ] Test OTA update rollback mechanism

### Ongoing Maintenance

- [ ] Regularly update base OS and packages
- [ ] Review audit logs for anomalies
- [ ] Re-run Lynis audits quarterly
- [ ] Monitor CVE databases for kernel/package vulnerabilities
- [ ] Rotate RAUC signing keys annually
- [ ] Test disaster recovery procedures

---

## Additional Resources

- [Kernel Self Protection Project](https://kspp.github.io/)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks)
- [NIST Security Guidelines](https://www.nist.gov/cyberframework)
- [OWASP Embedded Security](https://owasp.org/www-project-embedded-application-security/)
