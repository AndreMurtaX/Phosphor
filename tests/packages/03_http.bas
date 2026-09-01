rem ---------------------------------------------------------------
rem HTTP client (opt-in host package): exercised against a REAL local
rem server the test runner (phosphorhttptest) stands up on loopback.
rem server_url$() is a host function giving the server's base URL, so
rem the port is never hard-coded here.
rem ---------------------------------------------------------------

base$ = server_url$()

test_case("http/GET body")
assert_eq(http_get$(base$ + "/"), "phosphor http ok", "GET / returns the greeting")
assert_eq(http_get$(base$ + "/json"), "{" + chr$(34) + "n" + chr$(34) + ":42}", "GET /json returns the JSON body")
assert_eq(http_get$(base$ + "/nope"), "not found", "GET returns the body of an error response too")

test_case("http/status codes")
assert_eq(http_status(base$ + "/"), 200, "200 for a known route")
assert_eq(http_status(base$ + "/teapot"), 418, "the route's own code passes through")
assert_eq(http_status(base$ + "/nope"), 404, "404 for an unknown route")

test_case("http/POST echoes the body")
assert_eq(http_post$(base$ + "/echo", "ping"), "ping", "POST body comes back verbatim")
assert_eq(http_post$(base$ + "/echo", "hello world"), "hello world", "a body with a space round-trips")
assert_eq(http_post$(base$ + "/echo", ""), "", "an empty body round-trips")

rem Multi-address fallback: http_get_via$ (a TEST-ONLY host function) forces the
rem candidate connect addresses, so the fallback is proven without DNS or a real
rem network. The server is bound to 127.0.0.1 only, so 127.0.0.9 is genuinely dead.
test_case("http/multi-address fallback")
assert_eq(http_get_via$(base$ + "/", "127.0.0.1"), "phosphor http ok", "a single good address connects")
assert_eq(http_get_via$(base$ + "/", "127.0.0.9,127.0.0.1"), "phosphor http ok", "a dead first address is skipped for the live one")
assert_eq(http_get_via$(base$ + "/", "127.0.0.1,127.0.0.9"), "phosphor http ok", "the first live address wins")
assert_eq(http_get_via$(base$ + "/", "127.0.0.9"), "", "an all-dead address list yields empty")
