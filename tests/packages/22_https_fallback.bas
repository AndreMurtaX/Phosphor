rem ---------------------------------------------------------------
rem HTTPS TRIES EVERY ADDRESS OF A NAME, AS HTTP DOES (2026-10-08;
rem docs/roadmap-net.md, Step 3).
rem
rem A name with several A records is tried address by address, so one
rem dead address does not fail a request the others would serve. Over
rem plain http that was always so. Over https the name was dialled as
rem written -- the socket layer's first A record only -- because a
rem connect pinned to an address would have shown SNI and the certificate
rem check that ADDRESS instead of the name. The TLS handler is now told
rem the name.
rem
rem The runner's resolver answers localhost as 127.0.0.9 then 127.0.0.1.
rem The servers bind 127.0.0.1 only, so .9 is dead. Every expected value
rem is derived from the rule, not read off a run:
rem   * the request is answered by the second address, and the localhost
rem     certificate is accepted -- it names localhost, the name asked for;
rem   * against the server whose certificate names only IP:127.0.0.1, the
rem     same request is REFUSED (http_error 3): the check is of the NAME,
rem     not of the address that was dialled, which that certificate does
rem     name -- a check of the address would have passed it;
rem   * the SNI the server saw is the name;
rem   * with every address dead the answer is a dead host -- status 0,
rem     http_error 0 -- not a refused name.
rem The client's connect timeout is one second, so each dead address
rem costs at most that (on Windows a refused connect costs the whole wait).
rem ---------------------------------------------------------------

lf$ = chr$(10)
ca$ = http_ca_file$(server_ca_file$())
tlsport$ = mid$(server_url_https$(), 19)
ipport$ = mid$(server_url_https_ip$(), 19)
x$ = http_resolve_as$("localhost", "127.0.0.9,127.0.0.1")

test_case("https-fallback/a name only the resolver knows is reached at its second address")
rem multi.test exists only in the runner's resolver, so only a request
rem that asks it -- and walks its list -- can get anywhere: the system
rem cannot resolve the name, which is what the old https path dialled. No
rem fixture certificate names multi.test (their CA's key is gone, so none
rem can be made), so this one case runs with verification off; the cases
rem below run it on, against names the certificates do carry.
x$ = http_resolve_as$("multi.test", "127.0.0.9,127.0.0.1")
m@ = http_client@("https://multi.test:" + tlsport$)
x = http_timeout(m@, 1000)
x = http_validatessl(m@, 0)
assert_eq(http_get$(m@, "/"), "phosphor http ok", "the dead first address is passed over")

test_case("https-fallback/a pinned address is checked as the name it is for")
c@ = http_client@("https://localhost:" + tlsport$)
x = http_timeout(c@, 1000)
assert_eq(http_get$(c@, "/"), "phosphor http ok", "localhost's second address answers too")
assert_eq(http_error(), 0, "and the certificate is accepted for the name")
b$ = http_get$(c@, "/inspect")
assert_true(instr(b$, "sni=localhost" + lf$) > 0, "SNI carried the name, not the address dialled")

test_case("https-fallback/the name is checked, not the address")
i@ = http_client@("https://localhost:" + ipport$)
x = http_timeout(i@, 1000)
assert_eq(http_status(i@, "/"), 0, "a certificate naming only the address is refused")
assert_eq(http_error(), 3, "for the name")

test_case("https-fallback/every address dead is a dead host")
x$ = http_resolve_as$("dead.test", "127.0.0.9,127.0.0.8")
d@ = http_client@("https://dead.test:" + tlsport$)
x = http_timeout(d@, 1000)
assert_eq(http_status(d@, "/"), 0, "nothing answers")
assert_eq(http_error(), 0, "and that is not a refusal")
