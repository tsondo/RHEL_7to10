# Handoff: send router syslog over TLS (RFC 5425)

For the **network/router admin**. This host is now a secure syslog
collector — syslog over TLS on TCP **6514**. The steps below get a Cisco
router sending to it. Exact CLI varies by IOS / IOS-XE train; confirm
against your version.

## Server endpoint

| | |
|---|---|
| FQDN | `<SERVER-FQDN>` (must resolve; the router validates the server cert **by name**) |
| IP | `<SERVER-IP>` |
| Port / transport | `6514` / TCP |
| TLS | 1.2+ |
| Auth | **Mutual TLS** — the router must present a client cert (see step 2) |
| Trust anchor | DoD PKI (same root/intermediates that signed this server's cert) |

## Before you start (on the router)

- **Clock must be accurate** (NTP synced) — TLS rejects certs when the
  clock is off.
- The server **FQDN must resolve** (DNS, or `ip host <SERVER-FQDN> <SERVER-IP>`).
  Name has to match the server cert, or validation fails.
- TCP **6514** to `<SERVER-IP>` must be permitted outbound (and through any
  firewall in between).

## Step 1 — Trust the syslog server's CA

Install the DoD CA chain the server was issued from, so the router trusts
the server cert.

```
crypto pki trustpoint SYSLOG-CA
 enrollment terminal
 revocation-check none
crypto pki authenticate SYSLOG-CA
  <paste the CA/root PEM cert(s), then type: quit>
```

## Step 2 — Router identity cert (for mutual TLS)

The server requires the router to present its own cert. Enroll one from the
same DoD PKI (subject `CN=<router-fqdn>`):

```
crypto pki trustpoint ROUTER-ID
 enrollment <your PKI method>
 subject-name CN=<router-fqdn>
 rsakeypair ROUTER-ID 2048
crypto pki authenticate ROUTER-ID
crypto pki enroll ROUTER-ID
```

## Step 3 — Configure TLS logging

```
logging tls-profile SYSLOG-TLS
 tls-version 1.2
 trustpoint client ROUTER-ID
!
logging host <SERVER-IP> transport tls port 6514 profile SYSLOG-TLS
logging source-interface <mgmt-interface>
logging trap informational
```

> Older IOS without `logging tls-profile`: use
> `logging host <SERVER-IP> transport tls port 6514` and bind the CA/ID
> trustpoints per that train's syntax.

## Step 4 — Send two things back to the syslog server owner

The server pins who may connect, so it needs:

1. The router's **client-cert Subject/SAN** (e.g. `CN=<router-fqdn>`) — it
   gets added to the server's `PermittedPeer` allow-list.
2. The **source IP** the router will send from — for the firewall.

Until #1 is added on the server side, the router's connection will be
refused. That's expected, not a misconfig.

## Step 5 — Verify

On the router:

```
show logging                        | look for the TLS host, state active
show crypto pki trustpoints status  | both trustpoints "Valid"
```

The server owner confirms arrival:

```
sudo ss -tnp | grep 6514
sudo tail -f /var/log/cisco/cisco.log
```

## If client certs aren't feasible

If the router can't be issued an identity cert, tell the server owner —
they can switch the collector to **server-auth-only** (a one-line change:
`StreamDriver.AuthMode="anon"`, drop `PermittedPeer`). The router then only
needs step 1 (trust the server CA); skip step 2 and the `trustpoint client`
line. Less strong than mutual TLS, but still encrypted in transit.
