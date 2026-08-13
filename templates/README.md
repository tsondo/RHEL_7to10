# Config adaptation templates

Reviewed starting points for the manual config step of a migration. These
are **not** installed by `restore_migration.sh` — the restore stages the
old RHEL 7 configs in `/root/migration-review/` and you adapt them by hand.
These templates are what that adaptation should produce, generated from the
first real UC SFTP/syslog host's configs.

Copy the relevant file to the real path, fill in the site-specific values
(cert paths, peer names, account groups), and validate before restarting a
service. **Nothing here is paste-and-go** — read the header comments.

| Template | Install to | Validate with |
|---|---|---|
| `sshd_config.d/50-sftp.conf` | `/etc/ssh/sshd_config.d/50-sftp.conf` | `sshd -t` |
| `rsyslog.d/10-cisco-tls.conf` | `/etc/rsyslog.d/10-cisco-tls.conf` | `rsyslogd -N1` |
| `crypto-policies/LEGACY-SFTP-KEX.pmod` | `/etc/crypto-policies/policies/modules/LEGACY-SFTP-KEX.pmod` | `update-crypto-policies --show` |

## Key decisions baked in

- **SSH crypto is not hardcoded.** The RHEL 7 source pinned weak
  Ciphers/MACs/KexAlgorithms inline; on RHEL 10 that is governed by
  crypto-policies. The sshd drop-in carries no crypto lines. Legacy-client
  interop is handled — if at all — by the scoped subpolicy, never
  `--set LEGACY`.
- **Syslog reception moves to TLS/TCP 6514** (ossl driver), replacing the
  source's plaintext UDP:514. The Cisco content/facility rules are carried
  over; the TLS receiver is net-new.
- **The crypto subpolicy is a stub with a FIPS caveat.** On a FIPS host,
  SHA-1/3DES/1024-bit-DH may be unusable no matter the policy — see the
  file header.
