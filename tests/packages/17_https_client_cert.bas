rem ---------------------------------------------------------------
rem A CLIENT CERTIFICATE (ledger m7, the half it was split into).
rem
rem The runner stands up a TLS server that REQUIRES a client certificate
rem signed by the throwaway CA (SSL_VERIFY_FAIL_IF_NO_PEER_CERT, which
rem FPC never sets by itself). Its own certificate is the localhost one,
rem so with the CA trusted the client verifies it end to end. Every
rem expectation follows from that, not from a run:
rem   * a client that presents nothing is refused by the server: 0;
rem   * a client that presents the CA-signed client certificate is
rem     answered: 200 and the body;
rem   * the key may live in the certificate file -- keyfile$ "" says so;
rem   * "" for the certificate takes it away again, and http_reset does
rem     too, so both are refused once more;
rem   * a freed handle answers 0 with http_error() 1;
rem   * a path holding a NUL byte is refused by the sandbox gate even for
rem     a read (docs/embedding.md), so it answers 0 with ioerror() 5 and
rem     records nothing -- the client keeps the certificate it had.
rem CONNECT, the other half of m7, is deferred: fphttpclient has none.
rem ---------------------------------------------------------------

url$ = server_url_mtls$()
ca$ = http_ca_file$(server_ca_file$())
v% = http_verify_peer(1)

test_case("client cert/without one the server refuses")
c@ = http_client@(url$)
assert_eq(http_status(c@, "/"), 0, "no client certificate: the handshake is refused")

test_case("client cert/with one it answers")
assert_eq(http_clientcert(c@, server_client_cert$("cert"), server_client_cert$("key")), 1, "the certificate and key are recorded")
assert_eq(http_error(), 0, "with no error")
assert_eq(http_status(c@, "/"), 200, "the server accepts the certificate its CA signed")
assert_eq(http_get$(c@, "/"), "phosphor http ok", "and the body comes back")

test_case("client cert/the key may live in the certificate file")
d@ = http_client@(url$)
assert_eq(http_clientcert(d@, server_client_cert$("combined"), ""), 1, "one PEM holding both")
assert_eq(http_status(d@, "/"), 200, "is presented the same way")

test_case("client cert/a relative path means where it was recorded")
rem Recorded relative to the fixture directory, then the program moves
rem back. OpenSSL opens the file only when the request is made, so the
rem path must have been made absolute when it was recorded -- the same
rem string the sandbox gate judged.
here$ = dir_getcurrent$()
full$ = server_client_cert$("combined")
e@ = http_client@(url$)
x = chdir(dir_getparent$(full$))
assert_eq(http_clientcert(e@, "tls_test_client_combined.pem", ""), 1, "a path relative to the fixture directory")
x = chdir(here$)
assert_eq(http_status(e@, "/"), 200, "still names that file after the program has moved")
x = http_free(e@)

test_case("client cert/a refused path records nothing")
assert_eq(http_clientcert(d@, "nul" + chr$(0) + "byte.pem", ""), 0, "a path with a NUL byte is refused")
assert_eq(ioerror(), 5, "by the sandbox gate")
assert_eq(http_status(d@, "/"), 200, "and the certificate it had is still the one it presents")

test_case("client cert/taking it away")
assert_eq(http_clientcert(c@, "", ""), 1, "an empty certificate path removes it")
assert_eq(http_status(c@, "/"), 0, "and the server refuses again")
x = http_reset(d@)
assert_eq(http_status(d@, "/"), 0, "http_reset removes it too")

test_case("client cert/a freed handle")
x = http_free(c@)
assert_eq(http_clientcert(c@, server_client_cert$("cert"), ""), 0, "is not a client")
assert_eq(http_error(), 1, "http_error says so")
x = http_free(d@)
