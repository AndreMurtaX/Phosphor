rem ---------------------------------------------------------------
rem AN ANSWER THAT DID NOT ARRIVE WHOLE IS NOT AN ANSWER, AND NO READ
rem OUTLIVES THE DEADLINE (2026-10-08, a third adversarial pass).
rem
rem The runner's [::1] server has three peers for this file:
rem   /silent  ten of a promised hundred bytes, then two seconds of nothing;
rem   /late    the same ten, one more byte at 900 ms, then nothing;
rem   tlslate  reads the ClientHello, sends a TLS record header at 900 ms,
rem            then nothing.
rem What was measured before the fix, and what the rules say instead:
rem   * /silent under a deadline answered a 200 with the ten bytes and
rem     http_error() 0. http.md: a request the run's time cuts off answers
rem     status 0, no body, and 4.
rem   * /late held a one-second deadline almost two: the per-read timeout
rem     was set once and restarts with every read, so a read begun at
rem     900 ms waited a whole second more. One deadline bounds the request.
rem   * tlslate likewise -- and on Windows a shutdown() from another thread
rem     does not wake a read already blocked, so the guard that tried it
rem     still let the call run on.
rem   * /silent with no deadline but a client read timeout answered the
rem     same partial 200. A body that broke off is not the body: status 0,
rem     no body, http_error() 5.
rem   * ::ffff:0.0.0.0 IS 0.0.0.0, which Linux connects to this machine;
rem     the unspecified address is refused, mapped or not, before any dial.
rem The bound in each "ends inside" check is the deadline, 1000 ms, plus
rem the half second a scheduler is allowed; the old behaviour was 1900.
rem ---------------------------------------------------------------

v6$ = server_url_ipv6$("plain")
srv$ = server_url$()
port$ = mid$(srv$, instr(mid$(srv$, 8), ":") + 8)
ca$ = http_ca_file$(server_ca_file$())

test_case("cut/a body that goes silent is cut at the deadline, and is no answer")
x = http_test_deadline(1000)
t0 = now()
b$ = http_get$(v6$ + "/silent")
ms = millisecondsbetween(now(), t0)
e = http_error()
x = http_test_deadline(0)
assert_eq(len(b$), 0, "none of the ten bytes is handed back")
assert_eq(e, 4, "and http_error() says the run's time cut it off")
assert_true(ms < 1500, "at the deadline")
rem THE [::1] SERVER ANSWERS ONE CONNECTION AT A TIME, and /silent holds its
rem connection two seconds after the client has gone. Without this wait the
rem next case's request sat in the server's queue and measured that instead
rem -- it passed on the code it was written to catch.
x = pause(2.2)

test_case("cut/a byte just before the deadline does not buy another wait")
x = http_test_deadline(1000)
t0 = now()
b$ = http_get$(v6$ + "/late")
ms = millisecondsbetween(now(), t0)
e = http_error()
x = http_test_deadline(0)
assert_true(ms < 1500, "the request ends at its deadline, not a read timeout after the late byte")
assert_eq(len(b$), 0, "and hands back nothing")
assert_eq(e, 4, "and says why")
x = pause(2.2)

test_case("cut/a TLS header sent late does not hold the handshake past the deadline")
x = http_test_deadline(1000)
t0 = now()
s = http_status(server_url_ipv6$("tlslate") + "/")
ms = millisecondsbetween(now(), t0)
e = http_error()
x = http_test_deadline(0)
assert_eq(s, 0, "no answer")
assert_true(ms < 1500, "and it ends at the deadline")
assert_eq(e, 4, "and http_error() says time cut it off")

test_case("cut/a body broken off by the client's own read timeout is no answer either")
c@ = http_client@(v6$)
x = http_responsetimeout(c@, 500)
b$ = http_get$(c@, "/silent")
e = http_error()
assert_eq(len(b$), 0, "no partial body")
assert_eq(e, 5, "and http_error() says the answer broke off")
assert_eq(http_strerror$(5), "the answer broke off before it was complete", "in words, too")
assert_eq(http_status(srv$ + "/"), 200, "and the next request is answered normally")
assert_eq(http_error(), 0, "with no error left over")

test_case("cut/the unspecified address is never dialled, mapped or not")
assert_eq(http_status("http://[::ffff:0.0.0.0]:" + port$ + "/"), 0, "::ffff:0.0.0.0 is 0.0.0.0, refused")
x$ = http_resolve_as$("zero.test", "0.0.0.0")
x$ = http_resolve6_as$("zero.test", "")
assert_eq(http_status("http://zero.test:" + port$ + "/"), 0, "and so is a resolver's 0.0.0.0")
