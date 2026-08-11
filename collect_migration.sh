#!/bin/bash
# collect_migration.sh - run as root on the RHEL 7 sftp/syslog server.
# Gathers everything needed for the RHEL 10 replacement into a tar.gz
# in the invoking user's home directory. RHEL 7 / bash 4.2 compatible.

set -euo pipefail

HOST=$(hostname -s)
STAMP=$(date +%Y%m%d-%H%M)
DEST_DIR="${SUDO_USER:+/home/$SUDO_USER}"
DEST_DIR="${DEST_DIR:-/root}"
ARCHIVE="$DEST_DIR/migration-${HOST}-${STAMP}.tar.gz"

STAGE=$(mktemp -d /tmp/mig.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/files" "$STAGE/info"

copy_path() {
    # Preserve full path, perms, ownership under files/
    local p="$1"
    if [ -e "$p" ]; then
        rsync -aR "$p" "$STAGE/files/" 2>/dev/null || cp -a --parents "$p" "$STAGE/files/"
        echo "$p" >> "$STAGE/info/manifest.txt"
    else
        echo "MISSING: $p" >> "$STAGE/info/manifest.txt"
    fi
}

echo "== Collecting on $HOST -> $ARCHIVE"

# --- SSH host keys (preserve DRS fingerprint) ---
for f in /etc/ssh/ssh_host_*; do copy_path "$f"; done
copy_path /etc/ssh/sshd_config
[ -d /etc/ssh/sshd_config.d ] && copy_path /etc/ssh/sshd_config.d

# --- rsyslog configs ---
copy_path /etc/rsyslog.conf
[ -d /etc/rsyslog.d ] && copy_path /etc/rsyslog.d

# --- TLS certs/keys referenced by rsyslog (plus common cert dirs) ---
grep -rhoE '/[^" '"'"']+\.(pem|crt|cer|key|p12|pfx)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null \
    | sort -u | while read -r certpath; do copy_path "$certpath"; done
for d in /etc/pki/rsyslog /etc/pki/tls/private /etc/pki/tls/certs; do
    [ -d "$d" ] && copy_path "$d"
done

# --- logrotate, cron ---
copy_path /etc/logrotate.d
copy_path /etc/cron.d
[ -d /var/spool/cron ] && copy_path /var/spool/cron

# --- firewalld ---
[ -d /etc/firewalld/zones ] && copy_path /etc/firewalld/zones
command -v firewall-cmd >/dev/null && \
    firewall-cmd --list-all-zones > "$STAGE/info/firewalld-runtime.txt" 2>/dev/null || true

# --- local (non-system) users: passwd/group/shadow records for recreation ---
awk -F: '$3 >= 1000 && $1 != "nfsnobody"' /etc/passwd > "$STAGE/info/users.passwd"
cut -d: -f1 "$STAGE/info/users.passwd" | while read -r u; do
    grep "^${u}:" /etc/shadow >> "$STAGE/info/users.shadow" || true
done
awk -F: '$3 >= 1000' /etc/group > "$STAGE/info/users.group"

# --- reference info (not restored, just for your eyes) ---
df -hT                >  "$STAGE/info/disk-layout.txt"
lsblk                 >> "$STAGE/info/disk-layout.txt"
cat /etc/fstab        >  "$STAGE/info/fstab.txt"
ip -4 addr show       >  "$STAGE/info/network.txt" 2>/dev/null || ifconfig -a > "$STAGE/info/network.txt"
rpm -qa | sort        >  "$STAGE/info/rpm-list.txt"
systemctl list-unit-files --state=enabled > "$STAGE/info/enabled-services.txt" 2>/dev/null || true
command -v semanage >/dev/null && semanage export > "$STAGE/info/selinux-custom.txt" 2>/dev/null || true
getenforce > "$STAGE/info/selinux-mode.txt" 2>/dev/null || true

# --- sftp landing / DRS backup dirs: record perms & ownership (data itself not archived) ---
cut -d: -f6 "$STAGE/info/users.passwd" | while read -r h; do
    [ -d "$h" ] && find "$h" -maxdepth 2 -exec ls -ldZ {} \; >> "$STAGE/info/sftp-dir-perms.txt" 2>/dev/null
done

# --- package it up ---
tar -czpf "$ARCHIVE" -C "$STAGE" files info
chmod 600 "$ARCHIVE"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$ARCHIVE"

echo "== Done."
echo "Archive: $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"
echo "Contains private keys - handle accordingly. Manifest:"
cat "$STAGE/info/manifest.txt"
