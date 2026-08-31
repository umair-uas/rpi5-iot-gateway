# ── FIT signing guard (signed-or-fail policy) ────────────────────────────────
# Hard-fails the build when FIT signing is off, or when the build-time FIT
# signing key is not usable (which would otherwise yield an unsigned FIT that
# the hardened U-Boot, CONFIG_FIT_SIGNATURE=y, cannot boot anyway).
#
# The in-band FIT signer is ALWAYS the file key: iotgw-fit-image feeds the
# upstream kernel-fit-image class from UBOOT_SIGN_KEYDIR / UBOOT_SIGN_KEYNAME, so
# this guard requires that file key (.crt + .key). YubiKey / SoftHSM are trust
# roots (DTB pubkeys) + the out-of-band resigner (scripts/fit-signing/sign_fit.py) — a YK
# public cert cannot sign the build-time FIT — and are validated elsewhere
# (kernel recipe do_deploy + iotgw-uboot-prod-key-guard). There is NO unsigned
# escape hatch.
#
# Modeled on iotgw-uboot-prod-key-guard: a task on the u-boot recipe, before
# do_configure, so it fails the BUILD early (before the kernel/rootfs compile)
# WITHOUT blocking `bitbake -e` / `make parse` / `make layers` for keyless
# metadata inspection. Inherited via u-boot_%.bbappend.

python do_iotgw_fit_signing_guard() {
    import os

    signing = (d.getVar('IOTGW_FIT_SIGNING') or '0').strip()
    if signing != '1':
        bb.fatal(
            '\n'
            'FIT signed boot is the ONLY supported flow, but IOTGW_FIT_SIGNING '
            'is "%s" (expected "1").\n'
            'This distro refuses to produce an unsigned FIT image.\n'
            'Leave IOTGW_FIT_SIGNING at its default and configure a signing key '
            'in kas/local.yml (see kas/local.yml.example, fit_signing block).'
            % signing
        )

    keydir = (d.getVar('UBOOT_SIGN_KEYDIR') or '').strip()
    keyname = (d.getVar('UBOOT_SIGN_KEYNAME') or '').strip()

    # An operator may point UBOOT_SIGN_KEYDIR at a PKCS#11 URI for in-band HSM
    # signing (e.g. SoftHSM); then there is no key *file* to stat and the engine
    # validates at sign time. Only file-based keydirs are checked here.
    if keydir.startswith('pkcs11:'):
        bb.debug(1, 'iotgw-fit-signing-guard: PKCS#11 in-band signer configured, passes.')
        return

    missing = []
    if not keydir or not keyname:
        missing.append('UBOOT_SIGN_KEYDIR / UBOOT_SIGN_KEYNAME are unset')
    else:
        crt = os.path.join(keydir, keyname + '.crt')
        key = os.path.join(keydir, keyname + '.key')
        if not os.path.isfile(crt):
            missing.append('missing cert: ' + crt)
        if not os.path.isfile(key):
            missing.append('missing private key: ' + key)

    if missing:
        bb.fatal(
            '\n'
            'FIT signing is required but the build-time signing key is not usable.\n'
            'The in-band FIT signer is the file key '
            '(UBOOT_SIGN_KEYDIR/UBOOT_SIGN_KEYNAME.{crt,key}):\n'
            '  - ' + '\n  - '.join(missing) + '\n\n'
            'This is operator-generated key material (gitignored, never shipped).\n'
            'Create kas/local.yml from kas/local.yml.example, set the fit_signing\n'
            'block (UBOOT_SIGN_KEYDIR / UBOOT_SIGN_KEYNAME) to point at your key,\n'
            'or generate one per docs/FIT_BOOT_SIGNING.md ("Generate FIT Signing\n'
            'Keys"). YubiKey / SoftHSM are trust roots + the out-of-band resigner;\n'
            'they do NOT replace the build-time file key.'
        )

    bb.debug(1, 'iotgw-fit-signing-guard: file signing key present, passes.')
}

addtask iotgw_fit_signing_guard before do_configure after do_patch
