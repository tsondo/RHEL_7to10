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
| `/var/backups` structure | directory tree + owner/group/mode/SELinux (dirs only, **not** the data) | Yes — dirs recreated (`backups` step) |
| Reference info | disk layout, fstab, network, rpm list, enabled services, SELinux customizations, home-dir perms | No — informational |

User **data** (DRS backup sets, spooled logs) is not archived — copy it
separately if history must carry over. The `/var/backups` **directory
structure** (e.g. the `log_archive/{cisco,iptables}` layout) *is* captured
and recreated with its perms/ownership, just without the backup files.
For the locally staged IOS-update tree (`/var/sftpstorage`) there is a
dedicated helper, `sync_sftpstorage.sh`, that installs rsync and pulls it
from the DR SFTP server onto the data disk, symlinking the old path
(see below and runbook Phase 4).

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
| `-s STEP` | Skip a step (repeatable): `hostkeys certs users cron logrotate firewalld backups review` |

> The `backups` step recreates the `/var/backups` directory structure
> (dirs/perms/ownership, no data). If `/var/backups` was a separate
> filesystem on the source, run it **after** the data disk is mounted — it
> auto-skips (with instructions) if the mount isn't in place yet.

### sync_sftpstorage.sh (run as root on RHEL 10, after restore)

Installs rsync if missing, then pulls the locally staged IOS-update tree
(`/var/sftpstorage`) — the images each site's routers update from — over
ssh from a peer SFTP server. Default source is the DR SFTP server
(`tyfq-dr-sftpv`), pulled as `drsbackup`, which stays up through cutover.
Because `/var` is a small (~10G) OS filesystem on these hosts, the tree is
stored at `/var/backups/sftpstorage` on the data disk and
`/var/sftpstorage` becomes a symlink to it, so existing scripts keep
working; the script refuses to sync onto `/` or `/var` (mount the data
disk first, runbook Phase 3). The whole tree is chowned to `drsbackup`
(dirs 750 / files 640) and relabeled with `restorecon`. Re-runs only
transfer changes; nothing already staged locally is ever deleted.

| Flag | Meaning |
|---|---|
| `-n` | Dry run — prints the mutating steps, previews the transfer with `rsync --dry-run` |
| `-s [USER@]HOST` | Server to pull from (default `drsbackup@tyfq-dr-sftpv`) |
| `-p PATH` | Source path on the peer and local symlink location (default `/var/sftpstorage`) |
| `-d DIR` | Real local storage dir on the data disk (default `/var/backups/sftpstorage`) |
| `-o USER[:GROUP]` | Local owner applied to the tree (default `drsbackup:drsbackup`) |

### generate_npe_csr.sh (run as the operator on RHEL 10)

Generates a private key + CSR for the DoD NPE certificate portal (e.g. the
syslog TLS server cert). Run on the target host so the key never leaves it.
Defaults: RSA 2048, SHA-256, `serverAuth`+`clientAuth`, SAN from CN + extras.

| Flag | Meaning |
|---|---|
| `-c CN` | Common Name / FQDN (default: `hostname -f`) |
| `-a SAN` | Extra Subject Alt Name (repeatable); bare = DNS, or `DNS:`/`IP:` prefix |
| `-o OUTDIR` | Output directory (default: current dir) |
| `-O ORG` / `-U OU` / `-C COUNTRY` | Optional Subject DN fields (`-U` repeatable) |
| `-b BITS` | RSA key size: 2048 (default), 3072, 4096 |
| `-f` | Overwrite an existing key/CSR |

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
