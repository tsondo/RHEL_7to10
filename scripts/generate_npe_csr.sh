#!/bin/bash
# generate_npe_csr.sh - create a private key + CSR to submit to the DoD NPE
# certificate portal (e.g. the syslog TLS server cert for Phase 5 of the
# cutover runbook). Run ON the target RHEL 10 host so the private key is
# generated locally and never leaves the box.
#
# Defaults satisfy common NPE / FIPS requirements: RSA 2048, SHA-256,
# extendedKeyUsage = serverAuth + clientAuth, and a SubjectAltName built
# from the CN plus any extras you pass. Confirm the exact key size and
# Subject DN rules against YOUR portal's instructions - some NPE portals
# set the DN themselves and only read the public key + SANs from the CSR.
#
# Usage: generate_npe_csr.sh [-c CN] [-a SAN]... [-o OUTDIR] [-O ORG]
#                            [-U OU]... [-C COUNTRY] [-b BITS] [-f]
#   -c CN       Common Name / FQDN (default: `hostname -f`)
#   -a SAN      Extra Subject Alt Name (repeatable). Bare value = DNS, or
#               prefix explicitly:  DNS:host.mil  /  IP:10.1.2.3
#   -o OUTDIR   Output directory (default: current directory)
#   -O ORG      Subject O= (optional)
#   -U OU       Subject OU= (repeatable, optional)
#   -C COUNTRY  Subject C= (optional, e.g. US)
#   -b BITS     RSA key size: 2048 (default), 3072, or 4096
#   -f          Overwrite an existing key/CSR of the same name
#
# Upload the .csr to the portal. The .key is secret (mode 600) - never
# upload, email, or copy it off the host unencrypted.

set -euo pipefail

CN=""
OUTDIR="."
ORG=""
COUNTRY=""
BITS=2048
FORCE=0
SANS=()
OUS=()

while getopts ":c:a:o:O:U:C:b:fh" opt; do
    case "$opt" in
        c) CN="$OPTARG" ;;
        a) SANS+=("$OPTARG") ;;
        o) OUTDIR="$OPTARG" ;;
        O) ORG="$OPTARG" ;;
        U) OUS+=("$OPTARG") ;;
        C) COUNTRY="$OPTARG" ;;
        b) BITS="$OPTARG" ;;
        f) FORCE=1 ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option; try -h" >&2; exit 1 ;;
    esac
done

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

[ -n "$CN" ] || CN=$(hostname -f 2>/dev/null || hostname)
[ -n "$CN" ] || { echo "could not determine CN; pass -c FQDN" >&2; exit 1; }

case "$BITS" in
    2048|3072|4096) ;;
    *) echo "unsupported -b '$BITS' (use 2048, 3072, or 4096)" >&2; exit 1 ;;
esac

[ -d "$OUTDIR" ] || { echo "no such directory: $OUTDIR" >&2; exit 1; }

KEY="$OUTDIR/$CN.key"
CSR="$OUTDIR/$CN.csr"
if [ "$FORCE" -ne 1 ]; then
    for existing in "$KEY" "$CSR"; do
        [ -e "$existing" ] && { echo "refusing to overwrite $existing (use -f)" >&2; exit 1; }
    done
fi

# Build a self-contained openssl config: DN from flags, extensions fixed to
# the NPE server-cert profile, SAN section assembled from CN + extras.
CONF=$(mktemp)
trap 'rm -f "$CONF"' EXIT

{
    echo "[ req ]"
    echo "default_md = sha256"
    echo "prompt = no"
    echo "distinguished_name = dn"
    echo "req_extensions = req_ext"
    echo
    echo "[ dn ]"
    [ -n "$COUNTRY" ] && echo "C = $COUNTRY"
    [ -n "$ORG" ]     && echo "O = $ORG"
    ou_i=0
    for ou in ${OUS[@]+"${OUS[@]}"}; do
        echo "${ou_i}.OU = $ou"        # numbered so multiple OUs are allowed
        ou_i=$((ou_i + 1))
    done
    echo "CN = $CN"
    echo
    echo "[ req_ext ]"
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth, clientAuth"
    echo "subjectAltName = @alt_names"
    echo
    echo "[ alt_names ]"
    dns_n=0; ip_n=0
    dns_n=$((dns_n + 1)); echo "DNS.${dns_n} = $CN"   # CN as SAN: modern TLS ignores CN
    for s in ${SANS[@]+"${SANS[@]}"}; do
        case "$s" in
            [Dd][Nn][Ss]:*) dns_n=$((dns_n + 1)); echo "DNS.${dns_n} = ${s#*:}" ;;
            [Ii][Pp]:*)     ip_n=$((ip_n + 1));   echo "IP.${ip_n} = ${s#*:}" ;;
            *)              dns_n=$((dns_n + 1)); echo "DNS.${dns_n} = $s" ;;
        esac
    done
} > "$CONF"

umask 077
openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$BITS" -out "$KEY"
chmod 600 "$KEY"
openssl req -new -key "$KEY" -out "$CSR" -config "$CONF"

echo "== CSR generated"
echo "  key: $KEY  (mode 600, KEEP SECRET - do not upload)"
echo "  csr: $CSR  (upload THIS to the NPE portal)"
echo
echo "== Self-check (verify these match the portal's requirements):"
openssl req -in "$CSR" -noout -verify
openssl req -in "$CSR" -noout -text \
    | grep -E "Subject:|Public-Key:|Signature Algorithm:|DNS:|IP Address:|TLS Web" \
    | sed 's/^ */  /'
