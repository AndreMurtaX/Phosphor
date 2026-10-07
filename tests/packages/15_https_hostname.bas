rem ---------------------------------------------------------------
rem HTTPS VERIFIES THE HOSTNAME, not only the chain (ledger m5).
rem
rem The runner's TLS server holds a certificate a throwaway CA signed
rem for DNS:localhost and nothing else. With that CA trusted through
rem http_ca_file$, one server and one chain answer two URLs:
rem https://localhost must verify end to end, and https://127.0.0.1
rem must be REFUSED -- the chain is just as valid, but the certificate
rem is not for that host. Until m5 it was accepted: the chain was
rem checked and the name never was.
rem
rem Every expectation follows from the certificate, not from a run: it
rem carries one DNS name, localhost, and no IP address, so a name
rem check passes for "localhost" and fails for "127.0.0.1". A refusal
rem for the name sets http_error() to 3; a request that is not refused
rem sets it back to 0. Turning verification off -- globally or for one
rem client -- turns the name check off with it, as documented.
rem ---------------------------------------------------------------

base$ = server_url_https$()
port$ = mid$(base$, len("https://127.0.0.1:") + 1)
byname$ = "https://localhost:" + port$
byip$ = "https://127.0.0.1:" + port$
ca$ = http_ca_file$(server_ca_file$())
v% = http_verify_peer(1)

test_case("hostname/a trusted chain for the right name is accepted")
assert_eq(http_status(byname$ + "/"), 200, "localhost: the chain is trusted and the name matches")
assert_eq(http_error(), 0, "and nothing is refused")
assert_eq(http_get$(byname$ + "/"), "phosphor http ok", "and the body comes back")

test_case("hostname/the same chain under another name is refused")
assert_eq(http_status(byip$ + "/"), 0, "127.0.0.1: the certificate names localhost only")
assert_eq(http_error(), 3, "and http_error says it was the name")
assert_eq(http_strerror$(3), "the server's certificate is not for this host", "in words")
assert_eq(http_get$(byip$ + "/"), "", "and no body comes back")

test_case("hostname/a request that is not refused clears it")
assert_eq(http_status(byname$ + "/"), 200, "localhost again")
assert_eq(http_error(), 0, "and the 3 is gone")

test_case("hostname/a client handle is checked the same way")
c@ = http_client@(byip$)
assert_eq(http_status(c@, "/"), 0, "a client aimed at 127.0.0.1 is refused")
assert_eq(http_error(), 3, "for its name")
d@ = http_client@(byname$)
assert_eq(http_status(d@, "/"), 200, "and one aimed at localhost is not")

test_case("hostname/turning verification off turns the name check off too")
e@ = http_client@(byip$)
x = http_validatessl(e@, 0)
assert_eq(http_status(e@, "/"), 200, "one client with validation off reaches 127.0.0.1")
assert_eq(http_status(c@, "/"), 0, "while the client that kept it is still refused")
v% = http_verify_peer(0)
assert_eq(http_status(byip$ + "/"), 200, "and with verification off globally, so does a bare request")
v% = http_verify_peer(1)
assert_eq(http_status(byip$ + "/"), 0, "back on: refused again")
x = http_free(c@)
x = http_free(d@)
x = http_free(e@)

rem A SECOND SERVER, the mirror image: the same CA signed its certificate
rem for IP:127.0.0.1 and no DNS name. An address must be matched against
rem the certificate's addresses -- a check that treated "127.0.0.1" as a
rem DNS name would refuse it here, and only this server can show that.
rem Its CN is deliberately NOT the address: X509_check_host falls back to
rem the CN when a certificate has no DNS name, so with CN=127.0.0.1 the
rem wrong check passed through the CN and the first sweep could not tell.
ipbase$ = server_url_https_ip$()
ipport$ = mid$(ipbase$, len("https://127.0.0.1:") + 1)

test_case("hostname/an address is checked as an address")
assert_eq(http_status(ipbase$ + "/"), 200, "127.0.0.1 on the IP certificate: the address matches")
assert_eq(http_error(), 0, "and nothing is refused")
assert_eq(http_status("https://localhost:" + ipport$ + "/"), 0, "localhost on the IP certificate: it names no host")
assert_eq(http_error(), 3, "refused for its name")

rem WHICH OpenSSL WAS LOADED. Windows had https only by accident until
rem m5: FPC's names stop at OpenSSL 1.1, and Git's copy was on PATH. The
rem package now prefers a whole OpenSSL 3 pair. The runner asks Windows
rem with LoadLibrary whether that pair exists, independently of the
rem package; where it does, the version must be 3. Elsewhere there is no
rem expectation to derive, so the comparison is with itself -- one
rem assertion on every platform keeps the golden's count the same.
test_case("hostname/the OpenSSL that was loaded")
ver$ = server_openssl_version$()
assert_eq(left$(ver$, 8), "OpenSSL ", "the loaded library reports a version")
if server_openssl3_pair() = 1 then want$ = "OpenSSL 3" else want$ = left$(ver$, 9)
assert_eq(left$(ver$, 9), want$, "and on Windows with both OpenSSL 3 DLLs present, it is 3")
