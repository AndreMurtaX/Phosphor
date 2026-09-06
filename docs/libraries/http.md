# http — fetch a URL, and build the request that will fetch it

`host/packages/PhosphorHttpLib.pas` · 60 functions · opt-in host package (the
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

The surprise worth stating plainly: **the three verbs take a URL, not a client.**
Nothing today reads a client's headers, cookies, auth, proxy or timeouts back out
and puts them on the wire — the accumulator holds them, hands them back, and resets
them, waiting for the verb that will consume them. `http_get$` uses a fixed 5-second
connect timeout of its own, not `http_timeout`. In the same spirit, the flag that
actually governs TLS is the process-global `http_verify_peer`, not the per-client
`http_validatessl`. What a program can genuinely do today is compose the URL itself
(`http_baseurl$` + a form's `http_formurlencoded$` rendering) and fetch that.

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
| `http_verify_peer(on) → num` | turn https certificate verification on (the default) or off, for the whole process; answers the value it set (`1`/`0`). `0` is the explicit opt-out for a self-signed dev server, never the default |
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
| `http_proxy(c@, host$, port) → num` | `1`; the proxy is recorded. Neither the host nor the port is validated here |
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
| `http_validatessl(c@, on) → num` / `http_validatessl(c@) → num` | this client's SSL-validation flag, `1` by default. Per-client and stored only — the flag that actually decides a handshake is the global `http_verify_peer` |

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
| `http_error() → num` | the last config op's code: `0` clean, `1` a bad client or form handle. A *request* never sets this — a 404, a dead host and a rejected certificate are all read from `http_status`, not from here |
| `http_clearerror() → num` | `0`, always; the code is reset to `0` |
| `http_strerror$(code) → str` | `"no error"` for `0`, `"invalid handle"` for `1`, `"unknown error"` for anything else — including a code this library would never produce |

## A worked example

A search request against a local service. The settings live on a client handle, the
query string is built by a form rather than by string-pasting, and only the two
lines near the end touch the network.

```basic
rem Compose a URL from a client's base and a form's rendering, then fetch it.

c@ = http_client@("http://127.0.0.1:8080")
http_timeout(c@, 5000)
http_header(c@, "X-Requested-With", "phosphor")
if http_error() <> 0 then println "config refused: " + http_strerror$(http_error())

f@ = http_form@()
http_formfield(f@, "q", "phosphor basic")
http_formfield(f@, "page", "2")
query$ = http_formurlencoded$(f@)      rem q=phosphor%20basic&page=2
http_formfree(f@)

url$ = http_baseurl$(c@) + "/search?" + query$
code = http_status(url$)
if code = 0 then
  println "nothing answered at " + url$
else
  body$ = http_get$(url$)
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
- **The header and the timeout on `c@` never left the process.** They are set, they
  read back, `http_reset` would clear them — but the verb takes `url$`. What the
  client genuinely contributes here is `http_baseurl$`, one place to keep the
  service's address so the rest of the program composes against it.

## Notes / Where the rest lives

**HTTPS is verified by default, and that is a deliberate reversal.** FPC's OpenSSL
handler ships insecure — it accepts any certificate, expired, self-signed or issued
for another host, which is TLS that encrypts without authenticating. This library
turns verification on (`SSL_VERIFY_PEER` plus the system CA bundle, located at
startup) so a bad certificate makes the connection *fail* instead of silently
succeeding. Two consequences a caller meets in practice: a box with no CA bundle in
a standard place — Windows, notably — **fails closed** until `http_ca_file$` points
at a PEM; and a self-signed dev server needs an explicit `http_verify_peer(0)`,
which stays off for the whole process until something turns it back on. Known gap:
this validates the certificate *chain*, not yet the hostname.

**A host name with several A records is tried in turn.** FPC's socket layer
resolves a host to its first A record and connects only to that one, so a single
dead IP fails a request that a round-robin CDN's other addresses would have served.
This library resolves them all and tries each until one connects. It applies to
plain `http://` only: over TLS, pinning a resolved IP would show the handshake an
IP where it needs the name, so https takes the plain resolve-and-dial path. The
underlying layer is IPv4-only, so an IPv6-only endpoint is out of reach here. The
reasoning and what comes next are in [roadmap-net.md](../roadmap-net.md).

The tests are `tests/packages/03_http.bas` (a real loopback server the runner
stands up), `tests/packages/04_https.bas` (a self-signed TLS server, proving both
that verification refuses it and that TLS works once relaxed) and
`tests/packages/08_http_offline.bas`, which covers the whole configuration surface
without a single request.
