rem ---------------------------------------------------------------
rem http_ca_file$ under the sandbox (2026-10-09, round 2).
rem
rem OpenSSL, not this engine, opens the CA bundle -- so the path never
rem passes through a Pascal file call, and scripts/check-sandbox.py,
rem which knows the engine's file primitives, could not see it. The
rem setter recorded ANY path. A script confined to its root pointed it
rem at a file outside, and the next https request answered 200 when
rem that file was the CA and 0 when it was not: an oracle on files the
rem sandbox exists to hide. http_clientcert, the other path OpenSSL
rem opens, asked the gate from the day it was written.
rem
rem The runner's root is its working directory (the checkout), so
rem "outside" is the parent of it. Nothing here creates, writes or
rem deletes anything; the outside names need not exist, because the
rem gate refuses a path by where it RESOLVES, not by whether it is there.
rem ---------------------------------------------------------------

base$ = server_url_https$()
port$ = mid$(base$, len("https://127.0.0.1:") + 1)
byname$ = "https://localhost:" + port$
ca$ = server_ca_file$()
v% = http_verify_peer(1)

test_case("ca-sandbox/a bundle inside the root is recorded")
assert_eq(http_ca_file$(ca$), ca$, "the path comes back")
assert_eq(ioerror(), 0, "and ioerror() says nothing was refused")
assert_eq(http_status(byname$ + "/"), 200, "and the chain it holds is trusted")

test_case("ca-sandbox/a bundle outside the root is refused")
assert_eq(http_ca_file$("../phosphor-ca-outside.pem"), "", "a relative path that climbs out answers nothing")
assert_eq(ioerror(), 5, "and ioerror() says access denied")
up$ = dir_getparent$(sandboxroot$())
assert_eq(http_ca_file$(up$ + dirseparator$() + "phosphor-ca-outside.pem"), "", "an absolute path outside answers nothing")
assert_eq(ioerror(), 5, "and ioerror() says access denied again")

test_case("ca-sandbox/a refused path does not replace the bundle")
assert_eq(http_status(byname$ + "/"), 200, "the bundle recorded earlier still verifies")

test_case("ca-sandbox/a refusal is not sticky")
assert_eq(http_ca_file$(ca$), ca$, "an inside path is recorded again")
assert_eq(ioerror(), 0, "and ioerror() is this call's: 0")
