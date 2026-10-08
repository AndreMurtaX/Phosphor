rem ---------------------------------------------------------------
rem AN ANSWER THAT BROKE OFF IS NO ANSWER, HOWEVER IT BROKE OFF, AND THE
rem DEADLINE BOUNDS THE SEND AND THE TLS RECORD TOO (2026-10-08, a fourth
rem adversarial pass).
rem
rem FPC's client ends a body at end-of-stream without raising, so a peer
rem that CLOSED early -- fewer bytes than its Content-Length, a chunked
rem body before its last chunk -- was a 200 with the part that had come and
rem http_error() 0. And when the stream ended inside the HEADERS it handed
rem back a 4096-byte buffer the server never sent. RFC 9112 6.3 and 8: such
rem a message is incomplete. A chunked body with its last chunk, and a body
rem with no length that ends at the close, are complete -- the two
rem controls below, which must keep their bodies.
rem
rem A reset is the PEER's doing even 50 ms before the deadline (5, not 4);
rem an upload drained in bursts held a one-second request 8.4 s; a TLS
rem record trickled inside itself held one 11.4 s. Each ends at its
rem deadline now: the bound is 1000 ms and the half second a scheduler is
rem allowed.
rem ---------------------------------------------------------------

v6$ = server_url_ipv6$("plain")
ca$ = http_ca_file$(server_ca_file$())

test_case("broken/a body short of its Content-Length is no answer")
b$ = http_get$(v6$ + "/shortclose")
assert_eq(len(b$), 0, "none of the ten bytes of a promised hundred")
assert_eq(http_error(), 5, "and http_error() says it broke off")

test_case("broken/a chunked body cut before its last chunk is no answer")
b$ = http_get$(v6$ + "/chunkcut")
assert_eq(len(b$), 0, "no partial body")
assert_eq(http_error(), 5, "broken off")

test_case("broken/headers cut by the close are no answer, and no invented body")
s = http_status(v6$ + "/hdrcut")
assert_eq(s, 0, "no status")
b$ = http_get$(v6$ + "/hdrcut")
assert_eq(len(b$), 0, "and not the 4096 bytes FPC's buffer held")
assert_eq(http_error(), 5, "broken off")

test_case("broken/a complete chunked body and a close-delimited one keep their bodies")
assert_eq(http_get$(v6$ + "/chunkok"), "AAAAAAAAAA", "the chunked body, whole")
assert_eq(http_error(), 0, "with no error")
assert_eq(http_get$(v6$ + "/closeok"), "AAAAAAAAAA", "and the body that ends at the close")
assert_eq(http_error(), 0, "with no error")

test_case("broken/a reset just before the deadline is the peer's, not the clock's")
x = http_test_deadline(1000)
b$ = http_get$(v6$ + "/rst")
e = http_error()
x = http_test_deadline(0)
assert_eq(len(b$), 0, "no partial body")
assert_eq(e, 5, "broken off by the peer (5), not cut by the run's time (4)")

test_case("broken/an upload drained in bursts ends at the deadline")
big$ = string$(2097152, 65)
x = http_test_deadline(1000)
t0 = now()
b$ = http_post$(server_url_ipv6$("drain") + "/", big$)
ms = millisecondsbetween(now(), t0)
e = http_error()
x = http_test_deadline(0)
assert_true(ms < 1500, "the send is bounded by the deadline too")
assert_eq(e, 4, "and the run's time is what cut it")

test_case("broken/a TLS record trickled inside itself ends at the deadline")
x = http_test_deadline(1000)
t0 = now()
b$ = http_get$(server_url_ipv6$("relay") + "/late")
ms = millisecondsbetween(now(), t0)
e = http_error()
x = http_test_deadline(0)
assert_true(ms < 1500, "OpenSSL's own reads do not buy another wait")
assert_eq(len(b$), 0, "no partial body")
assert_eq(e, 4, "and the run's time is what cut it")
