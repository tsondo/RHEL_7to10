#!/bin/bash
# collect_migration.sh - run as root on a RHEL 7 source server.
# Gathers identity, config, and account material needed to rebuild the
# host on RHEL 10 into a tar.gz archive. RHEL 7 / bash 4.2 compatible.
#
# Usage: collect_migration.sh [-o OUTDIR] [-a PATH]... [-U MINUID]
#   -o OUTDIR   Where to write the archive (default: invoking user's home)
#   -a PATH     Additional file/dir to collect (repeatable)
#   -U MINUID   Minimum UID treated as a local user (default: 1000)

set -euo pipefail

OUTDIR="${SUDO_USER:+/home/$SUDO_USER}"
OUTDIR="${OUTDIR:-/root}"
MINUID=1000
EXTRA_PATHS=()

while getopts ":o:a:U:h" opt; do
    case "$opt" in
        o) OUTDIR="$OPTARG" ;;
        a) EXTRA_PATHS+=("$OPTARG") ;;
        U) MINUID="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option; try -h" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -d "$OUTDIR" ] || { echo "no such directory: $OUTDIR" >&2; exit 1; }

HOST=$(hostname -s)
STAMP=$(date +%Y%m%d-%H%M)
ARCHIVE="$OUTDIR/migration-${HOST}-${STAMP}.tar.gz"

STAGE=$(mktemp -d /tmp/mig.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/files" "$STAGE/info"

copy_path() {
    local p="$1"
    if [ -e "$p" ]; then
        rsync -aR "$p" "$STAGE/files/" 2>/dev/null || cp -a --parents "$p" "$STAGE/files/"
        echo "$p" >> "$STAGE/info/manifest.txt"
    else
        echo "MISSING: $p" >> "$STAGE/info/manifest.txt"
    fi
}

echo "== Collecting on $HOST -> $ARCHIVE"

# --- SSH host keys (preserve fingerprint for DRS / known_hosts consumers) ---
for f in /etc/ssh/ssh_host_*; do copy_path "$f"; done
copy_path /etc/ssh/sshd_config
[ -d /etc/ssh/sshd_config.d ] && copy_path /etc/ssh/sshd_config.d

# --- rsyslog configs ---
copy_path /etc/rsyslog.conf
[ -d /etc/rsyslog.d ] && copy_path /etc/rsyslog.d

# --- TLS certs/keys referenced by rsyslog, plus common cert dirs ---
# grep exits 1 when it finds no cert paths; with pipefail that would abort the
# whole script under set -e, so swallow a no-match into an empty result.
grep -rhoE '/[^" '"'"']+\.(pem|crt|cer|key|p12|pfx)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null \
    | sort -u | while read -r certpath; do copy_path "$certpath"; done || true
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

# --- caller-specified extras ---
for p in ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do copy_path "$p"; done

# --- local users: passwd/group/shadow records for recreation ---
awk -F: -v m="$MINUID" '$3 >= m && $1 != "nfsnobody"' /etc/passwd > "$STAGE/info/users.passwd"
: > "$STAGE/info/users.shadow"
cut -d: -f1 "$STAGE/info/users.passwd" | while read -r u; do
    grep "^${u}:" /etc/shadow >> "$STAGE/info/users.shadow" || true
done
awk -F: -v m="$MINUID" '$3 >= m' /etc/group > "$STAGE/info/users.group"

# --- reference info (not restored automatically) ---
df -hT                >  "$STAGE/info/disk-layout.txt"
lsblk                 >> "$STAGE/info/disk-layout.txt" 2>/dev/null || true
cat /etc/fstab        >  "$STAGE/info/fstab.txt"
{ ip -4 addr show 2>/dev/null || ifconfig -a; } > "$STAGE/info/network.txt"
rpm -qa | sort        >  "$STAGE/info/rpm-list.txt"
systemctl list-unit-files --state=enabled > "$STAGE/info/enabled-services.txt" 2>/dev/null || true
command -v semanage >/dev/null && semanage export > "$STAGE/info/selinux-custom.txt" 2>/dev/null || true
getenforce > "$STAGE/info/selinux-mode.txt" 2>/dev/null || true

# --- record perms/ownership of local users' dir trees (data not archived) ---
cut -d: -f6 "$STAGE/info/users.passwd" | while read -r h; do
    # find can exit non-zero on an unreadable subdir; don't let that abort collect.
    [ -d "$h" ] && find "$h" -maxdepth 2 -exec ls -ldZ {} \; >> "$STAGE/info/data-dir-perms.txt" 2>/dev/null || true
done

# --- record /var/backups directory structure (dirs + owner/group/mode/context,
#     NOT the data) so restore can recreate the tree on the new host ---
: > "$STAGE/info/var-backups-structure.txt"
if [ -d /var/backups ]; then
    if mountpoint -q /var/backups 2>/dev/null; then
        echo yes > "$STAGE/info/var-backups.ismount"
    else
        echo no  > "$STAGE/info/var-backups.ismount"
    fi
    # tab-separated: path, owner, group, octal-mode, SELinux context
    find /var/backups -type d 2>/dev/null | while read -r d; do
        stat -c '%n\t%U\t%G\t%a\t%C' "$d" 2>/dev/null || true
    done >> "$STAGE/info/var-backups-structure.txt"
fi

# --- package it up ---
tar -czpf "$ARCHIVE" -C "$STAGE" files info
chmod 600 "$ARCHIVE"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$ARCHIVE"

echo "== Done."
echo "Archive: $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"
echo "Contains private keys and password hashes - handle accordingly."
echo "Manifest:"
cat "$STAGE/info/manifest.txt"
