#!/bin/bash
# sync_sftpstorage.sh - run as root on the NEW RHEL 10 server, post-restore.
#
# Installs rsync if missing, then pulls the locally staged IOS-update tree
# (/var/sftpstorage) from a peer SFTP server so site routers can keep
# pulling their images from this host. The usual source is the DR SFTP
# server (tyfq-dr-sftpv), which stays up regardless of cutover state, so
# this can run before or after the old host is powered off.
#
# Ownership is preserved numerically (--numeric-ids); run it after
# restore_migration.sh has recreated the local accounts so UIDs line up.
# Re-runs only transfer changes, and nothing already staged locally is
# ever deleted (no --delete). Data sync is deliberately separate from
# restore_migration.sh - see docs/cutover-runbook.md Phase 4.
#
# Usage: sync_sftpstorage.sh [-n] [-s [USER@]HOST] [-p PATH]
#   -n              Dry run: prints the install step, runs rsync with
#                   --dry-run so you see exactly what would transfer
#   -s [USER@]HOST  Server to pull from (default: root@tyfq-dr-sftpv)
#   -p PATH         Tree to sync, same path on both ends
#                   (default: /var/sftpstorage)

set -euo pipefail

SRC=root@tyfq-dr-sftpv
SYNCPATH=/var/sftpstorage
DRYRUN=0

while getopts ":ns:p:h" opt; do
    case "$opt" in
        n) DRYRUN=1 ;;
        s) SRC="$OPTARG"; case "$SRC" in *@*) ;; *) SRC="root@$SRC" ;; esac ;;
        p) SYNCPATH="$OPTARG" ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option; try -h" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || { echo "usage: $0 [-n] [-s [USER@]HOST] [-p PATH]" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
case "$SYNCPATH" in /?*) ;; *) echo "-p must be an absolute path" >&2; exit 1 ;; esac
SYNCPATH="${SYNCPATH%/}"

run() {  # mutating commands go through here so -n can intercept
    if [ "$DRYRUN" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi
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

echo "== Free-space check ($SYNCPATH on $SRC vs. local)"
# shellcheck disable=SC2029  # client-side expansion of $SYNCPATH is intended
srckb=$(ssh "$SRC" "du -skx '$SYNCPATH'" 2>/dev/null | awk '{print $1}') || srckb=
if [ -d "$SYNCPATH" ]; then dfref="$SYNCPATH"; else dfref=$(dirname "$SYNCPATH"); fi
availkb=$(df -Pk "$dfref" | awk 'NR==2 {print $4}') || availkb=
if [ -n "$srckb" ] && [ -n "$availkb" ]; then
    echo "  source tree: $((srckb / 1024)) MiB, destination free: $((availkb / 1024)) MiB"
    if [ "$srckb" -gt "$availkb" ]; then
        echo "  WARNING: source tree is larger than the free space here." >&2
        echo "  Give $SYNCPATH its own filesystem first (see runbook Phase 3/4)." >&2
    fi
else
    echo "  could not size $SYNCPATH on $SRC (ssh or du failed) - continuing anyway"
fi

echo "== Syncing $SRC:$SYNCPATH/ -> $SYNCPATH/"
[ -d "$SYNCPATH" ] || run install -d -m 0755 "$SYNCPATH"
if [ "$DRYRUN" -eq 1 ]; then
    echo "  DRY: rsync -aH --numeric-ids --partial $SRC:$SYNCPATH/ $SYNCPATH/ - preview:"
    rsync -aH --numeric-ids --partial --dry-run --itemize-changes \
        "$SRC:$SYNCPATH/" "$SYNCPATH/"
else
    rsync -aH --numeric-ids --partial --info=progress2 \
        "$SRC:$SYNCPATH/" "$SYNCPATH/"
fi

echo "== SELinux contexts"
run restorecon -R "$SYNCPATH" || true

if [ "$DRYRUN" -eq 1 ]; then
    echo "== Dry run complete - nothing changed."
else
    echo "== Done. $(du -sh "$SYNCPATH" | cut -f1) staged in $SYNCPATH" \
         "($(find "$SYNCPATH" -type f | wc -l) files)."
    echo "   Spot-check a router-visible image via sftp before relying on it."
fi
