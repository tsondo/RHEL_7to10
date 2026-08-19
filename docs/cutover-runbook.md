# Cutover runbook — RHEL 7 → RHEL 10 UC SFTP/syslog host

Step-by-step for the **manual** half of a migration: everything after the
archive is on the new box. Work top to bottom, one host at a time. Check
each box as you go — you're not meant to hold it all in your head.

Assumes you've already: collected on the old host, deployed the RHEL 10 VM
from the OVA (same name/IP, currently on a temp IP or powered off), copied
the archive over, and can SSH in as `ucadmin`.

Set these once per session so the commands below paste cleanly:

```bash
ARCHIVE=~/migration-<oldhost>-<stamp>.tar.gz   # the tarball you copied over
OLDHOST=<old-rhel7-ip-or-name>                 # old box, still powered on
REVIEW=/root/migration-review                  # restore's staging dir (default)
```

> **Relaying over an air-gap** (email → Notepad → paste)? Newlines get
> mangled and here-docs (`<<'EOF'`) break — the shell hangs at the `>`
> prompt. Prefer **single-line** commands, and for any multi-line file use a
> one-line base64 drop instead of a here-doc:
> `echo '<base64>' | base64 -d | sudo tee /path/to/file >/dev/null`
> (or pipe to `sudo bash` to run a script). Generate the blob on any Linux
> box with `base64 -w0 <file>`.

---

## Phase 0 — First-boot network sanity (OVA / cloud-init)

Do this **before** anything else on a freshly deployed VM. The OVA's
cloud-init manages the NIC and, on every boot, **regenerates the connection
profile back to DHCP** — silently wiping any static IP you set. Symptom:
networking works right after you configure it, then the box comes up with
no address (only `lo`) after a reboot, and SSH is refused.

- [ ] Set the static IP on a **persistent** NetworkManager profile (replace
      the device name and your four values). The cloud-init profile is
      usually named `cloud-init <dev>`:
  ```bash
  nmcli con mod "cloud-init ens32" ipv4.method manual \
    ipv4.addresses <IP>/<PREFIX> ipv4.gateway <GATEWAY> \
    ipv4.dns "<DNS>" connection.autoconnect yes
  nmcli con up "cloud-init ens32"
  ```

- [ ] **Stop cloud-init from clobbering it on the next boot** — this is the
      fix that makes the address stick:
  ```bash
  echo 'network: {config: disabled}' \
    > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  ```

- [ ] **Prove it survives a reboot** before you trust it:
  ```bash
  reboot
  # after it comes back:
  ip -4 addr show ens32      # same inet address must be present
  ```

> Notes: root's password is locked on the hardened image — use `sudo -i`
> (with **ucadmin's own** password), not `su -`. And `ip -4 addr show` with
> only a `127.0.0.1/8 lo` line means the NIC has no address — go straight to
> the `nmcli` steps above.

---

## Phase 1 — Restore (dry run, then real)

- [ ] **Dry run.** Prints every action, changes nothing. Read it.
  ```bash
  sudo ./scripts/restore_migration.sh -n "$ARCHIVE"
  ```
  Confirm: host keys listed, the accounts it will create (drsbackup + the
  `.adm`/service accounts) show **no UID collision** errors, and configs
  are staged to `$REVIEW` (not installed).

- [ ] **Real run.**
  ```bash
  sudo ./scripts/restore_migration.sh "$ARCHIVE"
  ```
  This auto-installs: SSH host keys, TLS certs (if any were in the
  archive), local users (original UID/GID + hash), cron, logrotate.d,
  firewalld zones. It stages sshd/rsyslog configs in `$REVIEW` for you to
  adapt by hand — it never installs those.

---

## Phase 2 — Verify what restore did

- [ ] **SSH host keys preserved** (this is what keeps CUCM DRS's cached
  fingerprint valid — do not regenerate them):
  ```bash
  for t in rsa ecdsa ed25519; do
    ssh-keygen -lf /etc/ssh/ssh_host_${t}_key.pub 2>/dev/null
  done
  ```
  Compare against the same command on the old host — fingerprints must match.

- [ ] **Accounts recreated** with original UID/GID and password hash:
  ```bash
  id drsbackup                       # expect uid=1007
  getent passwd | awk -F: '$3>=1000'  # review the full set that came over
  sudo getent shadow drsbackup | cut -d: -f2 | head -c 4  # non-empty = hash landed
  ```
  Decide whether the `.adm` admin accounts and `scap.service` *should*
  exist on this hardened box. If the RHEL 10 template/IdM manages those,
  delete the ones you don't want (`sudo userdel -r <name>`) rather than
  leaving stale local accounts.

- [ ] **Restore supplementary group memberships by hand.** Restore recreates
  each account's **primary** group only — not secondary memberships like
  `wheel` (which is GID 10, below the UID/GID 1000 cutoff, so it isn't even
  in the archive). Re-add what each account needs:
  ```bash
  sudo usermod -aG wheel drsbackup     # -aG appends; repeat per account/group
  ```
  Cross-check against the old host's `/etc/group` (or `$REVIEW/info/users.group`
  for the captured ones) so nobody loses sudo/role access after cutover.

- [ ] **Certs** (only if the archive contained any — this host's old
  rsyslog was plaintext, so likely none):
  ```bash
  sudo ls -lZ /etc/pki/rsyslog /etc/pki/tls/private 2>/dev/null
  ```

- [ ] **Cron / logrotate / firewalld** landed:
  ```bash
  ls /etc/cron.d /etc/logrotate.d
  sudo firewall-cmd --list-all
  ```

---

## Phase 3 — Backup storage (mounts + perms)

The DRS backups land on **/var/backups** and router logs on **/var/log**,
both on the dedicated data disk (`sdb`). Do this **before** the rsyslog
setup (Phase 6) creates `/var/log/cisco`, and before DRS ever writes. This
reproduces the old server's LVM names (VG `rhel`) even though the RHEL 10
OVA's OS disk uses plain partitions — the new VG lives only on `sdb`.

Sizes here: `/var/log` = 30G (the old default), `/var/backups` = remaining
disk. Adjust the `-L`/`-l` values if your data disk differs.

- [ ] **Confirm the data disk is the empty 500G one and no `rhel` VG exists:**
  ```bash
  lsblk /dev/sdb           # 500G disk, no partitions/holders
  sudo vgs; sudo pvs       # confirm nothing named 'rhel' already
  ```

- [ ] **Create the PV, VG, and the two LVs** (keeps the old names):
  ```bash
  sudo pvcreate /dev/sdb
  sudo vgcreate rhel /dev/sdb
  sudo lvcreate -n var_log     -L 30G      rhel
  sudo lvcreate -n var_backups -l 100%FREE rhel
  ```

- [ ] **Make xfs filesystems** (matches the old server):
  ```bash
  sudo mkfs.xfs /dev/mapper/rhel-var_log
  sudo mkfs.xfs /dev/mapper/rhel-var_backups
  ```

- [ ] **Seed the new /var/log with the current skeleton** (directory
  structure + SELinux labels services expect — not old log data), then make
  the backups mountpoint:
  ```bash
  sudo mount /dev/mapper/rhel-var_log /mnt
  sudo rsync -aHAX /var/log/ /mnt/     # preserves ownership + SELinux contexts
  sudo umount /mnt
  sudo mkdir -p /var/backups
  ```
  `/var/log/audit` is its own partition (sda8) and remounts on top of the
  new `/var/log` after reboot — leave its fstab line alone.

- [ ] **Point fstab at the new LVs.** `/var/log` already has a line (the OVA
  partition) — **replace** it; **add** the backups line. Do not append a
  second `/var/log`:
  ```bash
  sudo cp /etc/fstab /etc/fstab.bak
  sudo vi /etc/fstab
  #  change the existing /var/log line to:
  #    /dev/mapper/rhel-var_log      /var/log      xfs  defaults  0 0
  #  add a new line for backups:
  #    /dev/mapper/rhel-var_backups  /var/backups  xfs  defaults  0 0
  sudo findmnt --verify        # sanity-check fstab syntax
  ```

- [ ] **Reboot to switch the mounts cleanly** (avoids remounting a busy
  `/var/log` live), then verify:
  ```bash
  sudo systemctl reboot
  # after it comes back:
  findmnt /var/log /var/backups          # on rhel-var_log / rhel-var_backups
  findmnt /var/log/audit                 # still on sda8
  ```

- [ ] **Set ownership, perms, and SELinux on the backup target:**
  ```bash
  sudo chown drsbackup:drsbackup /var/backups
  sudo chmod 2770 /var/backups           # setgid: backups inherit the group
  sudo restorecon -Rv /var/log /var/backups
  ```
  Watch for SELinux denials on the first DRS backup (`ausearch -m avc -ts recent`).
  `/var/backups` gets the default `var_t`; if SFTP writes are blocked, add a
  file-context rule (`semanage fcontext`) rather than disabling SELinux.

- [ ] **Recreate the `/var/backups` directory structure** captured from the
  old host (the `log_archive/{cisco,iptables}` layout etc. — dirs + perms/
  ownership only, no data). Now that the disk is mounted, run restore's
  `backups` step:
  ```bash
  sudo ./scripts/restore_migration.sh \
    -s hostkeys -s certs -s users -s cron -s logrotate -s firewalld -s review \
    "$ARCHIVE"
  ```
  This auto-skipped during the Phase 1 restore because the data disk wasn't
  mounted yet. It recreates the full captured tree; trim
  `$REVIEW/info/var-backups-structure.txt` first if you only want the
  structural dirs, not every dated backup subdir.

---

## Phase 4 — Account data NOT in the archive

The archive carried the **account** (name/UID/hash) but **not** home-dir
contents. `$REVIEW/info/data-dir-perms.txt` lists what existed and its
ownership/labels. Pull what you need from the old host while it's still up.

- [ ] **Essential — drsbackup SSH auth** (so existing key-based logins from
  DRS/routers/scripts keep working):
  ```bash
  sudo rsync -aRz --numeric-ids \
    "$OLDHOST":/home/drsbackup/./.ssh/ /home/drsbackup/
  sudo chown -R drsbackup:drsbackup /home/drsbackup/.ssh
  sudo chmod 700 /home/drsbackup/.ssh
  sudo chmod 600 /home/drsbackup/.ssh/authorized_keys /home/drsbackup/.ssh/id_rsa
  sudo restorecon -Rv /home/drsbackup/.ssh
  ```
  Do the same for `sftpstorage` if that account is in use.

- [ ] **Optional — historical backup/data trees** (e.g. `cdr-cmr/`,
  `scripts/`) only if history must carry over. DRS will repopulate new
  backups on its own; you don't need the old sets unless you want them.
  ```bash
  sudo rsync -aRz --numeric-ids "$OLDHOST":/home/drsbackup/./cdr-cmr/ /home/drsbackup/
  sudo chown -R drsbackup:drsbackup /home/drsbackup/cdr-cmr
  sudo restorecon -Rv /home/drsbackup/cdr-cmr
  ```

- [ ] **IOS staging tree — `/var/sftpstorage`** (the images each site's
  routers pull for updates). Not in the archive; pull it from the **DR SFTP
  server** (`tyfq-dr-sftpv`), not the old host — the DR box stays up, so
  this works before or after cutover. The helper installs rsync on this
  host if it's missing, checks free space, syncs (preserving numeric
  ownership — run it after restore has recreated the accounts), and fixes
  SELinux labels:
  ```bash
  sudo ./scripts/sync_sftpstorage.sh -n     # preview (real rsync --dry-run)
  sudo ./scripts/sync_sftpstorage.sh
  ```
  `-s [user@]host` picks a different source, `-p PATH` a different tree.
  Re-runs only transfer changes and never delete anything already staged.
  Mind the size: the tree lands on the OS disk's `/var` unless you give it
  its own filesystem — the script warns if the source is bigger than the
  free space; if it is, carve an LV for it on the data disk in Phase 3
  before syncing. If ssh to the peer won't negotiate (FIPS client vs. an
  older server), diagnose with `ssh -vv` — the same scoped-subpolicy rules
  as Phase 7 apply, never `LEGACY`.

> Transfer key material over the encrypted rsync/ssh channel only, as above.
> Never stage it on an intermediate host in the clear.

---

## Phase 5 — Adapt sshd (from `templates/`)

The old `sshd_config` is staged at `$REVIEW/sshd_config.rhel7`. Do **not**
copy it in — it has RHEL 7-only directives that stop RHEL 10 sshd, plus a
weak cipher block that's a STIG/FIPS violation.

- [ ] Install the reviewed drop-in and adjust per its header comments:
  ```bash
  sudo install -m 0644 templates/sshd_config.d/50-sftp.conf \
    /etc/ssh/sshd_config.d/50-sftp.conf
  ```
  For this host there are no chroot/Match blocks to port (accounts use full
  homes), so the file is mostly documentation. Leave the optional
  `Match Group sftponly` block commented unless you're locking the SFTP
  accounts down (and only after confirming drsbackup's lftp/CDR workflow
  survives it).

- [ ] Validate and reload:
  ```bash
  sudo sshd -t && sudo systemctl reload sshd
  ```

---

## Phase 6 — Adapt rsyslog to TLS/TCP 6514 (from `templates/`)

The old receiver was **plaintext UDP:514**; the target requirement is
**TLS over TCP 6514**. This is net-new config, and it needs a server
certificate the old box never had.

> **Interim plaintext option.** If the routers can't switch to TLS yet (the
> network admin needs a few days), stand up the old plaintext **UDP 514**
> receiver in the meantime with
> [`templates/rsyslog.d/10-cisco-udp514.conf`](../templates/rsyslog.d/10-cisco-udp514.conf)
> — same Cisco routing rules, listening on 514 instead of TLS 6514. Do the
> log-dir + logrotate steps below, install that drop-in,
> `sudo firewall-cmd --add-port=514/udp` (runtime is fine for a short bridge),
> and restart rsyslog. **Remove it and close 514 the moment TLS is live** —
> plaintext 514 open permanently is a STIG finding.

- [ ] **Generate the CSR** on this host and submit it to the NPE portal
  (RSA 2048, SHA-256, serverAuth+clientAuth, SAN from CN + extras):
  ```bash
  ./scripts/generate_npe_csr.sh -c <fqdn> -a IP:<prod-ip> [-a <alt-dns>]
  # upload the resulting <fqdn>.csr to the portal; the <fqdn>.key stays here
  ```
  Confirm the printed key size / DN / SANs match the portal's rules before
  submitting. Add `-O/-U/-C` if the portal wants a specific Subject DN.

- [ ] **Convert the CA chain** if the PKI returned a P7B (`.p7b`) instead of
  PEM. Add `-inform DER` if the first form errors with "unable to load":
  ```bash
  openssl pkcs7 -print_certs -in chain.p7b -out chain.pem
  grep -c "BEGIN CERTIFICATE" chain.pem   # expect 2+ (intermediate(s) + root)
  ```
  Cert order in a CA bundle doesn't matter — use it as-is for `ca.pem` below.

- [ ] **When the signed cert comes back**, place the CA chain, server cert,
  and the key generated above:
  ```bash
  sudo install -d -m 0755 /etc/pki/rsyslog
  sudo install -m 0644 chain.pem       /etc/pki/rsyslog/ca.pem
  sudo install -m 0644 cert.pem        /etc/pki/rsyslog/server-cert.pem
  sudo install -m 0600 <fqdn>.key      /etc/pki/rsyslog/server-key.pem
  sudo restorecon -Rv /etc/pki/rsyslog
  ```

- [ ] **Create the Cisco log target + archive dirs.** These do **not**
  survive the Phase 3 `/var/log` disk swap, so (re)create them here — rsyslog
  can't write the logs, and the logrotate `lastaction` can't archive,
  otherwise:
  ```bash
  sudo install -d -m 0750 -o root -g root /var/log/cisco /var/log/iptables
  sudo install -d -m 0750 -o root -g root /var/backups/log_archive/cisco /var/backups/log_archive/iptables
  sudo restorecon -Rv /var/log/cisco /var/log/iptables /var/backups/log_archive
  ```

- [ ] **Fix the migrated logrotate rules for RHEL 10.** The old server's
  logrotate files (`cisco`, `cisco-uc`, `iptables`, `ise`, `solarwinds`, and
  the base `syslog`) signal rsyslog with `kill -HUP $(cat /var/run/syslogd.pid)`
  — a RHEL 7 path that doesn't exist here, so `|| true` swallows the failure
  and, after the first rotation, rsyslog keeps writing to the renamed file and
  the active log stops filling. Replace it with the systemd HUP wherever it
  appears:
  ```bash
  grep -rl 'syslogd\.pid' /etc/logrotate.d/ \
    | sudo xargs -r sed -i 's#.*syslogd\.pid.*#        /usr/bin/systemctl kill -s HUP rsyslog.service 2>/dev/null || true#'
  grep -n 'systemctl kill' /etc/logrotate.d/*   # confirm the replacement
  ```

- [ ] **Install the drop-in** and edit the peers/paths in its header:
  ```bash
  sudo install -m 0644 templates/rsyslog.d/10-cisco-tls.conf \
    /etc/rsyslog.d/10-cisco-tls.conf
  sudo vi /etc/rsyslog.d/10-cisco-tls.conf   # set PermittedPeer (or 'anon'), confirm cert paths
  ```

- [ ] **Set the clock to UTC** if you're keeping the `UTC` timestamp label:
  ```bash
  timedatectl show -p Timezone --value   # if not UTC:
  sudo timedatectl set-timezone UTC
  ```

- [ ] **Open the firewall port and validate**:
  ```bash
  sudo firewall-cmd --permanent --add-port=6514/tcp && sudo firewall-cmd --reload
  sudo rsyslogd -N1 && sudo systemctl restart rsyslog
  sudo ss -tlnp | grep 6514            # confirm it's listening
  ```
  > **If `firewall-cmd --permanent` fails with `[Errno 17] File exists:
  > '/etc/firewalld/zones'`** — restore copied the old server's firewalld
  > zone files (`public.xml`, `public.xml.old`) into `/etc/firewalld/zones/`,
  > and RHEL 10 firewalld chokes writing over them (the traceback ends in
  > `os.mkdir('/etc/firewalld/zones')`). Move them aside so firewalld
  > recreates the dir cleanly — safe: it doesn't touch the running firewall,
  > and the default zone still permits SSH:
  > ```bash
  > sudo mkdir -p /root/fw-backup && sudo mv /etc/firewalld/zones /root/fw-backup/
  > sudo firewall-cmd --permanent --add-port=6514/tcp && sudo firewall-cmd --reload
  > ```
  > A runtime-only `sudo firewall-cmd --add-port=…` (no `--permanent`)
  > sidesteps the write entirely if you just need the port open now.

- [ ] **Onboard each sending router (peer pinning).** Send the network admin
  the router guide — [`docs/router-syslog-tls-guide.md`](router-syslog-tls-guide.md)
  (a `.docx` version sits beside it for handing off). They configure the
  router and return its **client-cert Subject/SAN** and **source IP**. For each router, add the Subject to `PermittedPeer` and
  open the firewall to its source IP, then reload:
  ```bash
  sudo vi /etc/rsyslog.d/10-cisco-tls.conf   # PermittedPeer=["router1.fqdn","router2.fqdn", ...]
  sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=<router-ip> port port=6514 protocol=tcp accept'
  sudo firewall-cmd --reload
  sudo rsyslogd -N1 && sudo systemctl restart rsyslog
  ```
  Until a router's Subject is in `PermittedPeer`, its connection is refused
  by design — that's the mutual-TLS check, not a fault.

---

## Phase 7 — Legacy crypto (only if a client can't connect)

Skip unless an old CUCM/router SSH/SFTP client actually fails to negotiate.

- [ ] **Diagnose first** — what algorithm is it asking for?
  ```bash
  sudo journalctl -u sshd | grep -iE 'no matching|unable to negotiate'
  ```

- [ ] If a specific legacy KEX/cipher is required, apply the **scoped**
  subpolicy (never `--set LEGACY`), per its header:
  ```bash
  sudo install -m 0644 templates/crypto-policies/LEGACY-SFTP-KEX.pmod \
    /etc/crypto-policies/policies/modules/LEGACY-SFTP-KEX.pmod
  sudo vi /etc/crypto-policies/policies/modules/LEGACY-SFTP-KEX.pmod  # uncomment the minimum
  sudo update-crypto-policies --set FIPS:LEGACY-SFTP-KEX   # DEFAULT:… on a non-FIPS host
  sudo sshd -t && sudo systemctl reload sshd
  ```

> **FIPS reality check:** on a FIPS host the crypto libraries may refuse
> SHA-1/3DES/1024-bit-DH regardless of policy. If the client only speaks
> those, the fix is to update the client, not weaken the server.

---

## Phase 8 — Cutover

Old and new must never hold the same IP at once.

- [ ] Quiesce the old host (stop DRS jobs / router log flow if you can).
- [ ] **Power off the old VM.**
- [ ] Move the new VM onto the production IP (or confirm it already has it
      now that the old box is down); verify hostname/IP:
  ```bash
  hostnamectl status; ip -4 addr show
  ```

---

## Phase 9 — Functional verification

- [ ] **SSH fingerprint** — from a client that cached the old host key,
      connect and confirm **no** host-key-changed warning (proves the
      preserved keys work).
- [ ] **CUCM DRS** — run a manual backup per cluster to this SFTP server;
      confirm it completes and the file lands under drsbackup's home.
- [ ] **TLS syslog** — confirm reception from a real device, then watch:
  ```bash
  sudo ss -tnp | grep 6514                 # established peer connections
  sudo tail -f /var/log/cisco/cisco.log /var/log/cisco/cisco-uc.log
  ```
- [ ] **IOS staging** — confirm `/var/sftpstorage` matches the DR server
      (compare `du -sh /var/sftpstorage` on both, or re-run
      `sudo ./scripts/sync_sftpstorage.sh -n` and expect no transfers) and
      test-download one image over SFTP as a router would.
- [ ] **Services healthy:**
  ```bash
  systemctl status sshd rsyslog firewalld --no-pager
  ```

---

## Phase 10 — Cleanup

- [ ] Securely delete the archive and any copied key material once verified:
  ```bash
  shred -u "$ARCHIVE"
  ```
- [ ] The staging dir `$REVIEW/info/` holds password hashes — remove it once
      you no longer need the reference data:
  ```bash
  sudo shred -u $REVIEW/info/users.shadow 2>/dev/null; sudo rm -rf "$REVIEW"
  ```
- [ ] Confirm the old VM stays off (or is snapshotted/decommissioned per
      your process) so it can never reclaim the IP.

---

### If you need to roll back

The old VM is untouched. Power the new one off, power the old one back on,
and it reclaims its own name/IP. Nothing in this runbook modifies the old
host except the read-only rsync pulls in Phase 4.
