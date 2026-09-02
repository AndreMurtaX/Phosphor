# Phosphor BASIC — networking roadmap (the next step after the opt-in packages)

The opt-in host packages are closed (see [roadmap-phase3.md](roadmap-phase3.md),
"Closure"): `base64`, `zip`, `http` (with multi-address fallback), and a
library-gated `sqlite`, each verified against reality on both operating systems. Two
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

### Step 1 — the client speaks TLS

Add the OpenSSL-backed socket handler so `TFPHTTPClient` handles `https://`. In FPC
this is a `uses` line — `opensslsockets` registers itself as the default handler; the
client picks TLS automatically for `https` URLs. `PhosphorHttpLib` keeps the same
three functions (`http_get$`/`http_status`/`http_post$`) — they gain HTTPS for free
because a URL's scheme, not a new API, selects it.

- **Gate:** a one-off reality spot-check (like the HTTP one) — `http_status`/
  `http_get$` against a real public HTTPS host returns 200 with a real body — proving
  TLS + certificate trust work end to end over real network. (Spot-check only; not a
  permanent test — see Step 2 for the deterministic one.)
- **Unknown to resolve first:** whether FPC's default handler verifies the peer
  certificate, and against what. This decides whether the public spot-check needs the
  system trust store and whether Step 2's self-signed server needs verification turned
  off.

### Step 2 — the permanent test: a local TLS server, library-gated

Stand up a TLS server on loopback in the test runner (extend `phosphorhttptest`, or a
sibling `phosphorhttpstest`) and drive real HTTPS requests at it — no external
network, deterministic, byte-exact.

- **Self-signed certificate.** Prefer generating it in-process (FPC's X.509 API) so
  the test needs no files and no `openssl` CLI; fall back to a checked-in throwaway
  cert/key pair under `tests/packages/` only if in-process generation proves fiddly.
  The cert is a test fixture, never a real credential.
- **Client trusts the test cert.** Point the client's verification at the test cert
  (or disable verification *for this local test only*, via the socket-handler seam) so
  a self-signed loopback cert is accepted deliberately — never a blanket "trust
  everything" in the shipping package.
- **Library-gate.** Detect OpenSSL at runtime (as `sqlite` detects `libsqlite3`):
  present on the Linux VM → run `04_https` byte-exact; absent on this Windows box (no
  `libssl`/`libcrypto` DLLs) → **SKIP** with the honest message, never a fake pass.
  `test-packages.{ps1,sh}` gain the probe + the `*https*` route to its runner.
- **Gate:** `tests/packages/04_https` (GET body, status codes, POST echo — mirrors
  `03_http`) byte-exact where OpenSSL is present; SKIP where absent; `-B -vewn` clean;
  the other three packages still green; committed and cross-verified on the VM.

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

Client certificates, custom CA bundles, and proxy-tunnelled TLS (`CONNECT`) — real
features, but past "the client can fetch an HTTPS URL". Recorded for later, not built
speculatively.

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
