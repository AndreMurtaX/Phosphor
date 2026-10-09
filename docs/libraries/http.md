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

**Nothing reaches the request head that its grammar does not allow.** A header
value may carry visible characters, spaces and HTAB, and no other control
character (0x00–0x1F, 0x7F; RFC 9110 §5.5); a header name is a token (RFC 9110
§5.1: letters, digits and ``!#$%&'*+-.^_`|~``); a cookie name or value carries no
control character at all, HTAB included (RFC 6265 §4.1.1); a url carries none
either. A setter given something else — `http_header`, `http_cookie`,
`http_useragent`, `http_accept`, `http_contenttype`, `http_bearerauth`,
`http_customauth`, `http_baseurl` — **refuses**: it answers `0`, stores nothing (an
earlier value stays), and `http_error()` is `6`. A verb given such a url, by
argument, through a client's base url or path, or by a redirect's `Location`,
**sends nothing**: status `0`, no body, `http_error()` `6`. What is encoded on its
way out cannot carry a control character to the wire and is accepted as it is: a
param (percent-encoded, CR as `%0D`), basic and proxy credentials (base64). Until
2026-10-09 every one of those strings was written into the head as given, so a CR
LF in a header value, a cookie, a token or the url put one more header line in
front of the server.

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
`http_error()` to `0` — except a setter refusing a value that may not go on the
wire (above), which answers `0` and sets it to `6`. Only the rows where that leaves
something ambiguous say so again.

### Requests, and the process-global TLS posture

| function | what it answers |
| --- | --- |
| `http_get$(url$) → str` | GET `url$`; the response body, whatever the status — an error page's body included. `""` when the request never completed, which is also what an empty 200 answers: pair it with `http_status` to tell those apart |
| `http_status(url$) → num` | GET `url$`; the HTTP status code. `0`, and only `0`, when nothing connected — a dead host, a refused connection, a rejected certificate, or a url that was never sent: one carrying a control character (`http_error()` `6`), or one whose port is not 1–65535, or one whose host or port RFC 3986 and the client's own parser would read differently (see below) |
| `http_post$(url$, body$) → str` | POST `body$` to `url$`; the response body, on the same terms as `http_get$` |
| `http_get$(c@, path$) → str` | GET `path$` on the client's base url, with everything the client carries; the body on the same terms as `http_get$(url$)`. `""` with `http_error()` `1` for a bad handle and `2` for a proxy it cannot use |
| `http_status(c@, path$) → num` | the same request, answering its status; `0` when nothing connected or nothing was sent. Under a host that sets an execution budget, a query built from more params than the budget allows is a runtime error, the same refusal for all three client verbs |
| `http_post$(c@, path$, body$) → str` | POST `body$` the same way; the client's content type, if set, goes with it |
| `http_verify_peer(on) → num` | turn https certificate verification on (the default) or off, for the whole process; answers the value it set (`1`/`0`). `0` is the explicit opt-out for a self-signed dev server, never the default Off means off for the **name** as well as the chain. |
| `http_ca_file$(path$) → str` | verify against this CA bundle (PEM); answers `path$` back, and `ioerror()` `0`. A path that does not exist is accepted here and shows up later as a failed connection. Under a sandbox a path outside the root is refused: the answer is `""`, `ioerror()` is `5`, and the bundle recorded before stays — OpenSSL opens this file, so the setter asks the gate, as `http_clientcert` does |

### The client handle

| function | what it answers |
| --- | --- |
| `http_client@() → handle` / `http_client@(url$) → handle` | a new client, empty or carrying `url$` as its base url. Always succeeds |
| `http_free(c@) → num` | `1` when the client was live and is now released; `0` if it was already freed or was never a client |
| `http_reset(c@) → num` | `1`; the client returns to the factory state — bags emptied, timeouts `0`, redirects followed with a cap of 5, SSL validation on, auth and proxy cleared. **The base url survives a reset**: it is the client's identity, not one of its settings |
| `http_baseurl$(c@) → str` | its base url, `""` when it has none |
| `http_baseurl(c@, u$) → num` | `1`; the base url is now `u$`. `0` and `http_error()` `6` for a `u$` carrying a control character, and the old base url stays. (`http_client@(url$)` always answers a handle; a verb on it refuses such a url) |
| `http_timeout(c@) → num` | the connect timeout in ms; `0` means none was set |
| `http_timeout(c@, ms) → num` | `1`; the connect timeout is now `ms` |
| `http_responsetimeout(c@, ms) → num` | `1`; the response timeout is now `ms`. Write-only — there is no getter |

### Headers, query parameters and cookies

Three name/value bags with the same shape. **Setting a name that is already there
replaces it** — the count does not grow and no duplicate is sent. Header names
match case-insensitively (the HTTP rule); parameter and cookie names match exactly.
An empty value is a stored value, so it counts, but the getter cannot tell it from
a name that was never set. A header or cookie that may not go on the wire (see
"Nothing reaches the request head" above) is refused: `0`, nothing stored,
`http_error()` `6`. A param is percent-encoded on the way out, so any byte is
accepted.

| function | what it answers |
| --- | --- |
| `http_headercount(c@) → num` | how many headers are set; `0` for an empty bag *and* for a bad handle — `http_error()` separates the two |
| `http_header(c@, name$, value$) → num` | `1`; the header is set, replacing any earlier value under that name. `0` and `http_error()` `6` when `name$` is not a token or `value$` carries a control character other than HTAB |
| `http_header$(c@, name$) → str` | its value; `""` when the name was never set, when it was set to `""`, or when the handle is bad |
| `http_headerremove(c@, name$) → num` | `1` when a header of that name was there and is now gone, `0` when there was nothing to remove — and `0` again for a bad handle |
| `http_headerclear(c@) → num` | `1`; every header is gone |
| `http_paramcount(c@) → num` | how many query parameters are set |
| `http_param(c@, name$, value$) → num` | `1`; the parameter is set, replacing any earlier one |
| `http_param$(c@, name$) → str` | its value, `""` when unset |
| `http_paramremove(c@, name$) → num` | `1` when one was removed, `0` when there was none |
| `http_paramclear(c@) → num` | `1`; every parameter is gone |
| `http_cookiecount(c@) → num` | how many cookies are set |
| `http_cookie(c@, name$, value$) → num` | `1`; the cookie is set, replacing any earlier one. `0` and `http_error()` `6` when either carries a control character, HTAB included |
| `http_cookie$(c@, name$) → str` | its value, `""` when unset |
| `http_cookieremove(c@, name$) → num` | `1` when one was removed, `0` when there was none |
| `http_cookieclear(c@) → num` | `1`; every cookie is gone |

### Authentication and proxy

Auth is **write-only by design**: nothing reads a credential back out of a client,
so a `1` is the only confirmation there is — and a `0` with `http_error()` `6` the
only sign a token was refused, in which case the one set before it is still sent.

| function | what it answers |
| --- | --- |
| `http_basicauth(c@, user$, pass$) → num` | `1`; the client now carries `Basic <base64 of user:pass>` — base64, so any byte is accepted |
| `http_bearerauth(c@, token$) → num` | `1`; the client now carries `Bearer <token$>`. `0` and `http_error()` `6` for a token carrying a control character other than HTAB |
| `http_customauth(c@, value$) → num` | `1`; the client carries `value$` as the whole Authorization value, examined only for control characters: one other than HTAB is refused like a bearer token's |
| `http_clearauth(c@) → num` | `1`; whichever of the three was set is gone |
| `http_proxy(c@, host$, port) → num` | `1`; the proxy is recorded, and checked when a request is made: a port outside 1–65535, or an `https://` request, is refused there with `http_error()` `2` |
| `http_proxyauth(c@, user$, pass$) → num` | `1`; the proxy credentials are recorded, also write-only, and sent base64-encoded, so any byte is accepted |
| `http_clearproxy(c@) → num` | `1`; host, port, user and password are all cleared |

### Behaviour flags

Each setter answers `1`; each getter answers the value. The getter and setter share
a name where the types allow it and are told apart by arity. The user agent,
content type and accept are header values: one carrying a control character other
than HTAB is refused — `0`, the earlier value kept, `http_error()` `6`.

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
| `http_error() → num` | the last code: `0` clean, `1` a bad client or form handle, `2` a request a client's proxy could not carry (nothing was sent), `3` an https request refused because the server's certificate is not for the host it was sent to, `4` a request the run's time cut off mid-handshake or mid-response, `5` a response that broke off for any other reason — the peer went silent past the client's own read timeout, or the connection dropped. Either way it answers status `0` and no body, never the part that had arrived. `6` a header, cookie, credential or url that may not go on the wire — a control character, or a header name that is not a token — refused by its setter (nothing stored) or by a verb (nothing sent, status `0`). Every request — bare-url or client — sets it: `0` when it was not refused or cut off. A 404, a dead host and an untrusted chain are still read from `http_status`, not from here |
| `http_clearerror() → num` | `0`, always; the code is reset to `0` |
| `http_strerror$(code) → str` | `"no error"` for `0`, `"invalid handle"` for `1`, `"the request cannot go through this proxy"` for `2`, `"the server's certificate is not for this host"` for `3`, `"the run's time ran out before the answer was complete"` for `4`, `"the answer broke off before it was complete"` for `5`, `"a header, cookie or url carries a control character"` for `6`, `"unknown error"` for anything else — including a code this library would never produce |

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
  own — so a program never pastes a query string together by hand. They go before
  a `#fragment`, which is never sent: `/q?x=2#top` asks for `/q?x=2&a=1`. (Until
  2026-10-09 they were appended after it, inside the fragment, and lost.)

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
as a dead IPv4 one. An AAAA answer that is an IPv4-mapped address (`::ffff:a.b.c.d`)
is that IPv4 address and is dialled as one, exactly as the same address written
in a URL is; until 2026-10-08 it was dialled as IPv6, which Windows refuses.

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

**A relative `Location` is resolved as RFC 3986 §5.2 says, on the text as the
server wrote it.** Its path and query are copied, never decoded: `g?a=1%262`
against `/b/c/d;p?q` is asked for as `/b/c/g?a=1%262`, and `%2B`, `%2F`, `%3D`,
`%20` stay what they were. Dot segments are removed (§5.2.4) — only literal ones;
`%2E%2E` is a name. Until 2026-10-09 FPC's resolver decoded the reference and
re-encoded the result, so that request went out as `/b/c/g?a=1&2`, another query.
A hop whose url carries a control character is refused like a first url
(`http_error()` `6`, nothing sent), and so is a hop whose port is not 1–65535 or
whose authority the two parsers read differently; a hop's fragment is never sent.
**Cookie names match exactly** across a redirect too (RFC 6265 §5.3): `SID` and
`sid` are two cookies, and a server's `THEME` does not replace the client's own
`theme`. A `Set-Cookie` carrying a control character other than HTAB is ignored
whole (RFC 6265bis §5.6), so it never reaches the next hop.

**What counts as a host.** An address is text that parses as one: four decimal
numbers of 0..255 for IPv4, and for IPv6 what RFC 4291 writes inside the brackets,
`::ffff:a.b.c.d` (an IPv4 address written as IPv6, dialled as that IPv4 address,
and over https checked against the certificate AS that IPv4 address) included. A bracketed host that does not parse, a zone id, and the unspecified
address of either family (`0.0.0.0`, `[::]`) are refused before anything is dialled:
each used to be dialled as `::`, which Linux connects to this machine itself. A
name with a trailing dot, `localhost.`, is the same name, and is requested,
resolved and checked against the certificate without the dot -- Windows'
resolver knew the dotted form and Linux's hosts-file lookup does not; an address is never sent as SNI, a name always
is (RFC 6066). A path given to a client verb is a url of its own only when it
BEGINS with a scheme — `/go?to=http://x/` is a path whose query holds a url.
**A port is a decimal of 1–65535**, leading zeros allowed; anything else written
after the host's `:` — `0`, `65536`, `99999999999`, `8o` — is refused before
anything is dialled, exactly as an unusable host is: status `0`, no body,
`http_error()` `0`. An empty port, `http://h:/`, is RFC 3986's "no port" and means
the scheme's default: the url is sent as `http://h/` (§6.2.3). Until 2026-10-09 the
port was kept in 16 bits, so port `A + 65536` reached a server listening on `A`,
and `:0` meant the default; and until round 2 that day an empty port was refused
in practice (sent on, through a proxy, as the host `h:`), because the client's
parser read `h:` as the host.

**The url judged is the url dialled.** Two parsers read a url: RFC 3986, which
ends the authority at the FIRST `/`, `?` or `#`, and FPC's `ParseURI`, which the
client dials with and which cuts at the LAST `#` and the LAST `?` before it looks
for the authority. With a `?` or `#` before an `@` they read different hosts:
`http://127.0.0.1:1?@127.0.0.1:(A+65536)?` is port 1 to the RFC and port `A` to
`ParseURI`. So the **fragment** — everything from the first `#` (RFC 3986 §3.5) —
is removed before the client sees the url, on every verb and every redirect hop
(with two `#`, the text between them used to reach the request line), and a url
on which the two readings still differ in scheme, userinfo, host or port is
refused like a bad port: status `0`, nothing dialled, `http_error()` `0`. So is an
authority with two `@` (a userinfo holds none, §3.2.1) and a `[` host that is not
closed by `]` and followed by nothing or `:`.

**The request target is the url's path and query, as written.** The request line
carries exactly the text between the authority and the fragment — `/` when the
path is empty (RFC 9112 §3.2.1), and through a proxy that text behind the scheme
and authority. Nothing is decoded, re-encoded or normalised: a `:`, `@`, `;`, `=`
or `%3A` in any segment goes out as it stands, a `.` or `..` segment is sent for
the server to resolve (as `curl --path-as-is` does — a request url is not a
reference being resolved; a redirect's `Location` is, and is resolved by RFC 3986
§5.2), and an empty query keeps its `?` (§6.2.3). Until round 3 of 2026-10-09 the
client rebuilt the line from its own parser's pieces and appended a `/` after a
last segment holding a `:` or a dot segment — `/v1/items:batchGet` was asked for as
`/v1/items:batchGet/`, `/a:b?q` as `/a:b/?q` — and dropped an empty query's `?`,
all with status `200` and no error.

**Time.** A run with a time budget bounds a response as a whole, not only each read:
a server that trickles a byte a second is cut off when the run's time is gone. The
connect wait is whole seconds, rounded up, because the system's connect timeout is;
on Windows a REFUSED connect costs that whole wait before the next address is tried,
which is the RTL's connect and is bounded by the timeout either way. **The run's
remaining time is ONE deadline for the whole request**, however many addresses a
name has: an address is not started once it has passed, and each is given only what
is left of it. (Until 2026-10-08 every address was handed the whole allowance
again, so six addresses that stalled the handshake held a run six times its bound.)
The deadline covers the **TLS handshake** too, which OpenSSL reads on its own: a
peer that trickles one held a run for as long as it liked. A request cut off by it
answers status `0`, no body and `http_error()` `4` — a truncated body used to come
back as a complete-looking `200`. And **the wait is charged to the run's budget**,
at the price `pause()` pays for a millisecond: a budget measured in steps did not
move while the network waited, so each request was handed the whole allowance
again and two slow ones held a run twice its bound. The request whose wait spends
the budget answers the budget's own refusal, as `pause()` does, and a request after
that dials nothing.

**One deadline means every wait in the request**, not only the first: each read and
each send is bounded by what is left of it, and inside https the reads OpenSSL makes
on its own are too — a TLS record trickled a byte at a time used to hold a
one-second request eleven. And **an answer that broke off is no answer, however it
broke off**: a body short of its `Content-Length`, a chunked body before its last
chunk, or headers cut by the close answer status `0`, no body and `http_error()`
`5`, even when the peer simply closed. (A body with neither a length nor chunking
ends at the close, and is complete when that close is a clean one — over https,
a `close_notify` first. A TLS stream that just stops is what RFC 9112 §9.8 calls an
*incomplete close*: it cannot be told from a body cut short by anyone on the path,
so it answers `5`.) `4` and `5` are told apart by what failed — a read that timed
out under the deadline is `4`; a reset, even a moment before the deadline, is `5`.

All of that is held by a **generated** sweep, `tests/http_sweep.py`, which the
package runners run: four response shapes, cut at every structural point (inside
the status line, inside a header, before the blank line, after it, inside the
body or a chunk, whole), each ended by a clean close, a reset, silence, and over
https an abrupt close — and each of those twice: under the run's deadline, as a
budgeted host runs it, and with no deadline and the client's own response
timeout, as the console host runs a script. 356 cases, each verdict derived from
RFC 9112 and the bytes the case sends, never from a run. It found four defects
the hand-written tests had not: a close-delimited body ended by an abrupt TLS
close was accepted; a response cut *inside* a header line held the request until
the deadline (FPC's header loop never saw the empty line it waits for), and
without a deadline it waited the response timeout twice; and on Linux, a
close-delimited https body cut by the response timeout came back complete,
because FPC reports that timeout as a clean close.

The tests are `tests/packages/03_http.bas` (a real loopback server the runner
stands up), `tests/packages/04_https.bas` (a self-signed TLS server, proving both
that verification refuses it and that TLS works once relaxed) and
`tests/packages/08_http_offline.bas`, which covers the whole configuration surface
without a single request; `tests/packages/14_http_client.bas` sends that
configuration to the loopback server and reads back what arrived, through a proxy
as well. `tests/packages/26_http_fields.bas` reads the request head BYTE FOR BYTE
off a raw server the runner stands up: the refusals above, every example of RFC
3986 §5.4.1 and §5.4.2, the percent-encoded Locations, the port bounds, params
before a fragment, and exact cookie names across a redirect.
`tests/packages/28_http_authority.bas` holds a url to the two readings: a `?` or
`#` before an `@`, two `#` on every path, and a generated sweep of 218897 urls in
which the library's verdict must match an oracle that asks `ParseURI` itself.
`tests/packages/30_http_path_colon.bas` reads the request line back for 416
generated paths — every special segment in every position, with and without a
query — and through a client, its params, a proxy and a redirect hop.
