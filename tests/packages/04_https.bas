rem ---------------------------------------------------------------
rem HTTPS against a local self-signed TLS server the runner
rem (phosphorhttptest) stands up on loopback -- no external network.
rem Proves BOTH halves of the security story: verification refuses an
rem untrusted certificate by default, and TLS GET/status/POST work
rem once verification is explicitly relaxed for this self-signed peer.
rem ---------------------------------------------------------------

base$ = server_url_https$()

test_case("https/verification refuses an untrusted cert by default")
assert_eq(http_status(base$ + "/"), 0, "the self-signed cert is refused (verify on)")
assert_eq(http_get$(base$ + "/"), "", "and no body comes back")

test_case("https/TLS works once verification is relaxed")
v% = http_verify_peer(0)
assert_eq(http_status(base$ + "/"), 200, "reachable over TLS with verification off")
assert_eq(http_get$(base$ + "/"), "phosphor http ok", "GET body over TLS")
assert_eq(http_get$(base$ + "/json"), "{" + chr$(34) + "n" + chr$(34) + ":42}", "GET /json over TLS")
assert_eq(http_post$(base$ + "/echo", "secure ping"), "secure ping", "POST echo over TLS")

test_case("https/re-enabling verification refuses it again")
v% = http_verify_peer(1)
assert_eq(http_status(base$ + "/"), 0, "verification back on -> refused again")
