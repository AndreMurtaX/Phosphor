rem ---------------------------------------------------------------
rem THE URL THAT IS JUDGED IS THE URL THAT IS DIALLED (2026-10-09,
rem round 2 of the adversarial loop).
rem
rem Two parsers read every url. RFC 3986 (Appendix B) ends the
rem authority at the FIRST '/', '?' or '#', and the fragment begins at
rem the FIRST '#'. FPC's ParseURI -- which decides the host, the port
rem and the request line -- takes the bookmark after the LAST '#', the
rem params after the LAST '?', and only then the authority, up to the
rem first '/'. So with a '?' or '#' before an '@', the two read
rem different hosts and ports out of one url.
rem
rem   H1. Round 1's port range check judged the RFC's authority. In
rem       http://127.0.0.1:1?@127.0.0.1:(P+65536)? the RFC reads host
rem       127.0.0.1, port 1 (a usable port); ParseURI reads the
rem       authority 127.0.0.1:1?@127.0.0.1:(P+65536), host 127.0.0.1
rem       after the first '@', and P+65536 kept in a Word -- port P.
rem       The check passed and P was dialled. Now a url on which the two
rem       readings differ in scheme, userinfo, host or port is refused,
rem       as an unusable host is: status 0, http_error() 0, nothing
rem       dialled. A port too long for any integer, which ParseURI
rem       RAISES on (StrToInt), is refused the same way, not a fault.
rem   H2. With two '#', ParseURI took the bookmark after the LAST one,
rem       and what lay between the two went into the request line:
rem       /p#a#b was asked for as "GET /p#a". The fragment -- everything
rem       from the FIRST '#' (RFC 3986 3.5) -- is now removed before the
rem       url reaches FPC, on every path: the bare verbs, the client
rem       verbs, http_get_via$ and every redirect hop.
rem
rem The RAW server (server_url_raw$) answers the request head it was
rem sent, byte for byte, and counts its connections (raw_hits); its
rem /b/c/d;p?q answers 302 to whatever raw_location$ last set. The
rem parsing server (server_url$) answers "phosphor http ok" on /.
rem ---------------------------------------------------------------

cr$ = chr$(13)
raw$ = server_url_raw$()
rport = val(mid$(raw$, 18))
srv$ = server_url$()
wrap$ = str$(rport + 65536)

function reqline$(b$) local p
  p = instr(b$, cr$)
  if p = 0 then
    return b$
  endif
  return mid$(b$, 1, p - 1)
endfunction

test_case("authority/the control: one '?' before an '@' is a query")
rem http://127.0.0.1:1?@x -- both readings end the authority at the
rem only '?': host 127.0.0.1, port 1, the query "@x". They agree, so the
rem url is used: here, the parsing server's own port, and its answer.
assert_eq(http_get$(srv$ + "?@x"), "phosphor http ok", "a query holding an '@'")

test_case("authority/a '?' before the '@' does not move the port")
before = raw_hits()
u$ = "http://127.0.0.1:1?@127.0.0.1:" + wrap$ + "?"
assert_eq(http_status(u$), 0, "refused")
assert_eq(http_error(), 0, "as an unusable host is")
c@ = http_client@(raw$)
assert_eq(http_status(c@, u$), 0, "through a client")
assert_eq(http_status("http://x?@127.0.0.1:" + str$(rport) + "?"), 0, "nor the port written plainly: the hosts differ")
assert_eq(raw_hits() - before, 0, "and the raw server was never dialled")

test_case("authority/a '#' before the '@' is a fragment, and not sent")
rem After the FIRST '#' everything is the fragment, so this url is the
rem parsing server's /, which answers -- and the raw server, the host
rem ParseURI read out of the fragment, is never dialled.
before = raw_hits()
assert_eq(http_get$(srv$ + "/#@127.0.0.1:" + wrap$ + "#"), "phosphor http ok", "the host before the '#'")
assert_eq(http_get$(srv$ + "#@127.0.0.1:" + str$(rport) + "#"), "phosphor http ok", "with no path either")
assert_eq(raw_hits() - before, 0, "and the host in the fragment was never dialled")

test_case("authority/a redirect hop is judged as the first url is")
x$ = raw_location$("http://127.0.0.1:1?@127.0.0.1:" + wrap$ + "?")
r@ = http_client@(raw$)
before = raw_hits()
assert_eq(http_status(r@, "/b/c/d;p?q"), 0, "the hop is refused")
assert_eq(http_error(), 0, "with no error code")
assert_eq(raw_hits() - before, 1, "only the first request connected")

test_case("fragment/two '#': nothing after the first reaches the request line")
assert_eq(reqline$(http_get$(raw$ + "/p#a#b")), "GET /p HTTP/1.1", "a bare verb")
assert_eq(reqline$(http_get$(raw$ + "/p?q=1#a#b")), "GET /p?q=1 HTTP/1.1", "after a query")
assert_eq(reqline$(http_get$(raw$ + "/p#a?b#c")), "GET /p HTTP/1.1", "a '?' between them")
f@ = http_client@(raw$)
assert_eq(reqline$(http_get$(f@, "/p#a#b")), "GET /p HTTP/1.1", "a client verb")
x = http_param(f@, "a", "1")
assert_eq(reqline$(http_get$(f@, "/r#x#y")), "GET /r?a=1 HTTP/1.1", "a client verb with params")
assert_eq(reqline$(http_post$(f@, "/s#x#y", "")), "POST /s?a=1 HTTP/1.1", "a post")
assert_eq(reqline$(http_get_via$(raw$ + "/v#a#b", "127.0.0.1")), "GET /v HTTP/1.1", "http_get_via$")

test_case("fragment/two '#' in a redirect's Location")
x$ = raw_location$(raw$ + "/head#a#b")
g@ = http_client@(raw$)
assert_eq(reqline$(http_get$(g@, "/b/c/d;p?q")), "GET /head HTTP/1.1", "an absolute Location")
x$ = raw_location$("/head#a#b")
assert_eq(reqline$(http_get$(g@, "/b/c/d;p?q")), "GET /head HTTP/1.1", "a relative one")

test_case("authority/a port past 32 bits, read out of a query, is refused")
rem ParseURI reads port digits with StrToInt and keeps the low 16 bits:
rem measured, :4294967297 is port 1 and :99999999999 is 59391
rem (99999999999 mod 65536). So P + 2^32 is port P.
before = raw_hits()
assert_eq(http_status("http://127.0.0.1:1?@127.0.0.1:" + str$(rport + 4294967296) + "?"), 0, "refused")
p@ = http_client@(raw$)
x = http_proxy(p@, "127.0.0.1", rport)
assert_eq(http_status(p@, "http://127.0.0.1:1?@127.0.0.1:99999999999?"), 0, "and through a proxy")
assert_eq(raw_hits() - before, 0, "neither connected")

test_case("authority/the url handed on, read with the library's own function")
rem Each expected url is written out by hand from the rule: the
rem fragment goes (from the FIRST '#'), an empty port loses its ':',
rem and a url the two parsers read differently is '' (refused).
assert_eq(http_wire_url$("http://h/p?q#f#g"), "http://h/p?q", "the fragment, from the first '#'")
assert_eq(http_wire_url$("http://h:/p"), "http://h/p", "an empty port is no port (RFC 3986 6.2.3)")
assert_eq(http_wire_url$("http://[::1]:/p"), "http://[::1]/p", "an IPv6 literal's too")
assert_eq(http_wire_url$("http://u:pw@h:8080/p"), "http://u:pw@h:8080/p", "a userinfo both read alike")
assert_eq(http_wire_url$("http://h:00080/"), "http://h:00080/", "leading zeros")
assert_eq(http_wire_url$("http://h:1?@g:80?"), "", "host h port 1, or host g port 80")
assert_eq(http_wire_url$("http://h:1#@g:80#"), "http://h:1", "a fragment is not an authority")
assert_eq(http_wire_url$("http://a@b@h/"), "", "two '@' (RFC 3986 3.2.1)")
assert_eq(http_wire_url$("http://[::1]x/"), "", "a bracket followed by neither ':' nor the end")
assert_eq(http_wire_url$("http://[::1/"), "", "a bracket never closed")
assert_eq(http_wire_url$("http://h:0/"), "", "port 0")
assert_eq(http_wire_url$("http://h:65535/"), "http://h:65535/", "the last port")
assert_eq(http_wire_url$("http://h:65536/"), "", "one past it")
assert_eq(http_wire_url$("http://h:2147483648/"), "", "2^31, which ParseURI reads as port 0")
assert_eq(http_wire_url$("http://h:8o/"), "", "a port of letters")

test_case("authority/a generated sweep against ParseURI itself")
rem http_url_sweep$ (the runner) checks the library's verdict against
rem an oracle written apart from it, on every url "http://" + A + T:
rem A every string of 0..4 characters over ? # @ : [ ] / % h 1 -- 1 +
rem 10 + 100 + 1000 + 10000 = 11111 -- and five real authorities with
rem two of the eight delimiters inserted at every pair of positions
rem i <= j, (L+1)(L+2)/2 * 8 * 8 each: u:p@127.0.0.1:8080 (L 18, 190
rem pairs), [::1]:443 (9, 55), h.test (6, 28), h:65616 (7, 36) and
rem h: (2, 6) -- 315 pairs * 64 = 20160; T one of seven tails.
rem (11111 + 20160) * 7 = 218897.
s$ = http_url_sweep$()
assert_eq(mid$(s$, 1, 16), "checked=218897 u", "every url was asked")
assert_true(instr(s$, " mismatches=0") > 0, "and the library agreed with the oracle on each: " + s$)
assert_true(instr(s$, " usable=0 ") = 0, "some were usable")
assert_true(instr(s$, " refused=0 ") = 0, "and some refused")
