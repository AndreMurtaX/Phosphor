rem ---------------------------------------------------------------
rem THE HOSTNAME CHECK FAILS CLOSED (ledger m5).
rem
rem The check binds four OpenSSL names by hand, because FPC 3.2.2's own
rem binding answers nil on OpenSSL 3. A machine whose OpenSSL lacks one
rem of them must REFUSE the connection -- a check that cannot run must
rem not read as a check that passed. Every real OpenSSL has all four, so
rem the runner's http_tls_withhold makes the package find one missing
rem (PhosphorHttpLib's HttpTlsWithhold seam). The binding happens once
rem per process, which is why this is its own file and the withholding
rem is its first statement.
rem
rem Derived, not run: localhost with the trusted CA verifies end to end
rem in 15_https_hostname, so the ONLY reason it can be refused here is
rem the withheld name. Turning verification off still turns the check
rem off, so that request succeeds.
rem ---------------------------------------------------------------

x = http_tls_withhold("X509_check_host")
base$ = server_url_https$()
port$ = mid$(base$, len("https://127.0.0.1:") + 1)
byname$ = "https://localhost:" + port$
ca$ = http_ca_file$(server_ca_file$())
v% = http_verify_peer(1)

test_case("fail closed/a missing OpenSSL name refuses, it does not pass")
assert_eq(http_status(byname$ + "/"), 0, "localhost, a trusted chain, the right name -- and no way to check it")
assert_eq(http_error(), 3, "reported as a refusal for the name")

test_case("fail closed/opting out still opts out")
v% = http_verify_peer(0)
assert_eq(http_status(byname$ + "/"), 200, "with verification off nothing is checked")
