# Router Guide — Secure Syslog over TLS to the New Server

**Audience:** the network / router administrator.
**Goal:** configure a Cisco router to send its syslog **securely** — TLS over
TCP, port **6514** (RFC 5425) — to the migrated syslog server.

The server now requires **encrypted, mutually-authenticated** syslog. Plaintext
UDP 514 is being retired. This guide walks the router side end to end. Exact
CLI varies by IOS / IOS-XE train — confirm against your version.

---

## 1. Server endpoint

Point the router at:

| Setting | Value |
|---|---|
| Server FQDN | `<SERVER-FQDN>` — must resolve; the router validates the server certificate **by name** |
| Server IP | `<SERVER-IP>` |
| Port / transport | **6514 / TCP** |
| TLS version | 1.2 or higher |
| Authentication | **Mutual TLS** — the router must present its own client certificate (Step 2) |
| Trust anchor | DoD PKI — the same CA chain that signed the server certificate |

> Fill in `<SERVER-FQDN>` and `<SERVER-IP>` from the server owner before you begin.

---

## 2. Prerequisites (on the router)

Confirm these first — TLS fails cryptically if any are wrong:

- **Accurate clock.** The router must be NTP-synced. Certificate validation
  rejects an out-of-tolerance clock.
- **Name resolution.** The server FQDN must resolve (DNS, or a static
  `ip host <SERVER-FQDN> <SERVER-IP>` entry). The name must match the server
  certificate or validation fails.
- **Reachability.** TCP **6514** to `<SERVER-IP>` must be permitted outbound,
  through any ACL or firewall in the path.

---

## 3. Step 1 — Trust the syslog server's CA

Install the DoD CA chain so the router trusts the server's certificate.

```
crypto pki trustpoint SYSLOG-CA
 enrollment terminal
 revocation-check none
crypto pki authenticate SYSLOG-CA
  <paste the CA / root certificate(s) in PEM, then type: quit>
```

If the chain has intermediates, authenticate the full chain (root plus each
intermediate) so the router can build a path to the server certificate.

---

## 4. Step 2 — Enroll a router identity certificate (mutual TLS)

The server verifies the router, so the router must present its own certificate.
Enroll one from the same DoD PKI, with the router's FQDN as the subject.

```
crypto pki trustpoint ROUTER-ID
 enrollment <your PKI enrollment method>
 subject-name CN=<router-fqdn>
 rsakeypair ROUTER-ID 2048
crypto pki authenticate ROUTER-ID
crypto pki enroll ROUTER-ID
```

Record the resulting certificate's **Subject** (e.g. `CN=<router-fqdn>`) — the
server owner needs it to authorize this router (Step 4).

---

## 5. Step 3 — Configure TLS syslog

```
logging tls-profile SYSLOG-TLS
 tls-version 1.2
 trustpoint client ROUTER-ID
!
logging host <SERVER-IP> transport tls port 6514 profile SYSLOG-TLS
logging source-interface <mgmt-interface>
logging trap informational
```

> **Older IOS without `logging tls-profile`:** use
> `logging host <SERVER-IP> transport tls port 6514` and bind the CA and
> identity trustpoints per that train's syntax. Consult the version's
> secure-logging documentation.

Set `logging trap` to the severity your site requires; `informational` captures
most operational events.

---

## 6. Step 4 — Send two items to the syslog server owner

The server **pins** which devices may connect, so before the router can be
accepted it needs from you:

1. The router's **client-certificate Subject / SAN** (e.g. `CN=<router-fqdn>`)
   — this is added to the server's allow-list.
2. The **source IP** the router will send from — for the server's firewall.

> Until the server owner adds your Subject to the allow-list, the router's
> connection is **refused by design**. That is the mutual-TLS check working,
> not a fault. Coordinate the cutover so both sides are ready.

---

## 7. Step 5 — Verify

On the router:

```
show logging                        ! the TLS host should show, state active
show crypto pki trustpoints status  ! both trustpoints should read "Valid"
```

The server owner confirms receipt on their side (established connection on
6514, and messages landing in the log files). Send a test event — e.g. a
config change or an interface flap — and confirm it arrives.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Connection refused / reset | Router not yet in the server allow-list, or firewall closed | Confirm the server owner added your cert Subject (Step 4) and opened 6514 to your source IP |
| Certificate validation failed | Router clock off, missing CA/intermediate, or FQDN mismatch | Check NTP, re-authenticate the full CA chain (Step 1), confirm the server name resolves and matches its cert |
| No matching cipher / TLS handshake failure | TLS version or cipher mismatch | Confirm `tls-version 1.2`+; check the server's allowed ciphers with its owner |
| Nothing arrives, no errors | `logging trap` too low, or wrong source interface/route | Raise `logging trap`, verify `logging source-interface` and the route to `<SERVER-IP>` |

---

## 9. If client certificates are not feasible

If this router cannot be issued an identity certificate, tell the server
owner. They can switch the collector to **server-authentication only** — the
session is still **encrypted in transit**, but the server no longer verifies
the router by certificate. In that mode:

- Do **Step 1** only (trust the server CA).
- **Skip Step 2** and omit the `trustpoint client` line in Step 3.

Mutual TLS is stronger and preferred; use this only when identity-cert
enrollment is not possible.

---

*Questions on the server side (endpoint, allow-listing, cipher policy) go to
the syslog server owner.*
