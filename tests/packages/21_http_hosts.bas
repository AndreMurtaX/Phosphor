rem ---------------------------------------------------------------
rem WHAT A HOST IS, AND WHAT IS SENT FOR IT (2026-10-07).
rem
rem An adversarial round found the library reading hosts wrongly in
rem five ways, each pinned below:
rem   * a dotted quad ending in .0 was taken for a NAME (the test read
rem     the last octet, not the first), so 10.1.2.0's certificate was
rem     checked against DNS names and refused;
rem   * a bracketed host the RTL could not parse -- [zzzz], [1::2::3] --
rem     was dialled as ::, five seconds apiece on Windows, and on Linux,
rem     which connects :: to ::1, it reached this machine's own services;
rem     0.0.0.0 did the same over IPv4;
rem   * ::ffff:127.0.0.1 IS 127.0.0.1 (RFC 4291 2.5.5.2), and Windows'
rem     IPv6 sockets refuse to dial it;
rem   * localhost. is localhost spelled in full, and the name check
rem     refused it as another host;
rem   * an address was sent as SNI, which RFC 6066 3 forbids.
rem And a response that trickles a byte at a time answered every
rem per-read timeout and was bounded by nothing.
rem
rem Every expected value comes from a definition, not off a run: RFC
rem 3986's dec-octet for a dotted quad (four of 0..255, nothing else),
rem RFC 4291 2.2 for IPv6 text (one "::" at most), RFC 6066 3 for SNI,
rem and arithmetic for the times (the trickle sends 20 bytes over four
rem seconds; a refusal before dialling takes no connect timeout).
rem ---------------------------------------------------------------

lf$ = chr$(10)
srv$ = server_url$()
port$ = mid$(srv$, instr(mid$(srv$, 8), ":") + 8)
v6$ = server_url_ipv6$("plain")
v6port$ = mid$(v6$, 14)
ca$ = http_ca_file$(server_ca_file$())
tlsport$ = mid$(server_url_https$(), 19)

test_case("hosts/every dotted quad is an address, whatever its octets")
rem Each octet swept over 0..255 with the other three held at 10, then
rem every product of the edge values 0, 1 and 255: 1024 + 81 quads.
n = 0
seen = 0
for pos = 1 to 4
  for v = 0 to 255
    o1 = 10 : o2 = 10 : o3 = 10 : o4 = 10
    if pos = 1 then o1 = v
    if pos = 2 then o2 = v
    if pos = 3 then o3 = v
    if pos = 4 then o4 = v
    q$ = str$(o1) + "." + str$(o2) + "." + str$(o3) + "." + str$(o4)
    seen = seen + 1
    n = n + http_is_ipv4(q$)
  next
next
edge@ = dim@(3)
edge@[1] = 0 : edge@[2] = 1 : edge@[3] = 255
for a = 1 to 3
  for b = 1 to 3
    for c = 1 to 3
      for d = 1 to 3
        q$ = str$(edge@[a]) + "." + str$(edge@[b]) + "." + str$(edge@[c]) + "." + str$(edge@[d])
        seen = seen + 1
        n = n + http_is_ipv4(q$)
      next
    next
  next
next
assert_eq(seen, 1105, "1024 + 81 quads were asked")
assert_eq(n, seen, "and every one is an address")
assert_eq(http_is_ipv4("256.1.1.1"), 0, "an octet above 255 is not")
assert_eq(http_is_ipv4("1.2.3"), 0, "nor three parts")
assert_eq(http_is_ipv4("1.2.3.4.5"), 0, "nor five")
assert_eq(http_is_ipv4("a.b.c.d"), 0, "nor letters")
assert_eq(http_is_ipv4("localhost"), 0, "a name is a name")
assert_eq(http_is_ipv4(""), 0, "and nothing is not an address")

test_case("hosts/IPv6 text is an address only when it parses")
assert_eq(http_is_ipv6("::1"), 1, "::1")
assert_eq(http_is_ipv6("[::1]"), 1, "bracketed, as a url writes it")
assert_eq(http_is_ipv6("0:0:0:0:0:0:0:1"), 1, "written out in full")
assert_eq(http_is_ipv6("::ffff:127.0.0.1"), 1, "with an IPv4 tail")
assert_eq(http_is_ipv6("::"), 1, "the unspecified address is an address")
assert_eq(http_is_ipv6("zzzz"), 0, "letters that are not hex are not")
assert_eq(http_is_ipv6("1::2::3"), 0, "nor two '::'")
assert_eq(http_is_ipv6("[evil.example]"), 0, "nor a name in brackets")
assert_eq(http_is_ipv6("127.0.0.1"), 0, "nor an IPv4 address")

test_case("hosts/a host that is not an address it claims is never dialled")
rem Each used to be dialled as :: -- five seconds apiece on Windows, a
rem local service on Linux. Refused before dialling, all eight together
rem take no connect timeout at all; two seconds is generous.
t0 = now()
assert_eq(http_status("http://[zzzz]:" + v6port$ + "/family"), 0, "[zzzz]")
assert_eq(http_status("http://[1::2::3]:" + v6port$ + "/family"), 0, "[1::2::3]")
assert_eq(http_status("http://[evil.example]:" + v6port$ + "/family"), 0, "[evil.example]")
assert_eq(http_status("http://[::1%25lo]:" + v6port$ + "/family"), 0, "a zone id")
assert_eq(http_status("http://[]:" + v6port$ + "/family"), 0, "empty brackets")
assert_eq(http_status("http://[::1]x:" + v6port$ + "/family"), 0, "text after the bracket")
assert_eq(http_status("http://[::]:" + v6port$ + "/family"), 0, "the unspecified IPv6 address")
assert_eq(http_status("http://0.0.0.0:" + port$ + "/"), 0, "the unspecified IPv4 address")
assert_true(millisecondsbetween(now(), t0) < 2000, "and none of them waited on a connect")

test_case("hosts/an IPv4-mapped address is dialled as that IPv4 address")
assert_eq(http_get$("http://[::ffff:127.0.0.1]:" + port$ + "/"), "phosphor http ok", "it reaches the IPv4 server")

test_case("hosts/a trailing dot names the same host")
assert_eq(http_get$("https://localhost.:" + tlsport$ + "/"), "phosphor http ok", "localhost. is localhost to the name check")
assert_eq(http_error(), 0, "and is not refused")

test_case("hosts/an address is never sent as SNI")
b$ = http_get$(server_url_https_ip$() + "/inspect")
assert_true(instr(b$, "sni=" + lf$) > 0, "an IPv4 address sends none")
b$ = http_get$("https://localhost:" + tlsport$ + "/inspect")
assert_true(instr(b$, "sni=localhost" + lf$) > 0, "a name sends itself")
b$ = http_get$("https://localhost.:" + tlsport$ + "/inspect")
assert_true(instr(b$, "sni=localhost" + lf$) > 0, "without its trailing dot")

test_case("hosts/a response that trickles is bounded by the run's deadline")
rem /trickle sends 20 bytes, one every 200 ms. Each read comes in time,
rem so only a deadline on the whole response can end it early.
b$ = http_get$(v6$ + "/trickle")
assert_eq(len(b$), 20, "the control: unbounded, all twenty bytes arrive")
x = http_test_deadline(1000)
t0 = now()
b$ = http_get$(v6$ + "/trickle")
ms = millisecondsbetween(now(), t0)
x = http_test_deadline(0)
assert_true(ms < 2500, "with a second left, it ends well inside the four seconds the body takes")
assert_true(len(b$) < 20, "and the body did not all arrive")
assert_eq(len(b$), 0, "a response cut off is no response: none of it is handed back")
assert_eq(http_error(), 4, "and http_error() says the run's time cut it off")
assert_eq(http_strerror$(4), "the run's time ran out before the answer was complete", "in words, too")
