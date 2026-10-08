rem ---------------------------------------------------------------
rem HTTP OVER IPv6 (ledger m6).
rem
rem FPC 3.2.2's socket layer is IPv4 only, and TFPHTTPClient keeps its
rem socket private. The package reaches IPv6 through the socket handler
rem (see PhosphorHttpLib's header). The runner stands up a plain-http
rem server on [::1] whose /family route answers "ipv6" -- the IPv4
rem servers have no such route -- so every "ipv6" below is proof the
rem request went over IPv6, not that it reached something.
rem
rem Expectations from the setup, not from a run:
rem   * an IPv6 literal URL is dialled as itself, for GET, POST and a
rem     client handle alike;
rem   * a name with no IPv4 address is reached through its AAAA record
rem     (http_resolve6_as$ names one deterministically on any machine);
rem   * a name's IPv4 address is still tried first: a name with an A
rem     record for the IPv4 server and an AAAA record for the IPv6 one
rem     answers from the IPv4 server, whose /family is a 404;
rem   * a dead IPv6 address is passed over for the next one;
rem   * a redirect from the IPv6 server to the IPv4 one lands there --
rem     the IPv6 pin is for its own host, not every host after it;
rem   * the platform's REAL AAAA resolver answers ::1 for a name it maps
rem     there (ip6-localhost on Linux, localhost on Windows).
rem ---------------------------------------------------------------

v6$ = server_url_ipv6$("http")
port$ = mid$(v6$, len("http://[::1]:") + 1)

test_case("ipv6/a literal address")
assert_eq(http_get$(v6$ + "/family"), "ipv6", "http://[::1] goes over IPv6")
assert_eq(http_status(v6$ + "/"), 200, "with a status")
assert_eq(http_get$(v6$ + "/"), "phosphor http ok", "and a body")
assert_eq(http_post$(v6$ + "/echo", "six"), "six", "POST too")

test_case("ipv6/a client handle")
c@ = http_client@(v6$)
assert_eq(http_get$(c@, "/family"), "ipv6", "a client aimed at [::1]")
x = http_free(c@)

test_case("ipv6/a name with only an IPv6 address")
x$ = http_resolve6_as$("v6only.test", "::1")
assert_eq(http_get$("http://v6only.test:" + port$ + "/family"), "ipv6", "reached through its AAAA record")

test_case("ipv6/IPv4 is still tried first")
x$ = http_resolve_as$("both.test", "127.0.0.1")
x$ = http_resolve6_as$("both.test", "::1")
v4$ = server_url$()
assert_eq(http_status("http://both.test:" + mid$(v4$, len("http://127.0.0.1:") + 1) + "/family"), 404, "the IPv4 server answered, and it has no /family")

test_case("ipv6/a dead IPv6 address is passed over")
x$ = http_resolve6_as$("deadfirst.test", "100::1, ::1")
assert_eq(http_get$("http://deadfirst.test:" + port$ + "/family"), "ipv6", "100::1 is discard-only; ::1 answers")

test_case("ipv6/a dead proxy is not gone around")
rem n26's rule, on the IPv6 side: through a proxy only the proxy is
rem dialled. With the proxy down the request fails; an AAAA fallback
rem that ran anyway would reach [::1] directly and answer "ipv6".
rem And no AAAA lookup is made for it at all: the proxy resolves, and a
rem client that asked its own resolver would leak the name to it.
p@ = http_client@("http://v6only.test:" + port$)
x = http_proxy(p@, "127.0.0.9", 9)
before = http_resolve6_calls()
assert_eq(http_status(p@, "/family"), 0, "the proxy is down, and IPv6 does not dial around it")
assert_eq(http_resolve6_calls(), before, "and the name was not looked up locally")
x = http_free(p@)

test_case("ipv6/a dead IPv6 address costs the client's own timeout")
rem 100::1 is in the discard-only prefix. Windows waits about 21 s for
rem a connect nobody answers; the client asked for 1 s. Linux refuses at
rem once (no route), so there the bound holds trivially. 10 s is the
rem line between "the timeout was applied" and "it was not".
x$ = http_resolve6_as$("deadonly.test", "100::1")
q@ = http_client@("http://deadonly.test:" + port$)
x = http_timeout(q@, 1000)
t0 = now()
st = http_status(q@, "/")
ms = (now() - t0) * 86400000
assert_eq(st, 0, "nothing answers")
assert_true(ms < 10000, "and the attempt ended within the client's timeout, not the system's")
x = http_free(q@)

test_case("ipv6/a redirect leaves the pin behind")
d@ = http_client@(v6$)
assert_eq(http_get$(d@, "/redir"), "phosphor http ok", "the IPv6 server sends it to the IPv4 server, which answers")
x = http_free(d@)

test_case("ipv6/the real resolver")
assert_eq(http_resolve6_has_loopback(server_ipv6_name$()), 1, "the platform's own AAAA lookup answers ::1")
