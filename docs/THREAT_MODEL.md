# Threat Model (Gateway-Wide, STRIDE)

This document is the public, repository-safe threat model for the IoT Gateway OS.
It captures architecture-level threats and controls without disclosing operational secrets.

Keep private investigations, incident notes, and sensitive assumptions in internal-only notes outside version control.

## Scope

In scope:
- Boot integrity chain (RPI firmware -> U-Boot -> FIT verification -> kernel/initramfs)
- OTA update path (RAUC A/B, bundle verification, slot switching)
- Runtime configuration persistence (`/etc` overlay reconciliation)
- Provisioning path (`/data/iotgw` inputs -> on-device config/cred stores)
- Core services (networking, OTA, observability, container runtime, TPM helpers)
- Local/remote management interfaces (SSH, D-Bus mediated services)
- Network exposure: listening sockets, firewall policy, and **address family**
  reachability on every attached interface
- Radio interfaces and their firmware: Wi-Fi (link security, supplicant policy),
  Bluetooth, and Thread/OpenThread

Out of scope:
- Fleet backend internals not in this repository
- Third-party cloud account controls

## Security Objectives

1. Prevent unauthorized code execution in boot and update paths.
2. Keep credentials out of immutable images and minimize runtime exposure.
3. Preserve integrity of configuration across OTA while allowing controlled local changes.
4. Maintain least privilege for long-running services.
5. Ensure auditable security events and recoverable failure behavior.

## Trust Boundaries

1. Build host/CI -> signed artifacts
2. Signed artifact store -> target device OTA installer
3. Read-only rootfs slots -> writable `/data` and `/etc` overlay upper
4. Provisioning input store (`/data/iotgw`) -> privileged provisioning services
5. Local root/admin shell -> all runtime secret and control planes
6. Network ingress (MQTT/SSH/management) -> internal services
7. Upstream layer defaults -> shipped product policy (see "Inherited vs
   Authored Configuration")

**Address families are a boundary, not a detail.** IPv4 subnet separation
between two interfaces does **not** imply IPv6 separation: interfaces on
different v4 subnets routinely share a single globally routable v6 prefix via
SLAAC, and IPv6 has no NAT to fall back on. Any reasoning of the form "that
interface is on a separate network" must be re-checked per family before it
counts as a control.

## Attacker Positions

Controls are only meaningful against a position. This list is the lookup: a
control that maps to no in-scope position is a nicety, however good it sounds.

| # | Position | Reaches | Primary controls |
|---|---|---|---|
| A1 | Unauthenticated network peer (LAN, routed, Wi-Fi, IPv6) | Listening sockets admitted by the firewall | listen scope, family-qualified firewall rules, service auth |
| A2 | Radio-proximate peer (Wi-Fi, BLE, Thread) | Link-layer association, pairing, commissioning | link security (WPA2/WPA3 + PMF), BlueZ policy, Thread commissioning |
| A3 | Compromised confined service (non-root) | Local IPC — D-Bus, Unix sockets, device nodes | per-service sandboxing, D-Bus method authorization, MAC policy |
| A4 | Local authenticated user | Shell, sudo policy, group memberships | account policy, sudoers scope, `hidepid` |
| A5 | Physical / removable storage | SD contents, UART, U-Boot console | boot-chain signing, console policy, storage-at-rest posture |
| A6 | Update-path actor (bundle source, D-Bus caller) | Rootfs replacement, slot/boot state | bundle signature policy, installer authorization, anti-rollback |

Notes on scope: A4 is largely development-only — production images carry no
interactive accounts. A5 is bounded by the documented absence of OTP-rooted
secure boot; see `docs/FIT_BOOT_SIGNING.md` for what signing does and does not
cover.

## Inherited vs Authored Configuration

**The recurring failure mode in this product is not weak policy we wrote — it is
absent policy we never wrote, because an upstream layer already supplied one.**
Services authored in `meta-iot-gateway` are consistently well-contained.
Components arriving from OE-Core, meta-raspberrypi or other layers ship with
*their* defaults, which are chosen for generality rather than for an appliance,
and are silently adopted.

Instances found in this product (each a real defect, not hypothetical):

| Inherited default | Effect | Position |
|---|---|---|
| `sshd.socket` with a bare `ListenStream=<port>` | systemd binds dual-stack; SSH answers on every address the device holds, including globally routable IPv6 | A1 |
| RAUC D-Bus policy granting `context="default"` | Any local process may call a root, unsandboxed installer | A3, A6 |
| brcmfmac SDIO device-ID -> vendor-backend mapping | Binds the Wi-Fi part to a backend lacking the external-SAE implementation, so WPA3 cannot work despite capable firmware | A2 |
| Radio firmware version/lineage chosen by an upstream machine conf | Firmware — a security-relevant input on the primary radio attack surface — is neither pinned nor reviewed by us | A2 |

Contrast: `nftables` rules that admitted a port on both address families were
**our** file, and the same file already family-qualified its ICMP rules. Authored
policy fails by omission in one rule; inherited policy fails wholesale and
invisibly, because no file in this repository is wrong.

Practices that follow:

1. **Review what you inherit, not only what you write.** A component's default
   config is a decision the product makes, whether or not anyone made it.
2. **Prefer overrides that travel with the package** over ones an image recipe
   must remember to install — an image variant that omits a hardening package
   must not thereby lose a listen-scope or authorization control.
3. **Pin security-relevant upstream inputs deliberately**, with a recorded
   reason and an upgrade path — firmware blobs included.
4. **Assert the resulting system, not the inputs.** Only a check that inspects
   the assembled image or the running device can see a defect that lives in a
   file this repository does not contain. See `docs/SECURITY.md`,
   "Listening Socket Check".

## Key Assets

- Boot keys, RAUC trust anchors, bundle signatures
- Device identity and TPM-backed material
- OTA state, rollback metadata, slot status
- Service credentials and auth policy stores
- Network configuration and access-control policy
- Security logs and audit trails

## STRIDE Summary

### Spoofing
- Risks: rogue bundle source, forged provisioning inputs, impersonated device/service.
- Baseline controls: signed FIT/RAUC artifacts, TLS/cert trust roots, service account isolation.
- Planned controls: stronger device identity binding and signed bootstrap payloads.

### Tampering
- Risks: modification of overlay-managed configs, credential stores, OTA metadata.
- Baseline controls: managed-path reconciliation, read-only rootfs, hardened service permissions.
- Planned controls: additional integrity checks and post-OTA verification gates.

### Repudiation
- Risks: inability to prove who changed security-relevant configuration.
- Baseline controls: journald/auditd coverage, build/version metadata exposure.
- Planned controls: structured security event catalog and retention policy by profile.

### Information Disclosure
- Risks: plaintext credentials in env/argv/files, debug surfaces leaking sensitive state.
- Baseline controls: credential store migration, reduced env secret usage, hardened file modes.
- Planned controls: TPM-sealed secret strategy and reduced runtime secret materialization.

### Denial of Service
- Risks: failed slot transitions, bad config persistence, service hardening regressions.
- Baseline controls: A/B rollback semantics, conservative provisioning behavior, restart policies.
- Planned controls: health gates for critical services in OTA validation.

### Elevation of Privilege
- Risks: overly broad service permissions/capabilities, weak syscall boundaries.
- Baseline controls: systemd sandboxing, non-root services, read-only system partitions.
- Planned controls: per-service hardening matrix with compatibility tests.

## Service Security Baseline

Every new or modified service should be reviewed for:
- `User=`/`Group=` non-root operation
- `NoNewPrivileges=yes`
- Read-only filesystem posture (`ProtectSystem`, scoped `ReadWritePaths`)
- Capability minimization (`CapabilityBoundingSet=`, `AmbientCapabilities=`)
- Syscall and namespace restrictions when compatible
- Secret handling path (no secrets in image defaults; avoid argv leaks)
- **Its D-Bus policy, if it claims a bus name** — a well-sandboxed non-root
  service is not contained if it can reach a privileged one over the system bus.
  Restrict state-changing interfaces or members to the accounts that need them;
  keep read-only properties and introspection open so diagnostics and health
  reporting keep working. A policy that names a group degrades safely to
  root-only when that group is absent.

**This review applies to inherited units too, and that is where the gaps are.**
`systemd-analyze security` separates the two populations cleanly — services
authored here sit in the protected band, services adopted from upstream layers
do not:

| Population | Typical exposure |
|---|---|
| Authored in this layer (health daemon, OTBR units, broker) | ~1-5, "OK"/"PROTECTED" |
| Inherited from upstream layers (installer, smartcard daemon, HCI attach, audit, bus daemon) | ~9+, "UNSAFE" |

A high score is not automatically a defect — some components legitimately need
broad privilege (a slot installer writes raw block devices and must run as
root). The defect is leaving such a component **both** broadly privileged
**and** broadly reachable. Reduce reachability first: it is usually a policy
file, whereas capability minimization on a privileged writer risks failing
mid-operation, at the worst possible moment.

Sandboxing directives added to an update or storage path must be validated by a
real end-to-end operation, not by the exposure score falling.

## Current Focus Areas

1. Credential lifecycle hardening across all services.
2. OTA security verification gates (pre/post install).
3. TPM-backed production secret model.
4. Formal service hardening checklist enforcement in CI.
5. Auditing inherited upstream defaults — listen scope, D-Bus authorization,
   device-ID/driver bindings, and radio firmware pinning.
6. Link-layer security posture: management-frame protection on existing
   networks, and WPA3-SAE support.
7. Assertion coverage for exposure: only expected listeners, on the expected
   address families, with family-qualified firewall rules.

## Verification Posture

Configuration presence is not enforcement, and a passing build is not evidence.
Anything in this document that claims a control is *effective* must be traceable
to a check whose answer does not come from reading our own configuration:

- **Off-device** for reachability — a device cannot prove what is reachable
  from elsewhere. See `scripts/security/exposure-probe-host.sh`.
- **On-device** for effective state — merged unit properties, the live firewall
  ruleset, actual listening sockets. See `scripts/security/exposure-target.sh`.
- **Build-time** for regressions that must be caught without hardware, and for
  image variants that are rarely flashed.

Where a claim has not been verified, this document should say so rather than
imply coverage. See `AGENTS.md`, "Validating behaviour changes".
