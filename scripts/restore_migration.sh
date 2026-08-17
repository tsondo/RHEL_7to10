#!/bin/bash
# restore_migration.sh - run as root on the NEW RHEL 10 server.
#
# Usage: restore_migration.sh [-n] [-r REVIEWDIR] [-s STEP]... ARCHIVE
#   -n            Dry run: print what would be done, change nothing
#   -r REVIEWDIR  Where to stage configs needing manual adaptation
#                 (default: /root/migration-review)
#   -s STEP       Skip a step (repeatable). Steps:
#                 hostkeys certs users cron logrotate firewalld backups review
#
# Auto-installs: SSH host keys, TLS certs/keys, local users (original
# UID/GID + password hash), cron, logrotate.d, firewalld zone files, and
# the /var/backups directory structure (dirs/perms/ownership only, no data).
# Stages for MANUAL adaptation (never overwrites RHEL 10 hardened
# configs): sshd_config, rsyslog.conf, rsyslog.d.

set -euo pipefail

DRYRUN=0
REVIEW=/root/migration-review
SKIP=" "

while getopts ":nr:s:h" opt; do
    case "$opt" in
        n) DRYRUN=1 ;;
        r) REVIEW="$OPTARG" ;;
        s) SKIP="$SKIP$OPTARG " ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option; try -h" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { echo "usage: $0 [-n] [-r DIR] [-s STEP]... ARCHIVE" >&2; exit 1; }
ARCHIVE="$1"
[ -f "$ARCHIVE" ] || { echo "no such archive: $ARCHIVE" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

run() {  # mutating commands go through here so -n can intercept
    if [ "$DRYRUN" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi
}
skipped() { case "$SKIP" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

STAGE=$(mktemp -d /tmp/restore.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
tar -xzpf "$ARCHIVE" -C "$STAGE"
F="$STAGE/files"; I="$STAGE/info"

if ! skipped hostkeys; then
    echo "== SSH host keys (preserves cached fingerprints, e.g. CUCM DRS)"
    for k in "$F"/etc/ssh/ssh_host_*; do run cp -a "$k" /etc/ssh/; done
    run chmod 600 /etc/ssh/ssh_host_*_key
    ls "$F"/etc/ssh/ssh_host_*_key.pub >/dev/null 2>&1 && run chmod 644 /etc/ssh/ssh_host_*_key.pub
    run restorecon -v /etc/ssh/ssh_host_* || true
fi

if ! skipped certs; then
    echo "== TLS certs/keys (reinstalled at original paths)"
    ( cd "$F" && find . -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \
        -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \) \
        ! -path './etc/ssh/*' -print ) | while read -r rel; do
        tgt="/${rel#./}"
        run install -D -m 0600 "$F/$rel" "$tgt"
        case "$tgt" in *.crt|*.cer|*.pem) run chmod 644 "$tgt" ;; esac
        run restorecon "$tgt" 2>/dev/null || true
        echo "  installed $tgt"
    done
fi

if ! skipped users && [ -s "$I/users.passwd" ]; then
    echo "== Local users (original UID/GID + password hash)"
    while IFS=: read -r name _ uid gid gecos home shell; do
        if id "$name" >/dev/null 2>&1; then
            echo "  $name exists - skipping"
            continue
        fi
        grp=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' "$I/users.group" || true)
        if [ -n "$grp" ] && ! getent group "$grp" >/dev/null; then
            run groupadd -g "$gid" "$grp"
        fi
        run useradd -u "$uid" -g "$gid" -d "$home" -s "$shell" -c "$gecos" -m "$name"
        hash=$(grep "^${name}:" "$I/users.shadow" | cut -d: -f2 || true)
        if [ -n "$hash" ]; then
            if [ "$DRYRUN" -eq 1 ]; then echo "  DRY: chpasswd -e <- $name"
            else echo "${name}:${hash}" | chpasswd -e; fi
        fi
        echo "  created $name (uid $uid)"
    done < "$I/users.passwd"
fi

if ! skipped logrotate && [ -d "$F/etc/logrotate.d" ]; then
    echo "== logrotate.d (no-clobber)"
    run cp -an "$F"/etc/logrotate.d/. /etc/logrotate.d/
fi

if ! skipped cron; then
    echo "== cron"
    [ -d "$F/etc/cron.d" ]      && run cp -an "$F"/etc/cron.d/. /etc/cron.d/
    [ -d "$F/var/spool/cron" ]  && run cp -a  "$F"/var/spool/cron/. /var/spool/cron/
fi

if ! skipped firewalld && [ -d "$F/etc/firewalld/zones" ]; then
    echo "== firewalld zone files"
    run cp -a "$F"/etc/firewalld/zones/. /etc/firewalld/zones/
    run firewall-cmd --reload || true
fi

if ! skipped backups && [ -s "$I/var-backups-structure.txt" ]; then
    echo "== /var/backups directory structure (dirs + perms/ownership; no data)"
    was_mount=$(cat "$I/var-backups.ismount" 2>/dev/null || echo no)
    if [ "$was_mount" = yes ] && ! mountpoint -q /var/backups 2>/dev/null; then
        # Don't create the tree on the root fs only to have the data disk
        # mounted over it later - wait until /var/backups is its own mount.
        echo "  SKIP: /var/backups was a separate filesystem on the source but is"
        echo "        not mounted here yet. Mount the data disk first, then re-run:"
        echo "        $0 -s hostkeys -s certs -s users -s cron -s logrotate \\"
        echo "           -s firewalld -s review $ARCHIVE"
    else
        while IFS=$'\t' read -r bpath bowner bgroup bmode _bctx; do
            [ -n "$bpath" ] || continue
            getent passwd "$bowner" >/dev/null 2>&1 || bowner=root
            getent group  "$bgroup" >/dev/null 2>&1 || bgroup=root
            run install -d -o "$bowner" -g "$bgroup" -m "$bmode" "$bpath"
        done < "$I/var-backups-structure.txt"
        run restorecon -R /var/backups 2>/dev/null || true
    fi
fi

if ! skipped review; then
    echo "== Staging configs for MANUAL adaptation -> $REVIEW"
    run mkdir -p "$REVIEW"
    run cp -a "$F"/etc/ssh/sshd_config "$REVIEW/sshd_config.rhel7"
    [ -f "$F/etc/rsyslog.conf" ] && run cp -a "$F"/etc/rsyslog.conf "$REVIEW/rsyslog.conf.rhel7"
    [ -d "$F/etc/rsyslog.d" ]    && run cp -a "$F"/etc/rsyslog.d "$REVIEW/rsyslog.d.rhel7"
    run cp -a "$I" "$REVIEW/info"
fi

echo
echo "== Done. Manual follow-ups before cutover:"
echo "   $REVIEW/sshd_config.rhel7  -> extract Subsystem/Match blocks into /etc/ssh/sshd_config.d/50-sftp.conf"
echo "   $REVIEW/rsyslog.*.rhel7    -> rewrite as /etc/rsyslog.d/ drop-in (ossl TLS driver)"
echo "   $REVIEW/info/data-dir-perms.txt -> recreate data dir tree on the data disk"
echo "Then: sshd -t && systemctl restart sshd rsyslog, and test (e.g. manual DRS backup)."
