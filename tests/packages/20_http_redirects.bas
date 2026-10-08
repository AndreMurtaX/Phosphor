rem ---------------------------------------------------------------
rem A REDIRECT IS A REQUEST OF ITS OWN (2026-10-07).
rem
rem TFPHTTPClient used to follow a client's redirects itself, and none of
rem this library's rules went with it. Through a proxy, an https url
rem reached by a redirect was opened WITH THE PROXY, and passed the name
rem check on the proxy's own name: the proxy was handed the bearer token.
rem The Authorization header and the cookies went to whatever host a
rem redirect named -- in cleartext after https to http -- while a
rem redirect to the SAME host dropped the cookies. A pin made for the
rem first host was carried into an https hop, which then failed its name
rem check; an IPv6 target was never dialled as one; and a POST answered
rem by a 307 to a dead host was sent AGAIN, to the first host's next
rem address. Each hop now goes through every rule a first request does.
rem
rem The paths below carry a url in their query, which found one more: a
rem client took any path holding "://" for an absolute url, so
rem /redirect?to=http://... was sent with no host at all. A url is
rem absolute only when it BEGINS with a scheme (RFC 3986 3.1).
rem An empty header is matched as lf$ + "auth=" + lf$, from the start
rem of its line: "auth=" + lf$ alone is also the end of the pauth= line,
rem and the first draft of this file passed on the leaking build so.
rem
rem Every expected value is derived from the rule it names, not off a
rem run:
rem   * what identifies the caller -- the Authorization header, the
rem     cookies, the client certificate -- goes only to the first url's
rem     ORIGIN: its scheme, host and port, all three (curl's rule since
rem     CVE-2022-27776; RFC 9110 15.4 leaves the choice to the client);
rem   * a cookie a response sets is "name=value", the text before its
rem     first ";", and cookies are joined with "; " (fphttpclient's
rem     request writer), so sid=1 then srv=7 is "sid=1; srv=7";
rem   * a hop a proxy cannot honour is refused as a first request is:
rem     nothing sent, http_error() 2;
rem   * 303 turns the request into a GET with no body; 307 keeps it;
rem   * a redirect that is not followed answers its own status.
rem The runner's /redirect?to=URL&code=N answers N (302 by default) with
rem Location URL; /setcookie also sets "srv=7; Path=/; HttpOnly"; /hit
rem counts and redirects, /hits answers the count.
rem ---------------------------------------------------------------

lf$ = chr$(10)
srv$ = server_url$()
port$ = mid$(srv$, instr(mid$(srv$, 8), ":") + 8)
x$ = http_resolve_as$("other.test", "127.0.0.1")
other$ = "http://other.test:" + port$
ca$ = http_ca_file$(server_ca_file$())
tls$ = "https://localhost:" + mid$(server_url_https$(), 19)

test_case("redirect/another origin is sent nothing that identifies the caller")
c@ = http_client@(srv$)
x = http_bearerauth(c@, "SECRET")
x = http_cookie(c@, "sid", "1")
x = http_header(c@, "X-Demo", "on")
b$ = http_get$(c@, "/redirect?to=" + other$ + "/inspect")
assert_true(instr(b$, "target=/inspect" + lf$) > 0, "the redirect was followed")
assert_true(instr(b$, lf$ + "auth=" + lf$) > 0, "with no Authorization")
assert_true(instr(b$, "cookie=" + lf$) > 0, "and no cookie")
assert_true(instr(b$, "xdemo=on" + lf$) > 0, "but with every other header")

test_case("redirect/an origin is a scheme, a host and a port, all three")
rem Asked of the rule itself, because no server here speaks two schemes
rem on one port: a request that changed ONLY the scheme cannot be served,
rem and a mutant that ignored the scheme passed every request above.
rem RFC 3986: the host is case-insensitive (3.2.2), an absent port is the
rem scheme's default (3.2.3: 80 for http, 443 for https), and a trailing dot
rem only spells the same name in full.
assert_eq(http_same_origin("http://h.test/a", "http://h.test:80/b"), 1, "the default port, written or not")
assert_eq(http_same_origin("https://h.test/", "https://h.test:443/x"), 1, "and for https")
assert_eq(http_same_origin("http://H.TEST/", "http://h.test/"), 1, "a host in another case")
assert_eq(http_same_origin("http://h.test./", "http://h.test/"), 1, "a host with its trailing dot")
assert_eq(http_same_origin("https://h.test:8080/", "http://h.test:8080/"), 0, "another scheme, same host and port")
assert_eq(http_same_origin("http://h.test:8080/", "http://h.test:8081/"), 0, "another port")
assert_eq(http_same_origin("http://h.test/", "http://g.test/"), 0, "another host")
assert_eq(http_same_origin("http://h.test/", "https://h.test/"), 0, "and an upgrade to https")

test_case("redirect/the same origin is sent all of it")
b$ = http_get$(c@, "/redirect?to=" + srv$ + "/inspect")
assert_true(instr(b$, lf$ + "auth=Bearer SECRET" + lf$) > 0, "the Authorization")
assert_true(instr(b$, "cookie=sid=1" + lf$) > 0, "and the cookie, which FPC's own loop dropped")

test_case("redirect/a header named for a credential is one")
h@ = http_client@(srv$)
x = http_header(h@, "Authorization", "Custom z")
x = http_header(h@, "Cookie", "k=v")
b$ = http_get$(h@, "/redirect?to=" + other$ + "/inspect")
assert_true(instr(b$, lf$ + "auth=" + lf$) > 0, "an Authorization set as a plain header stays behind")
assert_true(instr(b$, "cookie=" + lf$) > 0, "and so does a Cookie")
b$ = http_get$(h@, "/redirect?to=" + srv$ + "/inspect")
assert_true(instr(b$, lf$ + "auth=Custom z" + lf$) > 0, "both go to the same origin")
assert_true(instr(b$, "cookie=k=v" + lf$) > 0, "unchanged")

test_case("redirect/a cookie the redirect sets goes on, without its attributes")
k@ = http_client@(srv$)
x = http_cookie(k@, "sid", "1")
b$ = http_get$(k@, "/setcookie?to=" + srv$ + "/inspect")
assert_true(instr(b$, "cookie=sid=1; srv=7" + lf$) > 0, "to the same origin, as name=value only")
b$ = http_get$(k@, "/setcookie?to=" + other$ + "/inspect")
assert_true(instr(b$, "cookie=" + lf$) > 0, "and not to another")

test_case("redirect/https to plain http on another host sends no token")
s@ = http_client@(tls$)
x = http_bearerauth(s@, "SECRET")
b$ = http_get$(s@, "/redirect?to=" + srv$ + "/inspect")
assert_true(instr(b$, "target=/inspect" + lf$) > 0, "the redirect was followed")
assert_true(instr(b$, lf$ + "auth=" + lf$) > 0, "and the token did not go out in cleartext")

test_case("redirect/an https hop is not given the plain hop's pin")
rem localhost over plain http is pinned to its resolved 127.0.0.1. The
rem pin used to ride into the https hop, whose name check then saw an
rem address the localhost certificate does not name: error 3.
x$ = http_resolve_as$("localhost", "127.0.0.1")
u@ = http_client@("http://localhost:" + port$)
assert_eq(http_get$(u@, "/redirect?to=" + tls$ + "/"), "phosphor http ok", "the upgrade to https is answered")
assert_eq(http_error(), 0, "with no refusal")

test_case("redirect/through a proxy, an https hop is refused and nothing is sent")
rem The proxy is the runner's own server; the destination exists only
rem through it. Before, the client opened TLS with the proxy itself.
p@ = http_client@("http://dest.test:9")
x = http_proxy(p@, mid$(srv$, 8, instr(mid$(srv$, 8), ":") - 1), val(port$))
x = http_bearerauth(p@, "SECRET")
assert_eq(http_get$(p@, "/redirect?to=https://bank.test/secret"), "", "nothing comes back")
assert_eq(http_error(), 2, "and it says the proxy could not take it")
b$ = http_get$(p@, "/redirect?to=http://dest2.test:9/inspect")
assert_true(instr(b$, "target=http://dest2.test:9/inspect" + lf$) > 0, "a plain hop goes through the proxy")

test_case("redirect/an answered POST is not sent twice")
rem dual.test has two A records, both this server. /hit counts the POST
rem and answers 307 to an address nothing listens on. The POST was
rem answered, so the second address is never tried; it used to be.
x$ = http_resolve_as$("dual.test", "127.0.0.1,127.0.0.1")
d@ = http_client@("http://dual.test:" + port$)
x = http_timeout(d@, 1000)
before = val(http_get$(srv$ + "/hits"))
x$ = http_post$(d@, "/hit?to=http://127.0.0.9:9/&code=307", "payload")
assert_eq(val(http_get$(srv$ + "/hits")) - before, 1, "the POST reached the server once")

test_case("redirect/303 makes a GET, 307 keeps the POST")
m@ = http_client@(srv$)
b$ = http_post$(m@, "/redirect?to=" + srv$ + "/inspect&code=303", "payload")
assert_true(instr(b$, "method=GET" + lf$) > 0, "303: a GET")
assert_true(instr(b$, "body=") > 0 and instr(b$, "payload") = 0, "with no body")
b$ = http_post$(m@, "/redirect?to=" + srv$ + "/inspect&code=307", "payload")
assert_true(instr(b$, "method=POST" + lf$) > 0, "307: still a POST")
assert_true(instr(b$, "body=payload") > 0, "with its body")

test_case("redirect/what is not followed answers its own status")
n@ = http_client@(srv$)
assert_eq(http_status(n@, "/redirect?to=/inspect"), 200, "a relative Location is followed")
assert_eq(http_status(n@, "/redirect?to=ftp://x.test/"), 302, "a scheme it cannot send is not")
assert_eq(http_status(n@, "/redirect"), 302, "nor is a missing Location")
x = http_maxredirects(n@, 0)
assert_eq(http_status(n@, "/redirect?to=/inspect"), 302, "nor a hop past the cap")
x = http_maxredirects(n@, 5)
x = http_followredirects(n@, 0)
assert_eq(http_status(n@, "/redirect?to=/inspect"), 302, "nor anything, with following off")
assert_eq(http_status(srv$ + "/redirect?to=/inspect"), 302, "and a bare url never follows")

test_case("redirect/an IPv6 target is dialled as one")
v$ = server_url_ipv6$("plain")
r@ = http_client@(srv$)
assert_eq(http_get$(r@, "/redirect?to=" + v$ + "/family"), "ipv6", "a literal")
x$ = http_resolve_as$("only6.test", "")
x$ = http_resolve6_as$("only6.test", "::1")
assert_eq(http_get$(r@, "/redirect?to=http://only6.test:" + mid$(v$, 14) + "/family"), "ipv6", "and a name reached by AAAA")

test_case("redirect/the client certificate stays with its origin")
rem The mutual-TLS server refuses a request that presents no certificate.
q@ = http_client@(srv$)
x = http_clientcert(q@, server_client_cert$("cert"), server_client_cert$("key"))
assert_eq(http_status(q@, "/redirect?to=" + server_url_mtls$() + "/"), 0, "another origin is not shown it")
w@ = http_client@(server_url_mtls$())
x = http_clientcert(w@, server_client_cert$("cert"), server_client_cert$("key"))
assert_eq(http_status(w@, "/"), 200, "the control: its own origin is")
