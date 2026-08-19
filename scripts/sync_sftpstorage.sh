#!/bin/bash
# sync_sftpstorage.sh - run as root on the NEW RHEL 10 server, post-restore.
#
# Installs rsync if missing, then pulls the locally staged IOS-update tree
# from a peer SFTP server so site routers can keep pulling their images
# from this host. The usual source is the DR SFTP server (tyfq-dr-sftpv),
# which stays up regardless of cutover state, so this can run before or
# after the old host is powered off. Pulls as the drsbackup account.
#
# /var on these hosts is a small (~10G) OS filesystem, so the tree is
# stored under /var/backups (the data disk) and /var/sftpstorage becomes a
# symlink to it - existing scripts that reference /var/sftpstorage keep
# working. The script refuses to sync onto / or /var, so run it after the
# data disk is mounted (runbook Phase 3). Ownership and perms of the whole
# tree are set to the owner account (default drsbackup, dirs 750 files
# 640), so run it after restore_migration.sh has recreated the accounts.
#
# Re-runs only transfer changes, and nothing already staged locally is
# ever deleted (no --delete). Data sync is deliberately separate from
# restore_migration.sh - see docs/cutover-runbook.md Phase 4.
#
# Usage: sync_sftpstorage.sh [-n] [-s [USER@]HOST] [-p PATH] [-d DIR]
#                            [-o USER[:GROUP]]
#   -n              Dry run: prints the install/link/perm steps, runs rsync
#                   with --dry-run so you see exactly what would transfer
#   -s [USER@]HOST  Server to pull from (default: drsbackup@tyfq-dr-sftpv)
#   -p PATH         Source path on the peer AND the local symlink location
#                   (default: /var/sftpstorage)
#   -d DIR          Real local storage dir, on the data disk
#                   (default: /var/backups/sftpstorage)
#   -o USER[:GROUP] Local owner applied to the whole tree
#                   (default: drsbackup:drsbackup)

set -euo pipefail

SRC=drsbackup@tyfq-dr-sftpv
LINK=/var/sftpstorage
DEST=/var/backups/sftpstorage
OWNER=drsbackup
DRYRUN=0

while getopts ":ns:p:d:o:h" opt; do
    case "$opt" in
        n) DRYRUN=1 ;;
        s) SRC="$OPTARG"; case "$SRC" in *@*) ;; *) SRC="drsbackup@$SRC" ;; esac ;;
        p) LINK="$OPTARG" ;;
        d) DEST="$OPTARG" ;;
        o) OWNER="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option; try -h" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || { echo "usage: $0 [-n] [-s [USER@]HOST] [-p PATH] [-d DIR] [-o USER[:GROUP]]" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
case "$LINK" in /?*) ;; *) echo "-p must be an absolute path" >&2; exit 1 ;; esac
case "$DEST" in /?*) ;; *) echo "-d must be an absolute path" >&2; exit 1 ;; esac
LINK="${LINK%/}"; DEST="${DEST%/}"
[ "$LINK" != "$DEST" ] || { echo "-p and -d must differ (symlink -> storage dir)" >&2; exit 1; }
case "$OWNER" in *:*) OWNUSER="${OWNER%%:*}"; OWNGROUP="${OWNER#*:}" ;;
                   *) OWNUSER="$OWNER";       OWNGROUP="$OWNER" ;; esac

run() {  # mutating commands go through here so -n can intercept
    if [ "$DRYRUN" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi
}
fail_or_warn() {  # hard stop, except in dry run so previews still work
    if [ "$DRYRUN" -eq 1 ]; then echo "  WARNING (would abort a real run): $*" >&2
    else echo "  ERROR: $*" >&2; exit 1; fi
}

echo "== rsync package"
if command -v rsync >/dev/null; then
    echo "  already installed: $(rsync --version | head -1)"
else
    run dnf -y install rsync
fi
if [ "$DRYRUN" -eq 1 ] && ! command -v rsync >/dev/null; then
    echo "== rsync not installed yet - cannot preview the transfer; re-run without -n"
    exit 0
fi

echo "== Preflight ($DEST owned by $OWNUSER:$OWNGROUP, linked from $LINK)"
getent passwd "$OWNUSER" >/dev/null \
    || fail_or_warn "no local user '$OWNUSER' - run restore's users step first"
getent group "$OWNGROUP" >/dev/null \
    || fail_or_warn "no local group '$OWNGROUP' - run restore's users step first"
anc="$DEST"
while [ ! -d "$anc" ]; do anc=$(dirname "$anc"); done
mnt=$(df -P "$anc" | awk 'NR==2 {print $6}')
case "$mnt" in
    /|/var) fail_or_warn "$DEST would land on the small OS filesystem ($mnt)." \
                "Mount the data disk (/var/backups) first - runbook Phase 3." ;;
    *) echo "  destination filesystem: $mnt" ;;
esac

echo "== Free-space check ($LINK on $SRC vs. $mnt)"
# shellcheck disable=SC2029  # client-side expansion of $LINK is intended
srckb=$(ssh "$SRC" "du -skxH '$LINK'" 2>/dev/null | awk '{print $1}') || srckb=
availkb=$(df -Pk "$anc" | awk 'NR==2 {print $4}') || availkb=
if [ -n "$srckb" ] && [ -n "$availkb" ]; then
    echo "  source tree: $((srckb / 1024)) MiB, destination free: $((availkb / 1024)) MiB"
    if [ "$srckb" -gt "$availkb" ]; then
        echo "  WARNING: source tree is larger than the free space here." >&2
    fi
else
    echo "  could not size $LINK on $SRC (ssh or du failed) - continuing anyway"
fi

echo "== Storage dir + compatibility symlink"
[ -d "$DEST" ] || run install -d -m 0750 "$DEST"
if [ -L "$LINK" ]; then
    tgt=$(readlink "$LINK")
    if [ "$tgt" = "$DEST" ]; then
        echo "  $LINK -> $DEST already in place"
    else
        fail_or_warn "$LINK is a symlink to $tgt, not $DEST - fix it by hand"
    fi
elif [ -d "$LINK" ]; then
    if [ -z "$(ls -A "$LINK")" ]; then
        run rmdir "$LINK"
        run ln -s "$DEST" "$LINK"
    else
        fail_or_warn "$LINK is a real, non-empty directory. Move its contents" \
            "into $DEST (mv $LINK/* $DEST/), remove it, and re-run."
    fi
elif [ -e "$LINK" ]; then
    fail_or_warn "$LINK exists and is not a directory or symlink - fix it by hand"
else
    run ln -s "$DEST" "$LINK"
fi

echo "== Syncing $SRC:$LINK/ -> $DEST/"
# -rltH, not -a: source ownership/perms are irrelevant - the whole tree is
# chowned/chmodded to $OWNER below, and skipping -pog keeps re-runs from
# re-asserting perm diffs rsync would otherwise see.
if [ "$DRYRUN" -eq 1 ]; then
    echo "  DRY: rsync -rltH --partial $SRC:$LINK/ $DEST/ - preview:"
    [ -d "$DEST" ] || echo "  (into not-yet-created $DEST)"
    rsync -rltH --partial --dry-run --itemize-changes "$SRC:$LINK/" "$DEST/"
else
    rsync -rltH --partial --info=progress2 "$SRC:$LINK/" "$DEST/"
fi

echo "== Ownership, perms, SELinux ($OWNUSER:$OWNGROUP, dirs 750 / files 640)"
run chown -R "$OWNUSER:$OWNGROUP" "$DEST"
run chmod -R u+rwX,g+rX,o= "$DEST"
run restorecon -R "$DEST" || true

if [ "$DRYRUN" -eq 1 ]; then
    echo "== Dry run complete - nothing changed."
else
    echo "== Done. $(du -sh "$DEST" | cut -f1) staged in $DEST" \
         "($(find "$DEST" -type f | wc -l) files), linked from $LINK."
    echo "   Spot-check a router-visible image via sftp before relying on it."
fi
