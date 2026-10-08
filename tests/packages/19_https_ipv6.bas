rem ---------------------------------------------------------------
rem HTTPS OVER IPv6 (ledger m6), with the hostname check of m5.
rem
rem Two TLS servers on [::1], both signed by the throwaway CA: one holds
rem the localhost certificate (DNS:localhost only), the other the
rem address certificate (IP:127.0.0.1 and IP:::1). With the CA trusted:
rem   * https://[::1] on the address certificate verifies -- an IPv6
rem     literal is matched against the certificate's addresses -- and
rem     /family answers "ipv6";
rem   * https://[::1] on the localhost certificate is refused for its
rem     name: the address is not localhost (http_error() 3);
rem   * https://localhost on that server's port is reached through its
rem     AAAA record once IPv4 finds nothing listening there, and
rem     verifies, because the TLS layer is told the NAME (SNI and the
rem     check) while the socket dials the address;
rem   * a client handle goes the same way, and turning verification off
rem     lets the misnamed server answer.
rem ---------------------------------------------------------------

ca$ = http_ca_file$(server_ca_file$())
v% = http_verify_peer(1)
dns$ = server_url_ipv6$("https")
ip$ = server_url_ipv6$("https_ip")
dnsport$ = mid$(dns$, len("https://[::1]:") + 1)

test_case("https ipv6/an address matched as an address")
assert_eq(http_get$(ip$ + "/family"), "ipv6", "https://[::1] on the certificate that names ::1")
assert_eq(http_error(), 0, "and nothing is refused")

test_case("https ipv6/an address that is not the certificate's name")
assert_eq(http_status(dns$ + "/"), 0, "https://[::1] on the localhost certificate is refused")
assert_eq(http_error(), 3, "for its name")

test_case("https ipv6/a name reached through its AAAA record")
x$ = http_resolve6_as$("localhost", "::1")
assert_eq(http_get$("https://localhost:" + dnsport$ + "/family"), "ipv6", "IPv4 finds nothing there; IPv6 answers, and the name verifies")

test_case("https ipv6/a client handle")
c@ = http_client@(ip$)
assert_eq(http_get$(c@, "/family"), "ipv6", "a client aimed at https://[::1]")
x = http_free(c@)

test_case("https ipv6/verification off")
v% = http_verify_peer(0)
assert_eq(http_status(dns$ + "/"), 200, "the misnamed server answers when nothing is checked")
v% = http_verify_peer(1)
