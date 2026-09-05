# Phosphor BASIC — networking roadmap (the next step after the opt-in packages)

The opt-in host packages are closed (see [roadmap-phase3.md](roadmap-phase3.md),
"Closure"): `base64`, `zip`, `http` (with multi-address fallback), and a
library-gated `sqlite`, each verified against reality on both operating systems.
*(`crt` and `gzip` landed just after this file was last edited, making six.)* Two
things were deliberately left out of the HTTP client, recorded not stubbed: **HTTPS**
and **IPv6 endpoints**. This file picks the next one and plans it.

## Decision — HTTPS before IPv6

Both are real gaps. They are not close in value or in cost.

| | **HTTPS** | **IPv6 endpoints** |
|---|---|---|
| Real-world value | **Decisive.** Almost the entire live web and virtually every API is HTTPS; plain `http://` is increasingly redirected away. Without TLS the client cannot reach most real endpoints. | **Marginal today.** IPv6-only hosts are still rare; nearly everything publishes an A record. The common "first IP is dead" failure is *already* handled by the multi-address fallback that just shipped. |
| Implementation cost | **Low.** FPC already speaks TLS through a pluggable socket handler; `TFPHTTPClient` drives `https://` once an OpenSSL-backed handler is registered (adding the `opensslsockets` unit). No hand-rolled protocol code. | **High.** FPC 3.2.2's `TInetSocket` is `AF_INET`-only (proven in the socket source), so IPv6 means a hand-rolled `AF_INET6` connect (Winsock vs BSD sockets, `getaddrinfo` for AAAA) spliced into a client that assumes its own IPv4 socket — a substantial, low-level, cross-platform change. |
| Testability against reality | A local TLS server on loopback (self-signed cert) proves it with no external network — the same pattern the HTTP test already uses, **library-gated** where OpenSSL is absent (exactly like `sqlite`). | Needs a reachable IPv6 peer. `::1` loopback can prove the socket path, but the environment's public IPv6 is flaky (observed), so end-to-end reality checks are unreliable. |
| Risk | Contained: known FPC seam; unknowns are cert generation, default verification, and SNI-under-pinning (all listed below). | Larger: reimplementing connection setup risks regressing the working IPv4 path. |

**HTTPS wins on every axis** — far higher value, far lower cost, cleanly testable
against reality. IPv6 is deferred (its rationale and sketch are kept at the end so it
is not lost). The fallback already blunts IPv6's main practical benefit.

## HTTPS — the plan

Delivered the same way as every package: verify against reality, byte-exact on both
OSes, library-gated where the runtime dependency is absent, no stubs.

### Step 1 — the client speaks TLS  *(DONE 2026-09-01)*

Added the OpenSSL-backed socket handler so `TFPHTTPClient` handles `https://`: a
single `uses` line (`opensslsockets` self-registers as the default handler) and a
guard so https uses the plain resolve-and-dial path (not the IP-pinning fallback,
which would feed the TLS layer an IP for SNI/verification — reconciled in Step 3).
`PhosphorHttpLib` keeps the same three functions; the URL scheme, not a new API,
selects TLS.

- **Gate — MET, both OSes.** Reality spot-check: `http_status("https://example.com/")`
  → 200, `http_get$` → a real 559-byte body, on **Windows** (OpenSSL 1.1 DLLs from the
  toolchain) **and the Linux VM**. Plain http is unaffected (full package suite still
  green, `03_http` byte-exact).
- **Cross-platform OpenSSL loading — a real gotcha, fixed.** The VM ships only OpenSSL
  **3** (`libssl.so.3`), and FPC 3.2.2's loader never tries the `.so.3` soname (its
  list stops at `.1.1`/`.1.0.x`/`.0.9.x`), so https loaded on Windows but failed on the
  VM with a bare status 0 even though `curl` there does https and the library is
  installed. OpenSSL 3 kept the 1.1 API this client uses, so `PhosphorHttpLib`'s
  initialization teaches the loader the `.3` soname (claims the oldest dead slot of
  `openssl.DLLVersions`; Unix-only, Windows loads by DLL name). https then works on the
  VM too.
- **Unknown — RESOLVED, and it matters.** FPC's default OpenSSL handler does **NOT
  verify** the peer certificate: `expired`, `self-signed`, and `wrong.host`
  `badssl.com` *all* returned 200. So TLS here encrypts but does not authenticate —
  a real MITM footgun. Two consequences: Step 2's self-signed local server needs no
  trust configuration (the client accepts it as-is), and shipping HTTPS is not "done"
  until verification is addressed (Step 1b).

### Step 1b — certificate verification  *(DONE 2026-09-01)*

**Decision (owner):** a shipping HTTP client must **verify certificates by default** —
silently accepting a forged, expired, or wrong-host certificate defeats the point of
TLS. Done: `PhosphorHttpLib` overrides `GetSocketHandler` (the seam where the TLS
handler is born) to set `VerifyPeerCert` and hand it a CA bundle, auto-located at
startup from the usual Unix paths (`/etc/ssl/certs/ca-certificates.crt`, …). With
`SSL_VERIFY_PEER` plus a loaded CA store, `SSL_connect` itself fails on an expired,
self-signed, or untrusted-CA certificate. `http_verify_peer(0)` is the explicit
opt-out (for a self-signed dev server) — **process-wide, not per request**: it sets a
unit-global that stays off until it is set back on, so a program that turns it off
for one call must turn it on again itself. `http_ca_file$(path$)` points at
a specific bundle. A box with no system bundle (Windows) fails **closed** — https
refused until a bundle is supplied or verification is opted out — never a silent
trust-all.

- **Gate — MET.** With a real CA bundle the badssl probe inverts as intended:
  `example.com` → 200 (valid cert accepted), `expired`/`self-signed` → 0 (refused).
  Deterministic proof is Step 2.
- **Known gap, recorded:** this validates the certificate **chain**, not the
  **hostname** — `wrong.host.badssl.com` (a valid cert for another name) still returns
  200. Hostname verification (an `OnVerifyCertificate` `X509_check_host`, or setting
  the verify host param) is the next refinement; chain validation is the bulk of the
  MITM protection and lands first.

### Step 2 — the permanent test: a local TLS server, library-gated  *(DONE 2026-09-01)*

`phosphorhttptest` now stands up a **second server over TLS** on loopback
(`127.0.0.1:18443`), same routes, with a **checked-in self-signed certificate** —
`tests/packages/tls_test_cert.pem` and `tls_test_key.pem`, loaded into
`CertificateData`, so the fixture is the same bytes on every machine and no
`openssl` CLI is needed at test time. `server_url_https$()` hands the test its URL.

- **`tests/packages/04_https` (7 asserts)** proves BOTH halves with no external
  network: with verification on (default) the self-signed cert is **refused**
  (status 0, empty body); after `http_verify_peer(0)` the same server answers GET
  body / `/json` / POST-echo over TLS; re-enabling verification refuses it again.
- **Library-gate.** The runner's `--openssl-check` mode reports (via exit code)
  whether it can load OpenSSL, so the suite gates on exactly what the runner can do:
  present → run `04_https` byte-exact, absent → **SKIP** with the honest message.
  `test-packages.{ps1,sh}` gained the probe and route the `*https*` test to
  `phosphorhttptest`.
- **Gate — MET, both OSes.** Full suite green on Windows (`00_base64`/`01_zip`/
  `03_http`/`04_https` PASS, `02_sqlite` SKIP) and on the Linux VM (all five PASS);
  `-B -vewn` clean. Two Unix-only gotchas fixed along the way: an aborted TLS handshake
  raised **SIGPIPE** (default action kills the process → exit 141) until the runner
  ignored it, and FPC 3.2.2's in-process cert generation is **broken on OpenSSL 3**, so
  the server loads a **checked-in self-signed fixture** (`tls_test_cert.pem`) instead of
  generating one.

### Step 3 — reconcile the multi-address fallback with TLS (refinement)

The fallback pins the connect target to a specific IP while keeping the hostname in
`Host:`. Over TLS the handshake also needs the **hostname** — for SNI and for
certificate hostname verification — even though the socket dials an IP. Confirm FPC's
handler takes SNI/verification host from the request URL (the hostname), not the
pinned connect IP; if it takes the IP, set the peer hostname explicitly on the socket
handler. Until confirmed, HTTPS uses the plain (resolve-first-A, no pin) path and the
fallback stays an HTTP enhancement — correctness before breadth.

- **Gate:** a deterministic local proof that HTTPS still succeeds when the first
  candidate address is dead (the `127.0.0.9,127.0.0.1` trick, now against the TLS
  server) with the certificate still validating against the hostname.

### Out of scope for this step

Client certificates and proxy-tunnelled TLS (`CONNECT`) — real features, but past
"the client can fetch an HTTPS URL". Recorded for later, not built speculatively.
*(A custom CA bundle was on this list and then built: `http_ca_file$(path$)` points
verification at a specific PEM, as the step above describes.)*

## IPv6 — deferred (recorded, not dropped)

Kept here so the decision is traceable. FPC 3.2.2's `TInetSocket.Connect` is
`AF_INET`-only, so IPv6 support means, roughly: resolve AAAA records (`getaddrinfo`),
open an `AF_INET6` socket, connect it, and hand that connected socket to
`TFPHTTPClient` — which today creates its own IPv4 socket internally, so this needs a
custom socket-handler seam (`OnGetSocketHandler`) or a small reimplementation of the
connection setup, written twice for Winsock and BSD sockets. It would slot into the
existing address-fallback loop as just more candidate addresses (try IPv6 then IPv4,
or interleave). Revisit when an IPv6-only endpoint is actually in the requirements, or
alongside a broader socket-layer rework — after HTTPS, which most callers need first.
The shipped multi-address fallback already covers the frequent real failure (a host's
first advertised address being unreachable), which is what made IPv6 look urgent in
the first place.
