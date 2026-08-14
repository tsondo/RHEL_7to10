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

## Phase 3 — Account data NOT in the archive

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

> Transfer key material over the encrypted rsync/ssh channel only, as above.
> Never stage it on an intermediate host in the clear.

---

## Phase 4 — Adapt sshd (from `templates/`)

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

## Phase 5 — Adapt rsyslog to TLS/TCP 6514 (from `templates/`)

The old receiver was **plaintext UDP:514**; the target requirement is
**TLS over TCP 6514**. This is net-new config, and it needs a server
certificate the old box never had.

- [ ] **Obtain the syslog server cert** from your PKI (DoD CA) and place
  the CA, server cert, and key:
  ```bash
  sudo install -d -m 0755 /etc/pki/rsyslog
  sudo install -m 0644 ca.pem         /etc/pki/rsyslog/ca.pem
  sudo install -m 0644 server-cert.pem /etc/pki/rsyslog/server-cert.pem
  sudo install -m 0600 server-key.pem  /etc/pki/rsyslog/server-key.pem
  sudo restorecon -Rv /etc/pki/rsyslog
  ```

- [ ] **Create the Cisco log target dirs** (rsyslog can't write them
  otherwise):
  ```bash
  sudo install -d -m 0750 -o root -g root /var/log/cisco /var/log/iptables
  sudo restorecon -Rv /var/log/cisco /var/log/iptables
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

---

## Phase 6 — Legacy crypto (only if a client can't connect)

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

## Phase 7 — Cutover

Old and new must never hold the same IP at once.

- [ ] Quiesce the old host (stop DRS jobs / router log flow if you can).
- [ ] **Power off the old VM.**
- [ ] Move the new VM onto the production IP (or confirm it already has it
      now that the old box is down); verify hostname/IP:
  ```bash
  hostnamectl status; ip -4 addr show
  ```

---

## Phase 8 — Functional verification

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
- [ ] **Services healthy:**
  ```bash
  systemctl status sshd rsyslog firewalld --no-pager
  ```

---

## Phase 9 — Cleanup

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
host except the read-only rsync pulls in Phase 3.
