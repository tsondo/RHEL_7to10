# LEGACY-SFTP-KEX.pmod - SCOPED crypto-policies subpolicy STUB.
#
# Install at /etc/crypto-policies/policies/modules/LEGACY-SFTP-KEX.pmod
# (module name must be UPPERCASE and match the filename).
#
# Purpose: if - and ONLY if - a legacy CUCM/router SSH or SFTP client fails
# to negotiate against the RHEL 10 DEFAULT/FIPS policy, re-enable the
# SPECIFIC algorithm that client needs, scoped to SSH, WITHOUT dropping the
# whole system to LEGACY (a STIG finding, forbidden by this repo's rules).
#
# THIS IS A STUB. Do not apply blindly. Identify the exact algorithm first,
# enable only that, then re-validate STIG.
#
# ---------------------------------------------------------------------
# FIPS WARNING (read first):
# On a FIPS-enabled target the OpenSSL/kernel FIPS providers refuse
# non-approved primitives (SHA-1 signatures, 3DES, MD5, 1024-bit DH)
# REGARDLESS of crypto-policy. A subpolicy CANNOT re-enable what FIPS
# blocks at the library level. If a client only speaks
# diffie-hellman-group1-sha1 / 3des-cbc / hmac-sha1, it may simply be
# unable to connect to a FIPS host - the correct fix is to update the
# client, or keep that one flow on a non-FIPS bastion. Do NOT disable FIPS.
# ---------------------------------------------------------------------
#
# Enable the MINIMUM. Uncomment only the line(s) the client actually needs.
# Scope tokens are version-specific: confirm against `man crypto-policies`
# on this build, and check the result in
# /etc/crypto-policies/back-ends/opensshserver.config after applying.
#
# diffie-hellman-group14-sha1 (needs SHA-1 hash in the sshd scope):
#hash@openssh-server = +SHA1
#
# Legacy MAC / cipher (STRONGLY discouraged - non-FIPS, STIG findings;
# prefer replacing the client):
#mac@openssh-server    = +HMAC-SHA1
#cipher@openssh-server = +3DES-CBC
#
# diffie-hellman-group1-sha1 (1024-bit MODP) is intentionally omitted - it
# is broken and must never be re-enabled. Update the client instead.
#
# ---------------------------------------------------------------------
# Apply / verify / roll back:
#   install -m 0644 LEGACY-SFTP-KEX.pmod \
#       /etc/crypto-policies/policies/modules/LEGACY-SFTP-KEX.pmod
#   update-crypto-policies --set DEFAULT:LEGACY-SFTP-KEX   # FIPS host: FIPS:LEGACY-SFTP-KEX
#   sshd -t && systemctl reload sshd
#   # test the client, then confirm nothing else regressed:
#   update-crypto-policies --show
# Roll back:
#   update-crypto-policies --set DEFAULT                   # or FIPS
# ---------------------------------------------------------------------
