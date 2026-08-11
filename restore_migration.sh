#!/bin/bash
# restore_migration.sh - run as root on the NEW RHEL 10 server.
# Usage: ./restore_migration.sh /path/to/migration-<host>-<stamp>.tar.gz
#
# Auto-installs the mechanically safe items:
#   SSH host keys, rsyslog TLS certs/keys, logrotate.d, cron, firewalld
#   zone files, local users (original UID/GID + password hash).
# Stages sshd_config and rsyslog configs in /root/migration-review/ for
# manual adaptation - it does NOT overwrite the RHEL 10 hardened configs.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <archive.tar.gz>"; exit 1; }
ARCHIVE="$1"
STAGE=$(mktemp -d /tmp/restore.XXXXXX)
REVIEW=/root/migration-review
trap 'rm -rf "$STAGE"' EXIT

tar -xzpf "$ARCHIVE" -C "$STAGE"
F="$STAGE/files"; I="$STAGE/info"
mkdir -p "$REVIEW"

echo "== 1. SSH host keys (preserves DRS fingerprint)"
cp -a "$F"/etc/ssh/ssh_host_* /etc/ssh/
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
restorecon -v /etc/ssh/ssh_host_* || true

echo "== 2. TLS certs/keys for rsyslog"
# Reinstall every cert/key at its original path
( cd "$F" && find . -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \
    -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \) \
    ! -path './etc/ssh/*' -print ) | while read -r rel; do
    tgt="/${rel#./}"
    install -D -m 0600 "$F/$rel" "$tgt"
    case "$tgt" in *.crt|*.cer|*.pem) chmod 644 "$tgt" ;; esac
    restorecon "$tgt" 2>/dev/null || true
    echo "  installed $tgt"
done

echo "== 3. Local users (original UID/GID + password hash)"
while IFS=: read -r name _ uid gid gecos home shell; do
    if id "$name" >/dev/null 2>&1; then
        echo "  $name exists - skipping"
        continue
    fi
    grp=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' "$I/users.group" || true)
    [ -n "$grp" ] && ! getent group "$grp" >/dev/null && groupadd -g "$gid" "$grp"
    useradd -u "$uid" -g "$gid" -d "$home" -s "$shell" -c "$gecos" -m "$name"
    hash=$(grep "^${name}:" "$I/users.shadow" | cut -d: -f2 || true)
    [ -n "$hash" ] && echo "${name}:${hash}" | chpasswd -e
    echo "  created $name (uid $uid)"
done < "$I/users.passwd"

echo "== 4. logrotate + cron"
cp -an "$F"/etc/logrotate.d/. /etc/logrotate.d/ 2>/dev/null || true
cp -an "$F"/etc/cron.d/.      /etc/cron.d/      2>/dev/null || true
[ -d "$F/var/spool/cron" ] && cp -a "$F"/var/spool/cron/. /var/spool/cron/

echo "== 5. firewalld zone files"
if [ -d "$F/etc/firewalld/zones" ]; then
    cp -a "$F"/etc/firewalld/zones/. /etc/firewalld/zones/
    firewall-cmd --reload || true
fi

echo "== 6. Staging configs for MANUAL adaptation (not installed)"
cp -a "$F"/etc/ssh/sshd_config          "$REVIEW/sshd_config.rhel7"
cp -a "$F"/etc/rsyslog.conf             "$REVIEW/rsyslog.conf.rhel7" 2>/dev/null || true
[ -d "$F/etc/rsyslog.d" ] && cp -a "$F"/etc/rsyslog.d "$REVIEW/rsyslog.d.rhel7"
cp -a "$I" "$REVIEW/info"

echo
echo "== Done. Review and adapt before cutover:"
echo "   $REVIEW/sshd_config.rhel7   -> extract Subsystem/Match blocks into /etc/ssh/sshd_config.d/50-sftp.conf"
echo "   $REVIEW/rsyslog.*.rhel7     -> rewrite as /etc/rsyslog.d/ drop-in using the ossl TLS driver"
echo "   $REVIEW/info/sftp-dir-perms.txt  -> recreate sftp/DRS dir tree on the data disk"
echo "Then: sshd -t && systemctl restart sshd rsyslog, and run a manual DRS backup to test."
