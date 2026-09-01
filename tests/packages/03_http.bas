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
assert_eq(http_get$(base$ + "/nope"), "", "GET of an error status yields no body (check http_status)")

test_case("http/status codes")
assert_eq(http_status(base$ + "/"), 200, "200 for a known route")
assert_eq(http_status(base$ + "/teapot"), 418, "the route's own code passes through")
assert_eq(http_status(base$ + "/nope"), 404, "404 for an unknown route")

test_case("http/POST echoes the body")
assert_eq(http_post$(base$ + "/echo", "ping"), "ping", "POST body comes back verbatim")
assert_eq(http_post$(base$ + "/echo", "hello world"), "hello world", "a body with a space round-trips")
assert_eq(http_post$(base$ + "/echo", ""), "", "an empty body round-trips")
