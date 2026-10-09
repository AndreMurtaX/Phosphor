rem ---------------------------------------------------------------
rem THE REQUEST TARGET IS THE PATH AND QUERY THE URL NAMES, BYTE FOR
rem BYTE (2026-10-09, round 3 of the adversarial loop).
rem
rem FPC's client builds the request line from ParseURI's pieces
rem (fphttpclient.pp, GetServerURL): Path, then a '/' whenever Path
rem does not end in one, then Document, then '?' and Params when
rem Params is not empty. ParseURI (uriparser.pp) takes Document as the
rem text after the LAST '/' -- but its backward scan STOPS at a ':'
rem and then sets no Document at all. So a last segment holding a
rem colon stayed in Path, and GetServerURL appended a '/':
rem
rem   /v1/items:batchGet   was asked for as   /v1/items:batchGet/
rem   /a:b?q               was asked for as   /a:b/?q
rem
rem with status 200 and no error -- a different resource, silently.
rem Two more spellings of the same rebuild: a last segment of '.' or
rem '..' is likewise left in Path (/a/.. went out as /a/../), and an
rem EMPTY query was dropped with its '?' (/a? went out as /a).
rem
rem The expected request lines below are not read off a run. RFC 3986
rem 3.3 makes ':' '@' ';' '=' and a percent-escape legal path text, a
rem '.' or '..' segment is path text until something RESOLVES the
rem url (5.2, which a request url is not put through), and 6.2.3
rem keeps a delimiter whose component is empty; RFC 9112 3.2.1 (RFC
rem 7230 5.3.1) sends the origin-form target as the absolute path and
rem query as written, and '/' for an empty path. So each target is the
rem very text the test built the url from.
rem
rem The RAW server (server_url_raw$) answers the request head it was
rem sent, byte for byte; its /b/c/d;p?q answers 302 to whatever
rem raw_location$ last set.
rem ---------------------------------------------------------------

cr$ = chr$(13)
raw$ = server_url_raw$()
rport = val(mid$(raw$, 18))

function reqline$(b$) local p
  p = instr(b$, cr$)
  if p = 0 then
    return b$
  endif
  return mid$(b$, 1, p - 1)
endfunction

rem Sixteen path segments: every character RFC 3986 3.3 lets a segment
rem carry besides unreserved ones that FPC's parser treats specially,
rem alone, between letters and at either end; a percent-escaped colon;
rem the two dot segments; and the empty segment.
function seg$(i)
  if i = 1 then
    return "a"
  endif
  if i = 2 then
    return ":"
  endif
  if i = 3 then
    return "a:b"
  endif
  if i = 4 then
    return "items:batchGet"
  endif
  if i = 5 then
    return "p:"
  endif
  if i = 6 then
    return ":x"
  endif
  if i = 7 then
    return "@"
  endif
  if i = 8 then
    return "a@b"
  endif
  if i = 9 then
    return "a;b"
  endif
  if i = 10 then
    return "a=b"
  endif
  if i = 11 then
    return "%3A"
  endif
  if i = 12 then
    return "a%3Ab"
  endif
  if i = 13 then
    return "."
  endif
  if i = 14 then
    return ".."
  endif
  if i = 15 then
    return "k=v;w:z@y"
  endif
  return ""
endfunction

rem Six queries: none, empty, plain, and three holding a ':' -- one with
rem a '/', one with a second '?' (ParseURI cuts params at the LAST '?').
function qry$(i)
  if i = 0 then
    return ""
  endif
  if i = 1 then
    return "?"
  endif
  if i = 2 then
    return "?q"
  endif
  if i = 3 then
    return "?a:b"
  endif
  if i = 4 then
    return "?x/y:z"
  endif
  return "?a?b:c"
endfunction

test_case("path/the finding: a last segment holding a colon")
assert_eq(reqline$(http_get$(raw$ + "/v1/items:batchGet")), "GET /v1/items:batchGet HTTP/1.1", "GET, no slash added")
assert_eq(reqline$(http_post$(raw$ + "/v1/items:batchGet", "{}")), "POST /v1/items:batchGet HTTP/1.1", "POST the same")
assert_eq(reqline$(http_get$(raw$ + "/a:b?q")), "GET /a:b?q HTTP/1.1", "and before a query")
assert_eq(reqline$(http_get$(raw$ + "/c:/x")), "GET /c:/x HTTP/1.1", "the control: a colon not in the last segment")

test_case("path/the other rebuilds of the same request line")
assert_eq(reqline$(http_get$(raw$ + "/a/..")), "GET /a/.. HTTP/1.1", "a last segment of '..' gets no slash")
assert_eq(reqline$(http_get$(raw$ + "/a/.")), "GET /a/. HTTP/1.1", "nor one of '.'")
assert_eq(reqline$(http_get$(raw$ + "/a?")), "GET /a? HTTP/1.1", "an empty query keeps its '?' (RFC 3986 6.2.3)")
assert_eq(reqline$(http_get$(raw$)), "GET / HTTP/1.1", "an empty path is sent as '/'")
assert_eq(reqline$(http_get$(raw$ + "?q:r")), "GET /?q:r HTTP/1.1", "and before a query too")
assert_eq(reqline$(http_get$(raw$ + "/a:b#frag")), "GET /a:b HTTP/1.1", "a fragment is never sent")

test_case("path/through a client, its params, a proxy and a redirect")
c@ = http_client@(raw$)
assert_eq(reqline$(http_get$(c@, "/v1/projects/p:get")), "GET /v1/projects/p:get HTTP/1.1", "a client verb")
x = http_param(c@, "k", "v")
rem http.md: the params are appended after a '?', or after '&' when the
rem path already carries a query.
assert_eq(reqline$(http_get$(c@, "/a:b")), "GET /a:b?k=v HTTP/1.1", "params after a colon segment")
assert_eq(reqline$(http_get$(c@, "/a:b?")), "GET /a:b?&k=v HTTP/1.1", "and after an empty query")
p@ = http_client@("http://dest.test:9")
x = http_proxy(p@, "127.0.0.1", rport)
rem Through a proxy the target is the absolute url (RFC 9112 3.2.2).
assert_eq(reqline$(http_get$(p@, "/v1/items:batchGet")), "GET http://dest.test:9/v1/items:batchGet HTTP/1.1", "through a proxy")
r@ = http_client@(raw$)
x$ = raw_location$("/v1/items:batchGet")
assert_eq(reqline$(http_get$(r@, "/b/c/d;p?q")), "GET /v1/items:batchGet HTTP/1.1", "a redirect hop")

test_case("path/a generated sweep of segments and queries")
rem A: every segment as the only one, with every query: 16 * 6 = 96.
rem B: every ordered pair of segments, the query cycling: 16 * 16 = 256.
rem C: three segments, each of the sixteen in each position, "x" in the
rem    other two, the query cycling: 16 * 3 = 48.
rem D: every segment with a trailing '/': 16.
rem 96 + 256 + 48 + 16 = 416 requests, each target the text it was built
rem from.
asked = 0
wrong = 0
first$ = ""
for i = 1 to 16
  for q = 0 to 5
    p$ = "/" + seg$(i) + qry$(q)
    got$ = reqline$(http_get$(raw$ + p$))
    asked = asked + 1
    if got$ <> "GET " + p$ + " HTTP/1.1" then
      wrong = wrong + 1
      if first$ = "" then
        first$ = p$ + " -> " + got$
      endif
    endif
  next
next
for i = 1 to 16
  for j = 1 to 16
    p$ = "/" + seg$(i) + "/" + seg$(j) + qry$((i * 16 + j) mod 6)
    got$ = reqline$(http_get$(raw$ + p$))
    asked = asked + 1
    if got$ <> "GET " + p$ + " HTTP/1.1" then
      wrong = wrong + 1
      if first$ = "" then
        first$ = p$ + " -> " + got$
      endif
    endif
  next
next
for i = 1 to 16
  for k = 1 to 3
    p$ = ""
    for j = 1 to 3
      if j = k then
        p$ = p$ + "/" + seg$(i)
      else
        p$ = p$ + "/x"
      endif
    next
    p$ = p$ + qry$((i + k) mod 6)
    got$ = reqline$(http_get$(raw$ + p$))
    asked = asked + 1
    if got$ <> "GET " + p$ + " HTTP/1.1" then
      wrong = wrong + 1
      if first$ = "" then
        first$ = p$ + " -> " + got$
      endif
    endif
  next
next
for i = 1 to 16
  p$ = "/" + seg$(i) + "/"
  got$ = reqline$(http_get$(raw$ + p$))
  asked = asked + 1
  if got$ <> "GET " + p$ + " HTTP/1.1" then
    wrong = wrong + 1
    if first$ = "" then
      first$ = p$ + " -> " + got$
    endif
  endif
next
assert_eq(asked, 416, "every target was asked")
assert_eq(wrong, 0, "and each arrived as written; first wrong: " + first$)
