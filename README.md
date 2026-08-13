# rhel-migrate

Scripts for migrating RHEL 7 VMs to RHEL 10 replacements deployed from an
OVA template, where the new VM keeps the **same hostname and IP** as the old
one (old and new must never be powered on at the same time).

Originally built for the UC suite SFTP/syslog servers (CUCM DRS backup
targets + router syslog over TLS), but general enough for any RHEL 7 host:
it carries over machine identity (SSH host keys), TLS material, local
accounts, and scheduled jobs, while deliberately **not** overwriting the
RHEL 10 template's hardened configs.

## ⚠️ Sensitive contents

The archive produced by `collect_migration.sh` contains **SSH host private
keys, TLS private keys, and password hashes**. It is written mode 600.
Transfer it over an encrypted channel only and delete all copies once the
migration is verified.

## Workflow

1. **Collect** on the old RHEL 7 server:

   ```
   sudo ./scripts/collect_migration.sh
   ```

   Produces `migration-<host>-<stamp>.tar.gz` in your home directory and
   prints a manifest.

2. **Deploy** the RHEL 10 VM from the OVA in the same folder, same
   name/IP. Keep it powered off, or up on a temporary IP, while the old
   server is still running.

3. **Copy** the archive to the new server (scp/sftp).

4. **Restore** on the new RHEL 10 server — dry-run first:

   ```
   sudo ./scripts/restore_migration.sh -n migration-<host>-<stamp>.tar.gz
   sudo ./scripts/restore_migration.sh    migration-<host>-<stamp>.tar.gz
   ```

5. **Adapt configs by hand** (see below). The restore stages the old
   `sshd_config` and rsyslog configs in `/root/migration-review/` — it
   never installs them.

   > For the full manual sequence — restore, verify, data sync, config
   > adaptation, cutover, and verification — follow the step-by-step
   > [cutover runbook](docs/cutover-runbook.md).

6. **Cut over**: power off old VM → power on new VM (same name/IP means
   clients never notice, and the copied host keys keep cached SSH
   fingerprints — e.g. CUCM DRS — valid).

7. **Verify**: run a manual DRS backup per cluster, confirm TLS syslog is
   arriving (`ss -tlnp | grep 6514`, watch the log tree), check
   `sshd -t`, `systemctl status sshd rsyslog`, and firewalld rules.

## What gets collected

| Category | Paths | Restored automatically? |
|---|---|---|
| SSH host keys | `/etc/ssh/ssh_host_*` | Yes |
| sshd config | `/etc/ssh/sshd_config[.d]` | No — staged for review |
| rsyslog config | `/etc/rsyslog.conf`, `/etc/rsyslog.d/` | No — staged for review |
| TLS certs/keys | paths referenced in rsyslog config, plus `/etc/pki/rsyslog`, `/etc/pki/tls/{certs,private}` | Yes (original paths/modes) |
| Local users | passwd/group/shadow records, UID ≥ 1000 | Yes (original UID/GID + hash) |
| Scheduled jobs | `/etc/cron.d`, `/var/spool/cron`, `/etc/logrotate.d` | Yes (no-clobber) |
| firewalld | `/etc/firewalld/zones/` | Yes + reload |
| Reference info | disk layout, fstab, network, rpm list, enabled services, SELinux customizations, data-dir perms | No — informational |

User **data** (DRS backup sets, spooled logs) is not archived — copy it
separately if history must carry over.

## Script options

### collect_migration.sh (run as root, RHEL 7-compatible)

| Flag | Meaning |
|---|---|
| `-o OUTDIR` | Write archive here (default: invoking user's home) |
| `-a PATH` | Collect an additional file/dir (repeatable) |
| `-U MINUID` | Minimum UID counted as a local user (default 1000) |

### restore_migration.sh (run as root on RHEL 10)

| Flag | Meaning |
|---|---|
| `-n` | Dry run — print actions, change nothing |
| `-r DIR` | Review/staging directory (default `/root/migration-review`) |
| `-s STEP` | Skip a step (repeatable): `hostkeys certs users cron logrotate firewalld review` |

## RHEL 7 → 10 config adaptation notes

Reviewed drop-in templates for this step live in [`templates/`](templates/)
(sshd SFTP settings, rsyslog TLS-over-TCP 6514 input with the Cisco rules,
and a scoped legacy-KEX crypto subpolicy). They are reference-only — copy,
fill in site values, and validate; restore never installs them.


- **Never copy `sshd_config` verbatim.** RHEL 7 files often contain
  removed SSH-1-era options (`Protocol`, `RSAAuthentication`,
  `UsePrivilegeSeparation`, ...) that stop RHEL 10's sshd from starting.
  Extract only the `Subsystem sftp` line and `Match` blocks into
  `/etc/ssh/sshd_config.d/50-sftp.conf`, then `sshd -t`.
- **rsyslog**: rewrite rules as a drop-in in `/etc/rsyslog.d/` using
  modern RainerScript, and use the `ossl` netstream driver (not `gtls`)
  for TLS input on RHEL 10.
- **Crypto policy**: if an old client (e.g. CUCM DRS) fails SSH
  negotiation against RHEL 10, add a scoped crypto-policy subpolicy for
  the needed algorithm — do **not** switch the system to `LEGACY`
  (STIG finding).
- **Disks**: STIG requires separate *filesystems* (`/var`, `/var/log`,
  `/var/log/audit`, `/home`, `/tmp`), which LVM volumes on one disk
  satisfy. Recommended layout: OS disk + one data disk for
  logs/SFTP/DRS data.
