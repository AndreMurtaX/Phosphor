# http — fetch a URL, and build the request that will fetch it

`host/packages/PhosphorHttpLib.pas` · 61 functions · opt-in host package (the
`phosphor` console host links it; a host that never calls `RegisterHttpFuncs`
has none of these names)

## What it is for

Three functions reach the network: `http_get$` gives you a body, `http_status`
gives you a code, `http_post$` sends one and gives you the answer. The same three
serve `http://` and `https://` — **the URL scheme selects TLS, there is no second
API**. Plain HTTP needs nothing external; `https://` needs the OpenSSL runtime, so
a host that never fetches https carries no dependency.

The other fifty-seven never touch the network, and that is the point the unit
header makes: **a request is a bag of settings until a verb is called**. Building a
client, naming its headers, filling in a form, percent-encoding a string — all of
it is offline, and all of it is most of an HTTP library. A client handle
(`http_client@`) is a pure config accumulator with its own record, validated
through `PhosphorHandles` like every other Phosphor handle, so a fabricated or
stale id is *refused* rather than dereferenced.

Two design stances shape the answers. First, **nothing here raises**: a 404 is a
value the program inspects, not an exception; `http_get$` and `http_post$` return
the body of *any* status (the error page's body too), and `http_status` returns 0
only when the request could not complete at all. Second, **a failure is a value in
the ioerror/valcode shape**: every config op on a live handle clears `http_error()`
to 0, every op on a bad handle sets it to 1 and answers the empty answer for its
type — `0` for a number, `""` for a string. No config op ever fails loudly.

**A client is used by handing it to a verb.** The same three verbs take a client
handle and a path — `http_get$(c@, path$)`, `http_status(c@, path$)`,
`http_post$(c@, path$, body$)` — and everything configured on the handle goes on
the wire: the request url is the base url and the path joined by one `/` (or the
path alone when it is absolute), with the params url-encoded as its query; the
headers, cookies, auth, user agent, accept and content type are sent; the connect
and response timeouts, the redirect policy and the proxy are applied. Until
2026-10-06 no verb took a handle, so all of that stayed in the accumulator —
and a program that set a proxy had its requests go out direct. TLS is verified
only when the process-global `http_verify_peer` **and** the client's
`http_validatessl` both ask for it, so either one can opt out and neither can
switch the other back on.

**A proxy the client cannot honour is a refusal, never a detour.** The proxy is
plain HTTP: an `https://` request through one would need `CONNECT`, which FPC's
client does not have, so it is refused and nothing is sent; so is a proxy whose
port is not 1–65535, which the RTL would otherwise ignore and go direct. Either
way the verb answers its empty answer and `http_error()` is `2`.

## Functions

**The uniform failure answer.** Every function below that takes a client `c@` or a
form `f@` behaves the same way when the handle is fabricated, already freed, or of
the wrong kind: it does nothing, answers `0` (or `""` for a `$` name), and sets
`http_error()` to `1`. On a live handle it answers as described and clears
`http_error()` to `0`. Only the rows where that leaves something ambiguous say so
again.

### Requests, and the process-global TLS posture

| function | what it answers |
| --- | --- |
| `http_get$(url$) → str` | GET `url$`; the response body, whatever the status — an error page's body included. `""` when the request never completed, which is also what an empty 200 answers: pair it with `http_status` to tell those apart |
| `http_status(url$) → num` | GET `url$`; the HTTP status code. `0`, and only `0`, when nothing connected — a dead host, a refused connection, a rejected certificate |
| `http_post$(url$, body$) → str` | POST `body$` to `url$`; the response body, on the same terms as `http_get$` |
| `http_get$(c@, path$) → str` | GET `path$` on the client's base url, with everything the client carries; the body on the same terms as `http_get$(url$)`. `""` with `http_error()` `1` for a bad handle and `2` for a proxy it cannot use |
| `http_status(c@, path$) → num` | the same request, answering its status; `0` when nothing connected or nothing was sent. Under a host that sets an execution budget, a query built from more params than the budget allows is a runtime error, the same refusal for all three client verbs |
| `http_post$(c@, path$, body$) → str` | POST `body$` the same way; the client's content type, if set, goes with it |
| `http_verify_peer(on) → num` | turn https certificate verification on (the default) or off, for the whole process; answers the value it set (`1`/`0`). `0` is the explicit opt-out for a self-signed dev server, never the default Off means off for the **name** as well as the chain. |
| `http_ca_file$(path$) → str` | verify against this CA bundle (PEM); answers `path$` back, unchanged and unchecked — a path that does not exist is accepted here and shows up later as a failed connection |

### The client handle

| function | what it answers |
| --- | --- |
| `http_client@() → handle` / `http_client@(url$) → handle` | a new client, empty or carrying `url$` as its base url. Always succeeds |
| `http_free(c@) → num` | `1` when the client was live and is now released; `0` if it was already freed or was never a client |
| `http_reset(c@) → num` | `1`; the client returns to the factory state — bags emptied, timeouts `0`, redirects followed with a cap of 5, SSL validation on, auth and proxy cleared. **The base url survives a reset**: it is the client's identity, not one of its settings |
| `http_baseurl$(c@) → str` | its base url, `""` when it has none |
| `http_baseurl(c@, u$) → num` | `1`; the base url is now `u$` |
| `http_timeout(c@) → num` | the connect timeout in ms; `0` means none was set |
| `http_timeout(c@, ms) → num` | `1`; the connect timeout is now `ms` |
| `http_responsetimeout(c@, ms) → num` | `1`; the response timeout is now `ms`. Write-only — there is no getter |

### Headers, query parameters and cookies

Three name/value bags with the same shape. **Setting a name that is already there
replaces it** — the count does not grow and no duplicate is sent. Header names
match case-insensitively (the HTTP rule); parameter and cookie names match exactly.
An empty value is a stored value, so it counts, but the getter cannot tell it from
a name that was never set.

| function | what it answers |
| --- | --- |
| `http_headercount(c@) → num` | how many headers are set; `0` for an empty bag *and* for a bad handle — `http_error()` separates the two |
| `http_header(c@, name$, value$) → num` | `1`; the header is set, replacing any earlier value under that name |
| `http_header$(c@, name$) → str` | its value; `""` when the name was never set, when it was set to `""`, or when the handle is bad |
| `http_headerremove(c@, name$) → num` | `1` when a header of that name was there and is now gone, `0` when there was nothing to remove — and `0` again for a bad handle |
| `http_headerclear(c@) → num` | `1`; every header is gone |
| `http_paramcount(c@) → num` | how many query parameters are set |
| `http_param(c@, name$, value$) → num` | `1`; the parameter is set, replacing any earlier one |
| `http_param$(c@, name$) → str` | its value, `""` when unset |
| `http_paramremove(c@, name$) → num` | `1` when one was removed, `0` when there was none |
| `http_paramclear(c@) → num` | `1`; every parameter is gone |
| `http_cookiecount(c@) → num` | how many cookies are set |
| `http_cookie(c@, name$, value$) → num` | `1`; the cookie is set, replacing any earlier one |
| `http_cookie$(c@, name$) → str` | its value, `""` when unset |
| `http_cookieremove(c@, name$) → num` | `1` when one was removed, `0` when there was none |
| `http_cookieclear(c@) → num` | `1`; every cookie is gone |

### Authentication and proxy

Auth is **write-only by design**: nothing reads a credential back out of a client,
so a `1` is the only confirmation there is.

| function | what it answers |
| --- | --- |
| `http_basicauth(c@, user$, pass$) → num` | `1`; the client now carries `Basic <base64 of user:pass>` |
| `http_bearerauth(c@, token$) → num` | `1`; the client now carries `Bearer <token$>` |
| `http_customauth(c@, value$) → num` | `1`; the client carries `value$` as the whole Authorization value, unexamined |
| `http_clearauth(c@) → num` | `1`; whichever of the three was set is gone |
| `http_proxy(c@, host$, port) → num` | `1`; the proxy is recorded, and checked when a request is made: a port outside 1–65535, or an `https://` request, is refused there with `http_error()` `2` |
| `http_proxyauth(c@, user$, pass$) → num` | `1`; the proxy credentials are recorded, also write-only |
| `http_clearproxy(c@) → num` | `1`; host, port, user and password are all cleared |

### Behaviour flags

Each setter answers `1`; each getter answers the value. The getter and setter share
a name where the types allow it and are told apart by arity.

| function | what it answers |
| --- | --- |
| `http_useragent(c@, s$) → num` / `http_useragent$(c@) → str` | the User-Agent to send; `""` when none was set |
| `http_contenttype(c@, s$) → num` / `http_contenttype$(c@) → str` | the Content-Type to send; `""` when none was set |
| `http_accept(c@, s$) → num` / `http_accept$(c@) → str` | the Accept header to send; `""` when none was set |
| `http_followredirects(c@, on) → num` / `http_followredirects(c@) → num` | whether redirects would be followed; `1` on a factory-fresh client |
| `http_maxredirects(c@, n) → num` / `http_maxredirects(c@) → num` | the redirect cap; `5` on a factory-fresh client |
| `http_validatessl(c@, on) → num` / `http_validatessl(c@) → num` | this client's SSL-validation flag, `1` by default. It decides this client's handshakes together with the global `http_verify_peer`: verification — chain and name — is on only when both ask for it |
| `http_clientcert(c@, certfile$, keyfile$) → num` | the certificate this client presents when an https server asks for one (mutual TLS). PEM files; `keyfile$` `""` means the key is in `certfile$` too, and `certfile$` `""` removes the certificate (`http_reset` does too). Answers `1` when recorded, `0` for a bad handle (`http_error()` `1`) or a path the sandbox refuses (`ioerror()` `5`). A relative path means the file it names when it is recorded — it is made absolute then, and that is the path OpenSSL opens. Nothing is read until a request: a missing file, or a key that is not the certificate's, fails that request |

### Multipart forms

A form holds text fields (a bag, replace-on-duplicate) and file fields (a list, so
adding twice under the same field name gives you **two** entries). A file field
records a path; nothing is read from disk here.

| function | what it answers |
| --- | --- |
| `http_form@() → handle` | a new, empty form. Always succeeds |
| `http_formfield(f@, name$, value$) → num` | `1`; the text field is set, replacing any earlier one of that name |
| `http_formfile(f@, name$, path$) → num` | `1`; a file field for `name$`, sent under the disk file's own name. A path that does not exist is accepted now and only bites when the form is sent |
| `http_formfilenamed(f@, name$, path$, filename$) → num` | `1`; the same, sent under `filename$` instead |
| `http_formfiletype(f@, name$, path$, filename$, contenttype$) → num` | `1`; the same again, with `contenttype$` as the stated type |
| `http_formfieldcount(f@) → num` | how many text fields; `0` for an empty form and for a bad handle |
| `http_formfilecount(f@) → num` | how many file fields |
| `http_formurlencoded$(f@) → str` | the **text** fields as `a=1&b=2`, each half percent-encoded; `""` for an empty form and for a bad handle. File fields are skipped — a file has no url-encodable value — so a form of files alone renders as `""` |
| `http_formclear(f@) → num` | `1`; both text and file fields are gone, the handle stays usable |
| `http_formfree(f@) → num` | `1` when the form was live and is now released; `0` if it was already freed |

### Pure encoders

No handle, no network, no error code — these four are total functions on a string.

| function | what it answers |
| --- | --- |
| `http_urlencode$(s$) → str` | RFC-3986 percent-encoding: `A-Z a-z 0-9 - _ . ~` pass through, everything else becomes `%XX` in upper hex. A space is `%20`, **not** `+`, and a literal `+` is `%2B`, so the two can never collide on the way back |
| `http_urldecode$(s$) → str` | the reverse, byte-exact for non-ASCII (`%C3%A9` comes back as the two UTF-8 bytes of é). It still reads `+` as a space, so form-spelled data keeps working, while `%2B` still comes back as `+`. A malformed `%` escape is left literal |
| `http_htmlencode$(s$) → str` | escapes the five markup-significant characters: `& < > " '` (the last as `&#39;`) |
| `http_htmldecode$(s$) → str` | reverses those five, plus `&apos;` and `&#039;`, case-insensitively. **An entity it does not know is left exactly as it was**, not dropped |

### The error accessors

| function | what it answers |
| --- | --- |
| `http_error() → num` | the last code: `0` clean, `1` a bad client or form handle, `2` a request a client's proxy could not carry (nothing was sent), `3` an https request refused because the server's certificate is not for the host it was sent to. Every request — bare-url or client — sets it: `0` when it was not refused, `3` when it was. A 404, a dead host and an untrusted chain are still read from `http_status`, not from here |
| `http_clearerror() → num` | `0`, always; the code is reset to `0` |
| `http_strerror$(code) → str` | `"no error"` for `0`, `"invalid handle"` for `1`, `"the request cannot go through this proxy"` for `2`, `"the server's certificate is not for this host"` for `3`, `"unknown error"` for anything else — including a code this library would never produce |

## A worked example

A search request against a local service. The settings live on a client handle and
travel with it; only the two lines near the end touch the network.

```basic
rem The client carries the address, a header, a timeout and the query.

c@ = http_client@("http://127.0.0.1:8080")
http_timeout(c@, 5000)
http_header(c@, "X-Requested-With", "phosphor")
http_param(c@, "q", "phosphor basic")
http_param(c@, "page", "2")
if http_error() <> 0 then println "config refused: " + http_strerror$(http_error())

code = http_status(c@, "/search")      rem GET /search?q=phosphor%20basic&page=2
if code = 0 then
  println "nothing answered at " + http_baseurl$(c@)
else
  body$ = http_get$(c@, "/search")
  println "HTTP " + str$(code) + " -- " + str$(len(body$)) + " bytes"
  println http_htmldecode$(body$)
endif

http_free(c@)
```

Two things worth noticing:

- **That program makes two requests, not one.** `http_status` and `http_get$` each
  perform their own GET; there is no verb that hands back a code and a body
  together. When one round trip is all you can afford, take the body and treat `""`
  as "empty *or* unreachable", or take the code and accept that you gave up the
  body.
- **The params are the query.** They are url-encoded and appended in the order they
  were set, after a `?` — or after `&` when the path already carries a query of its
  own — so a program never pastes a query string together by hand.

## Notes / Where the rest lives

**HTTPS is verified by default, and that is a deliberate reversal.** FPC's OpenSSL
handler ships insecure — it accepts any certificate, expired, self-signed or issued
for another host, which is TLS that encrypts without authenticating. This library
turns verification on (`SSL_VERIFY_PEER` plus the system CA bundle, located at
startup) so a bad certificate makes the connection *fail* instead of silently
succeeding. Two consequences a caller meets in practice: a box with no CA bundle in
a standard place — Windows, notably — **fails closed** until `http_ca_file$` points
at a PEM; and a self-signed dev server needs an explicit `http_verify_peer(0)`,
which stays off for the whole process until something turns it back on.

**The certificate must also be for the host.** A valid chain is not enough — a
trusted CA issues certificates for every other host too. After the handshake the
certificate must name the host that was dialled: its DNS names (wildcards as
OpenSSL allows them) for a name, its IP addresses for a dotted quad such as
`https://127.0.0.1`. Otherwise the request fails, `http_status` answers `0`, and
`http_error()` answers `3` so a program can tell this refusal from a dead host.
After a redirect it is the new host that must be named. FPC does none of this,
and its one binding for reading the peer certificate answers nothing on OpenSSL 3,
so the check binds the OpenSSL functions it needs itself; on an OpenSSL that lacks
one of them, every verified request is **refused**, never waved through.
`http_verify_peer(0)` and `http_validatessl(c@, 0)` turn the name check off along
with the chain. On Windows the library prefers OpenSSL 3 — `libssl-3-x64.dll`
beside `libcrypto-3-x64.dll` — when both are on the DLL search path, and falls
back to the OpenSSL 1.1 names FPC knows; it never pairs halves of different
versions.

**IPv6 works, and IPv4 is still tried first.** A URL can name an IPv6 address —
`http://[::1]:8080/` or `https://[2001:db8::7]/` — and it is dialled as itself.
A host name is tried over IPv4 exactly as before, and its IPv6 (AAAA) addresses
only when no IPv4 address connected, so a host that already worked behaves the
same while one with only IPv6, or whose IPv4 is down, is now reached. Over https
the certificate must name the host: an IPv6 address is matched against the
certificate's addresses, and a name reached over IPv6 is still checked, and sent
as SNI, as the name. Through a proxy only the proxy is dialled, IPv6 or not, and
the name is not looked up locally either -- the proxy resolves it. The
addresses come from the system resolver on Linux and from Windows' own
`getaddrinfo` there. One bound: a dead IPv6 address costs the connect timeout
(five seconds, or the client's `http_timeout`) before the next is tried, the same
as a dead IPv4 one.

**A host name with several A records is tried in turn.** FPC's socket layer
resolves a host to its first A record and connects only to that one, so a single
dead IP fails a request that a round-robin CDN's other addresses would have served.
This library resolves them all and tries each until one connects, over `http://`
and `https://` alike: an https connect made to one of the addresses still sends
the NAME as SNI and checks the certificate against the name, never against the
address it dialled. (Until 2026-10-08 https dialled the name as written and so
only ever reached its first A record.) IPv6 is the paragraph above: a name's AAAA
addresses come after its A records. The reasoning is in
[roadmap-net.md](../roadmap-net.md).

**A redirect is a request of its own.** A client handle follows redirects (up to
`http_maxredirects`, five by default), and each hop goes through every rule a first
request does: the proxy, the certificate's name, IPv6, the choice of address. What
identifies the caller — the `Authorization` header, the cookies, and the client
certificate — goes only to the **origin** it was set up for, the first url's
scheme, host and port, all three: a redirect to another host, another port, or from
`https` to `http` arrives without them. A cookie a response sets goes on to the next
hop of the same origin, as `name=value`. A `303` turns the request into a `GET`
without a body; every other code keeps the method and the body. A redirect that is
not followed — a `Location` missing, a scheme other than http and https, one hop
past the cap — answers its own status with no body. And through a proxy, a hop to
`https` is refused like a first request: nothing is sent, `http_error()` `2`. Until
2026-10-07 the RTL followed redirects with none of this — a redirect to https
through a proxy was opened with the PROXY, which was handed the bearer token, and
credentials went to whatever host a redirect named. A bare url (`http_get$(url$)`)
never follows redirects.

**What counts as a host.** An address is text that parses as one: four decimal
numbers of 0..255 for IPv4, and for IPv6 what RFC 4291 writes inside the brackets,
`::ffff:a.b.c.d` (an IPv4 address written as IPv6, dialled as that IPv4 address)
included. A bracketed host that does not parse, a zone id, and the unspecified
address of either family (`0.0.0.0`, `[::]`) are refused before anything is dialled:
each used to be dialled as `::`, which Linux connects to this machine itself. A
name with a trailing dot, `localhost.`, is the same name, and is requested,
resolved and checked against the certificate without the dot -- Windows'
resolver knew the dotted form and Linux's hosts-file lookup does not; an address is never sent as SNI, a name always
is (RFC 6066). A path given to a client verb is a url of its own only when it
BEGINS with a scheme — `/go?to=http://x/` is a path whose query holds a url.

**Time.** A run with a time budget bounds a response as a whole, not only each read:
a server that trickles a byte a second is cut off when the run's time is gone. The
connect wait is whole seconds, rounded up, because the system's connect timeout is;
on Windows a REFUSED connect costs that whole wait before the next address is tried,
which is the RTL's connect and is bounded by the timeout either way.

The tests are `tests/packages/03_http.bas` (a real loopback server the runner
stands up), `tests/packages/04_https.bas` (a self-signed TLS server, proving both
that verification refuses it and that TLS works once relaxed) and
`tests/packages/08_http_offline.bas`, which covers the whole configuration surface
without a single request; `tests/packages/14_http_client.bas` sends that
configuration to the loopback server and reads back what arrived, through a proxy
as well.
