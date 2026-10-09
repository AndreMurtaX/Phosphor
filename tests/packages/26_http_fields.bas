rem ---------------------------------------------------------------
rem WHAT REACHES THE WIRE IS WHAT WAS ASKED FOR, AND NOTHING ELSE
rem (2026-10-09, five findings of an adversarial round).
rem
rem The runner's RAW server (server_url_raw$) answers the request head
rem it was sent, byte for byte, as the body, and counts every connection
rem (raw_hits) -- so a test reads the wire itself. Its /b/c/d;p?q answers
rem 302 with the Location raw_location$ last set; /threecookies and
rem /ctlcookie set cookies and redirect to /head.
rem
rem   H1. A CR LF in a header value, a cookie, the user agent, a token, a
rem       custom Authorization or the url was written raw into the request
rem       head: one more header line reached the server. RFC 9110 5.5: a
rem       field value is visible characters, SP and HTAB -- no other
rem       control character (0x00-0x1F, 0x7F); RFC 9110 5.1: a field NAME
rem       is a token (tchar: ALPHA DIGIT and !#$%&'*+-.^_`|~); RFC 6265
rem       4.1.1: a cookie name is a token and a cookie value's octets
rem       exclude every CTL, HTAB too; RFC 3986 2: a url carries no control
rem       character at all. A setter given one REFUSES -- answers 0, stores
rem       nothing, http_error() 6 -- and a verb given such a url sends
rem       nothing: status 0, no body, http_error() 6. What is percent- or
rem       base64-encoded on its way out (a param, basic and proxy
rem       credentials) carries no control character to the wire, and is
rem       accepted.
rem   H2. A RELATIVE Location was percent-DECODED and re-encoded on its way
rem       to the next hop (FPC's ResolveRelativeURI): g?a=1%262 was asked
rem       for as /b/c/g?a=1&2. RFC 3986 5.2.2 copies a reference's
rem       components as they are written. Every example of RFC 3986 5.4.1
rem       and 5.4.2 (base http://a/b/c/d;p?q, strict parser) is asked of
rem       the resolution FetchCore follows, the expected urls copied from
rem       the RFC.
rem   H3. A port above 65535 WRAPPED (FPC keeps it in a Word): port
rem       A + 65536 reached port A. RFC 3986 3.2.3 and RFC 793: a port is
rem       a decimal of 0..65535, and 0 is no port a server listens on. A
rem       url whose port is not 1..65535 is refused before any dial, as an
rem       unusable host already was ([zzzz] below, the control): status 0,
rem       http_error() 0, no connection. An EMPTY port (h:/) is RFC 3986's
rem       "no port", the scheme's default, as before.
rem   H4. Params were appended AFTER a #fragment, which is never sent, so
rem       they were lost. RFC 3986 3.5: the fragment follows the query.
rem   H5. The redirect cookie jar matched cookie names case-insensitively,
rem       so SID and sid were one cookie and THEME replaced the script's
rem       own theme. RFC 6265 5.3 / http.md: cookie names match exactly.
rem       The Cookie header is the client's own cookies, then the jar's in
rem       the order they were set, joined by "; " (fphttpclient's writer).
rem       A Set-Cookie carrying a control character other than HTAB is
rem       ignored entirely (RFC 6265bis 5.6, step 1), so it never reaches
rem       the next hop's head.
rem ---------------------------------------------------------------

cr$ = chr$(13)
lf$ = chr$(10)
crlf$ = cr$ + lf$
raw$ = server_url_raw$()
rport = val(mid$(raw$, 18))

rem The request line of an echoed head.
function reqline$(b$) local p
  p = instr(b$, cr$)
  if p = 0 then
    return b$
  endif
  return mid$(b$, 1, p - 1)
endfunction

test_case("fields/the control: a plain request's head comes back as it was sent")
c@ = http_client@(raw$)
b$ = http_get$(c@, "/head")
assert_eq(reqline$(b$), "GET /head HTTP/1.1", "the request line")
assert_true(instr(b$, crlf$ + "Host: 127.0.0.1:" + str$(rport) + crlf$) > 0, "and the Host line")
rem fphttpclient's SendRequest writes the request line, Host, the request
rem headers -- here only the Connection: close it adds itself when the
rem connection is not kept -- and a Cookie line only when it holds a cookie
rem list. A client with no cookies must send no Cookie line at all.
assert_eq(b$, "GET /head HTTP/1.1" + crlf$ + "Host: 127.0.0.1:" + str$(rport) + crlf$ + "Connection: close" + crlf$, "and nothing else")

test_case("fields/a header value carrying CR LF is refused, and nothing of it is sent")
h@ = http_client@(raw$)
assert_eq(http_header(h@, "X-A", "1" + crlf$ + "X-Injected: yes"), 0, "the setter refuses")
assert_eq(http_error(), 6, "and says why")
assert_eq(http_headercount(h@), 0, "nothing was stored")
b$ = http_get$(h@, "/head")
assert_eq(instr(b$, "X-Injected"), 0, "no injected line reached the server")
assert_eq(http_header(h@, "X-B", "a" + lf$ + "b"), 0, "a bare LF is refused too")
assert_eq(http_header(h@, "X-B", "a" + cr$ + "b"), 0, "and a bare CR")
assert_eq(http_header(h@, "X-B", "a" + chr$(0) + "b"), 0, "and NUL")
assert_eq(http_header(h@, "X-B", "a" + chr$(127) + "b"), 0, "and DEL")
assert_eq(http_header(h@, "X-B", "a" + chr$(31) + "b"), 0, "and 0x1F")
assert_eq(http_error(), 6, "each with code 6")
assert_eq(http_headercount(h@), 0, "none of them stored")

test_case("fields/a header value may carry HTAB, and an old value survives a refusal")
assert_eq(http_header(h@, "X-Tab", "a" + chr$(9) + "b"), 1, "HTAB is a field-value character")
assert_eq(http_error(), 0, "with no error")
assert_eq(http_header(h@, "X-Tab", "c" + crlf$ + "d"), 0, "a refused replacement")
assert_eq(http_header$(h@, "X-Tab"), "a" + chr$(9) + "b", "leaves the old value in place")
b$ = http_get$(h@, "/head")
assert_true(instr(b$, crlf$ + "X-Tab: a" + chr$(9) + "b" + crlf$) > 0, "and that is what is sent")

test_case("fields/a header NAME must be a token")
n@ = http_client@(raw$)
assert_eq(http_header(n@, "X-A" + crlf$ + "X-Injected", "v"), 0, "CR LF in a name")
assert_eq(http_error(), 6, "says why")
assert_eq(http_header(n@, "X A", "v"), 0, "a space")
assert_eq(http_header(n@, "X:A", "v"), 0, "a colon")
assert_eq(http_header(n@, "", "v"), 0, "an empty name")
assert_eq(http_header(n@, "X(A)", "v"), 0, "a delimiter")
assert_eq(http_header(n@, "X-" + chr$(195) + chr$(169), "v"), 0, "a byte above 127")
assert_eq(http_headercount(n@), 0, "none stored")
assert_eq(http_header(n@, "X-Ok!#$%&'*+-.^_`|~09az", "v"), 1, "every tchar is accepted")
assert_eq(http_error(), 0, "with no error")

test_case("fields/a cookie carrying a control character is refused")
k@ = http_client@(raw$)
assert_eq(http_cookie(k@, "k", "v" + crlf$ + "X-Injected: yes"), 0, "CR LF in a value")
assert_eq(http_error(), 6, "says why")
assert_eq(http_cookie(k@, "k" + lf$, "v"), 0, "LF in a name")
assert_eq(http_cookie(k@, "k", "a" + chr$(9) + "b"), 0, "HTAB is not a cookie octet")
assert_eq(http_cookie(k@, "k", "a" + chr$(127)), 0, "nor is DEL")
assert_eq(http_cookiecount(k@), 0, "nothing stored")
assert_eq(http_cookie(k@, "k", "v"), 1, "the control: a plain cookie")
b$ = http_get$(k@, "/head")
assert_true(instr(b$, crlf$ + "Cookie: k=v" + crlf$) > 0, "is sent alone")
assert_eq(instr(b$, "X-Injected"), 0, "with nothing injected")

test_case("fields/the user agent, accept and content type are header values")
u@ = http_client@(raw$)
assert_eq(http_useragent(u@, "ua" + crlf$ + "X-Injected: yes"), 0, "the user agent")
assert_eq(http_error(), 6, "says why")
assert_eq(http_accept(u@, "a/b" + lf$ + "X-Injected: yes"), 0, "accept")
assert_eq(http_contenttype(u@, "c/d" + cr$ + "X-Injected: yes"), 0, "content type")
assert_eq(http_useragent$(u@), "", "none of them stored")
assert_eq(http_accept$(u@), "", "accept neither")
assert_eq(http_contenttype$(u@), "", "nor content type")
b$ = http_get$(u@, "/head")
assert_eq(instr(b$, "X-Injected"), 0, "and nothing was injected")

test_case("fields/a token or a custom Authorization is refused, and the old one kept")
a@ = http_client@(raw$)
assert_eq(http_bearerauth(a@, "GOOD"), 1, "the control: a plain token")
assert_eq(http_bearerauth(a@, "BAD" + crlf$ + "X-Injected: yes"), 0, "a token with CR LF")
assert_eq(http_error(), 6, "says why")
assert_eq(http_customauth(a@, "Custom" + lf$ + "X-Injected: yes"), 0, "a custom value")
b$ = http_get$(a@, "/head")
assert_true(instr(b$, crlf$ + "Authorization: Bearer GOOD" + crlf$) > 0, "the earlier token is what is sent")
assert_eq(instr(b$, "X-Injected"), 0, "and nothing was injected")

test_case("fields/basic credentials and params are encoded, so they carry nothing")
rem Basic is base64 of "user:pass" (RFC 7617); a param is percent-encoded,
rem CR as %0D and LF as %0A (RFC 3986 2.1). u, CR, LF, ":", p in base64 is
rem dQ0KOnA= : u=0x75 CR=0x0D LF=0x0A ':'=0x3A 'p'=0x70.
e@ = http_client@(raw$)
assert_eq(http_basicauth(e@, "u" + crlf$, "p"), 1, "basic auth is accepted")
assert_eq(http_param(e@, "a", crlf$), 1, "and so is a param")
b$ = http_get$(e@, "/head")
assert_eq(reqline$(b$), "GET /head?a=%0D%0A HTTP/1.1", "the param went out encoded")
assert_true(instr(b$, crlf$ + "Authorization: Basic dQ0KOnA=" + crlf$) > 0, "and the credentials as base64")

test_case("fields/proxy credentials go out as base64 too")
rem The raw server is the proxy here: its target is the absolute url.
rem u, CR, LF, ":", p is dQ0KOnA= as above.
p@ = http_client@("http://dest.test:9")
x = http_proxy(p@, "127.0.0.1", rport)
assert_eq(http_proxyauth(p@, "u" + crlf$, "p"), 1, "accepted")
b$ = http_get$(p@, "/head")
assert_eq(reqline$(b$), "GET http://dest.test:9/head HTTP/1.1", "through the proxy")
assert_true(instr(b$, crlf$ + "Proxy-Authorization: Basic dQ0KOnA=" + crlf$) > 0, "with the credentials encoded")

test_case("fields/a base url carrying a control character is refused by its setter")
s@ = http_client@(raw$)
assert_eq(http_baseurl(s@, raw$ + crlf$ + "X-Injected: yes"), 0, "refused")
assert_eq(http_error(), 6, "says why")
assert_eq(http_baseurl$(s@), raw$, "the old base url stays")

test_case("fields/a url carrying a control character sends nothing at all")
before = raw_hits()
assert_eq(http_get$(raw$ + "/head" + crlf$ + "X-Injected: yes"), "", "a bare GET answers nothing")
assert_eq(http_error(), 6, "says why")
assert_eq(http_status(raw$ + "/head" + chr$(9)), 0, "an HTAB in a url is refused too")
assert_eq(http_error(), 6, "says why")
assert_eq(http_post$(raw$ + "/head" + chr$(0), "body"), "", "a bare POST")
assert_eq(http_error(), 6, "says why")
assert_eq(http_get$(c@, "/head" + lf$ + "X-Injected: yes"), "", "a client path")
assert_eq(http_error(), 6, "says why")
assert_eq(http_status(c@, "/head#frag" + chr$(127)), 0, "even in the fragment")
assert_eq(http_error(), 6, "says why")
i@ = http_client@(raw$ + "/x" + cr$)
assert_eq(http_status(i@, "/head"), 0, "a base url given to the constructor")
assert_eq(http_error(), 6, "says why")
assert_eq(raw_hits() - before, 0, "and not one of them connected")

test_case("fields/a Location carrying a control character is not followed")
before = raw_hits()
x$ = raw_location$("/head" + chr$(1))
assert_eq(http_status(c@, "/b/c/d;p?q"), 0, "the hop is refused")
assert_eq(http_error(), 6, "says why")
assert_eq(raw_hits() - before, 1, "only the first request was sent")

test_case("fields/a relative Location is sent as it was written")
rem RFC 3986 5.2.2: the reference's path and query are copied, never
rem decoded; 5.2.3 merges the path with the base's directory /b/c/.
x$ = raw_location$("g?a=1%262")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /b/c/g?a=1%262 HTTP/1.1", "%26 stays %26")
x$ = raw_location$("g%2Bh?x=%2B")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /b/c/g%2Bh?x=%2B HTTP/1.1", "%2B stays %2B")
x$ = raw_location$("g%2Fh")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /b/c/g%2Fh HTTP/1.1", "%2F stays %2F")
x$ = raw_location$("?k%3Dv=1")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /b/c/d;p?k%3Dv=1 HTTP/1.1", "%3D stays %3D")
x$ = raw_location$("../g%20h")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /b/g%20h HTTP/1.1", "and %20 stays %20")
x$ = raw_location$("/head")
assert_eq(reqline$(http_get$(c@, "/b/c/d;p?q")), "GET /head HTTP/1.1", "the control: an absolute path")

test_case("fields/RFC 3986 5.4.1, the normal examples")
base$ = "http://a/b/c/d;p?q"
assert_eq(http_resolve_ref$(base$, "g:h"), "g:h", "g:h")
assert_eq(http_resolve_ref$(base$, "g"), "http://a/b/c/g", "g")
assert_eq(http_resolve_ref$(base$, "./g"), "http://a/b/c/g", "./g")
assert_eq(http_resolve_ref$(base$, "g/"), "http://a/b/c/g/", "g/")
assert_eq(http_resolve_ref$(base$, "/g"), "http://a/g", "/g")
assert_eq(http_resolve_ref$(base$, "//g"), "http://g", "//g")
assert_eq(http_resolve_ref$(base$, "?y"), "http://a/b/c/d;p?y", "?y")
assert_eq(http_resolve_ref$(base$, "g?y"), "http://a/b/c/g?y", "g?y")
assert_eq(http_resolve_ref$(base$, "#s"), "http://a/b/c/d;p?q#s", "#s")
assert_eq(http_resolve_ref$(base$, "g#s"), "http://a/b/c/g#s", "g#s")
assert_eq(http_resolve_ref$(base$, "g?y#s"), "http://a/b/c/g?y#s", "g?y#s")
assert_eq(http_resolve_ref$(base$, ";x"), "http://a/b/c/;x", ";x")
assert_eq(http_resolve_ref$(base$, "g;x"), "http://a/b/c/g;x", "g;x")
assert_eq(http_resolve_ref$(base$, "g;x?y#s"), "http://a/b/c/g;x?y#s", "g;x?y#s")
assert_eq(http_resolve_ref$(base$, ""), "http://a/b/c/d;p?q", "the empty reference")
assert_eq(http_resolve_ref$(base$, "."), "http://a/b/c/", ".")
assert_eq(http_resolve_ref$(base$, "./"), "http://a/b/c/", "./")
assert_eq(http_resolve_ref$(base$, ".."), "http://a/b/", "..")
assert_eq(http_resolve_ref$(base$, "../"), "http://a/b/", "../")
assert_eq(http_resolve_ref$(base$, "../g"), "http://a/b/g", "../g")
assert_eq(http_resolve_ref$(base$, "../.."), "http://a/", "../..")
assert_eq(http_resolve_ref$(base$, "../../"), "http://a/", "../../")
assert_eq(http_resolve_ref$(base$, "../../g"), "http://a/g", "../../g")

test_case("fields/RFC 3986 5.4.2, the abnormal examples")
assert_eq(http_resolve_ref$(base$, "../../../g"), "http://a/g", "../../../g")
assert_eq(http_resolve_ref$(base$, "../../../../g"), "http://a/g", "../../../../g")
assert_eq(http_resolve_ref$(base$, "/./g"), "http://a/g", "/./g")
assert_eq(http_resolve_ref$(base$, "/../g"), "http://a/g", "/../g")
assert_eq(http_resolve_ref$(base$, "g."), "http://a/b/c/g.", "g.")
assert_eq(http_resolve_ref$(base$, ".g"), "http://a/b/c/.g", ".g")
assert_eq(http_resolve_ref$(base$, "g.."), "http://a/b/c/g..", "g..")
assert_eq(http_resolve_ref$(base$, "..g"), "http://a/b/c/..g", "..g")
assert_eq(http_resolve_ref$(base$, "./../g"), "http://a/b/g", "./../g")
assert_eq(http_resolve_ref$(base$, "./g/."), "http://a/b/c/g/", "./g/.")
assert_eq(http_resolve_ref$(base$, "g/./h"), "http://a/b/c/g/h", "g/./h")
assert_eq(http_resolve_ref$(base$, "g/../h"), "http://a/b/c/h", "g/../h")
assert_eq(http_resolve_ref$(base$, "g;x=1/./y"), "http://a/b/c/g;x=1/y", "g;x=1/./y")
assert_eq(http_resolve_ref$(base$, "g;x=1/../y"), "http://a/b/c/y", "g;x=1/../y")
assert_eq(http_resolve_ref$(base$, "g?y/./x"), "http://a/b/c/g?y/./x", "g?y/./x")
assert_eq(http_resolve_ref$(base$, "g?y/../x"), "http://a/b/c/g?y/../x", "g?y/../x")
assert_eq(http_resolve_ref$(base$, "g#s/./x"), "http://a/b/c/g#s/./x", "g#s/./x")
assert_eq(http_resolve_ref$(base$, "g#s/../x"), "http://a/b/c/g#s/../x", "g#s/../x")
assert_eq(http_resolve_ref$(base$, "http:g"), "http:g", "http:g, by the strict parser")

test_case("fields/the percent-encoded references, resolved as written")
assert_eq(http_resolve_ref$(base$, "g?a=1%262"), "http://a/b/c/g?a=1%262", "%26")
assert_eq(http_resolve_ref$(base$, "g%2Fh"), "http://a/b/c/g%2Fh", "%2F")
assert_eq(http_resolve_ref$(base$, "%2E%2E/g"), "http://a/b/c/%2E%2E/g", "an encoded dot is not a dot segment (RFC 3986 2.3)")
assert_eq(http_resolve_ref$(base$, "//h.test:81/p%3Fq?r%23s"), "http://h.test:81/p%3Fq?r%23s", "a network-path reference")

test_case("fields/a port is a decimal of 1..65535")
rem The control first: a host the library cannot use is refused before
rem any dial, status 0 and http_error() 0 -- the treatment a bad port gets.
before = raw_hits()
assert_eq(http_status("http://[zzzz]:" + str$(rport) + "/head"), 0, "the control: an unusable host")
assert_eq(http_error(), 0, "with no error code")
assert_eq(http_status("http://127.0.0.1:" + str$(rport + 65536) + "/head"), 0, "port + 65536 does not wrap")
assert_eq(http_error(), 0, "the same answer as an unusable host")
assert_eq(http_status("http://127.0.0.1:" + str$(rport + 131072) + "/head"), 0, "nor + 131072")
assert_eq(http_status(c@, "http://127.0.0.1:" + str$(rport + 65536) + "/head"), 0, "nor through a client")
assert_eq(http_status("http://127.0.0.1:0/head"), 0, "port 0 is no port")
assert_eq(http_status("http://127.0.0.1:65536/head"), 0, "65536 is one past the last")
assert_eq(http_status("http://127.0.0.1:1x/head"), 0, "a port must be digits")
assert_eq(http_status("http://[::1]:" + str$(rport + 65536) + "/head"), 0, "an IPv6 literal's port too")
assert_eq(raw_hits() - before, 0, "and none of them connected")
assert_eq(http_status("http://127.0.0.1:00" + str$(rport) + "/head"), 200, "the control: leading zeros are the same decimal")
x$ = raw_location$("http://127.0.0.1:" + str$(rport + 65536) + "/head")
before = raw_hits()
assert_eq(http_status(c@, "/b/c/d;p?q"), 0, "a redirect hop's port is checked too")
assert_eq(raw_hits() - before, 1, "only the first request connected")

test_case("fields/params go before a fragment, which is not sent")
f@ = http_client@(raw$)
x = http_param(f@, "a", "1")
assert_eq(reqline$(http_get$(f@, "/p#top")), "GET /p?a=1 HTTP/1.1", "a path with a fragment")
assert_eq(reqline$(http_get$(f@, "/q?x=2#top")), "GET /q?x=2&a=1 HTTP/1.1", "a path with a query and a fragment")
assert_eq(reqline$(http_get$(f@, "/r#a?b")), "GET /r?a=1 HTTP/1.1", "a ? inside the fragment is not a query")

test_case("fields/cookie names match exactly across a redirect")
j@ = http_client@(raw$)
x = http_cookie(j@, "theme", "dark")
b$ = http_get$(j@, "/threecookies")
assert_eq(reqline$(b$), "GET /head HTTP/1.1", "the redirect was followed")
assert_true(instr(b$, crlf$ + "Cookie: theme=dark; SID=upper; sid=lower; THEME=x" + crlf$) > 0, "four cookies, every name its own")

test_case("fields/a Set-Cookie carrying a control character is ignored")
g@ = http_client@(raw$)
b$ = http_get$(g@, "/ctlcookie")
assert_eq(reqline$(b$), "GET /head HTTP/1.1", "the redirect was followed")
assert_true(instr(b$, crlf$ + "Cookie: good=1" + crlf$) > 0, "with the clean cookie alone")

test_case("fields/a port too long for any integer is refused, not a fault")
rem Last: before the fix this one raised out of the library.
assert_eq(http_status("http://127.0.0.1:99999999999/head"), 0, "refused")
assert_eq(http_error(), 0, "as an unusable url")
