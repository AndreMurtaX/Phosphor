rem ---------------------------------------------------------------
rem A CLIENT HANDLE'S SETTINGS REACH THE REQUEST (ledger n26).
rem
rem http_client@ built a bag of settings -- base url, params, headers,
rem cookies, auth, proxy -- and no verb ever read it: http_get$,
rem http_status and http_post$ took a bare url. A program that set a
rem proxy had its traffic go out DIRECTLY, and nothing said so. The same
rem three names now take a client handle and a path.
rem
rem The local server's /inspect answers what the request carried. Every
rem expected value below is derived, not read off a run:
rem   "a b" url-encodes as a%20b (this library writes a space as %20);
rem   Basic auth for u:p is "Basic " + base64("u:p") = "Basic dTpw";
rem   for pu:pp it is base64("pu:pp") = "cHU6cHA=";
rem   through a proxy the request line carries the ABSOLUTE url
rem   (fphttpclient's GetServerURL), so target= proves the proxy was used.
rem ---------------------------------------------------------------

lf$ = chr$(10)
srv$ = server_url$()
hp$ = mid$(srv$, 8)
colon = instr(hp$, ":")
host$ = left$(hp$, colon - 1)
port = val(mid$(hp$, colon + 1))

test_case("http-client/the settings arrive")
c@ = http_client@(srv$)
x = http_param(c@, "q", "a b")
x = http_param(c@, "n", "1")
x = http_header(c@, "X-Demo", "on")
x = http_cookie(c@, "sid", "42")
x = http_useragent(c@, "phosphor-test/1")
x = http_accept(c@, "text/plain")
x = http_basicauth(c@, "u", "p")
b$ = http_get$(c@, "/inspect")
assert_eq(http_error(), 0, "a request on a live client clears http_error")
assert_true(instr(b$, "target=/inspect?q=a%20b&n=1" + lf$) > 0, "the base url, the path and the params, encoded, in order")
assert_true(instr(b$, "method=GET" + lf$) > 0, "as a GET")
assert_true(instr(b$, "ua=phosphor-test/1" + lf$) > 0, "with the user agent")
assert_true(instr(b$, "accept=text/plain" + lf$) > 0, "the accept header")
assert_true(instr(b$, "auth=Basic dTpw" + lf$) > 0, "the basic auth")
assert_true(instr(b$, "cookie=sid=42" + lf$) > 0, "the cookie")
assert_true(instr(b$, "xdemo=on" + lf$) > 0, "and a header of its own")

test_case("http-client/post and status take the handle too")
x = http_contenttype(c@, "text/plain")
b$ = http_post$(c@, "inspect", "payload")
assert_true(instr(b$, "method=POST" + lf$) > 0, "a POST, with the path joined without a slash of its own")
assert_true(instr(b$, "ctype=text/plain" + lf$) > 0, "carrying the content type")
assert_true(instr(b$, "body=payload") > 0, "and the body")
t@ = http_client@(srv$)
assert_eq(http_status(t@, "/teapot"), 418, "http_status answers the status of the path on the base url")

test_case("http-client/a proxy is used, not bypassed")
rem The destination resolves -- through the runner's resolver seam -- to
rem 127.0.0.9, a loopback address nothing listens on. The multi-address
rem fallback, if it still ran with a proxy set, would pin a connect to that
rem address and go AROUND the proxy, and fail. A first draft used
rem "localhost" here and could not see the bypass: localhost IS the proxy's
rem address, so the pinned connect landed on the same server either way.
x$ = http_resolve_as$("pinme.test", "127.0.0.9")
d@ = http_client@("http://pinme.test:" + str$(port))
x = http_timeout(d@, 800)
assert_eq(http_status(d@, "/inspect"), 0, "the control: with no proxy that destination cannot be reached")
p@ = http_client@("http://pinme.test:" + str$(port))
x = http_proxy(p@, host$, port)
x = http_proxyauth(p@, "pu", "pp")
b$ = http_get$(p@, "/inspect")
assert_true(instr(b$, "target=http://pinme.test:" + str$(port) + "/inspect" + lf$) > 0, "through the proxy it is, and the request line carries the absolute url")
assert_true(instr(b$, "pauth=Basic cHU6cHA=" + lf$) > 0, "with the proxy credentials")
rem The line itself, after its line break: "auth=Basic" alone also matches
rem inside "pauth=Basic ..." on the line above, which a first draft did.
assert_true(instr(b$, lf$ + "auth=" + lf$) > 0, "and no Authorization header this client never set")
rem A destination that does not exist at all: only the proxy can answer it.
v@ = http_client@("http://example.invalid:9")
x = http_proxy(v@, host$, port)
b$ = http_get$(v@, "/inspect")
assert_true(instr(b$, "target=http://example.invalid:9/inspect" + lf$) > 0, "a host nothing could reach directly is reached through the proxy")

test_case("http-client/a proxy it cannot honour is refused, not ignored")
h@ = http_client@("https://example.invalid")
x = http_proxy(h@, host$, port)
assert_eq(http_get$(h@, "/x"), "", "an https request through a proxy sends nothing -- there is no CONNECT")
assert_eq(http_error(), 2, "and says it was the proxy")
assert_eq(http_strerror$(2), "the request cannot go through this proxy", "in words")
z@ = http_client@(srv$)
x = http_proxy(z@, host$, 0)
assert_eq(http_status(z@, "/inspect"), 0, "a proxy with no port is refused rather than silently skipped")
assert_eq(http_error(), 2, "with the same code")
x = http_clearproxy(z@)
assert_eq(http_status(z@, "/inspect"), 200, "and once cleared, the same client goes direct again")

test_case("http-client/a handle that is not a client")
assert_eq(http_get$(pointer@(424242), "/inspect"), "", "a fabricated handle sends nothing")
assert_eq(http_error(), 1, "and is reported as an invalid handle")

test_case("http-client/the bare-url verbs are unchanged")
assert_eq(http_get$(srv$ + "/"), "phosphor http ok", "http_get$ of a url")
assert_eq(http_status(srv$ + "/teapot"), 418, "http_status of a url")
