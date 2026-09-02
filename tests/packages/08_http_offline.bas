rem ---------------------------------------------------------------
rem HTTP client, the OFFLINE half: building and configuring a request
rem and encoding a string, with no network call. Mirrors oracle 32
rem (32_http_offline.bas) in Phosphor's own package style -- functional
rem equivalence, not a byte port: handle type '@' (not '#'), the getter
rem is a distinct '$' name rather than a '#' mutator, and Phosphor's
rem 1-based/0-absent instr (so a reference "instr + 1" drops the +1 and
rem an "instr = -1" becomes "instr = 0"). The runner stands a server up
rem but this file never contacts it -- the whole surface here is offline.
rem It also reads several settings BACK (user-agent/content-type/accept/
rem redirects/ssl), which the reference left write-only.
rem ---------------------------------------------------------------

test_case("http/construction")
c@ = http_client@("https://example.invalid")
assert_true(pnttonum(c@), "http_client@ answers a handle")
assert_eq(http_baseurl$(c@), "https://example.invalid", "which remembers the base url it was given")

bare@ = http_client@()
assert_true(pnttonum(bare@), "the no-argument form answers one too")
assert_eq(http_baseurl$(bare@), "", "with no base url")

http_baseurl(bare@, "https://elsewhere.invalid")
assert_eq(http_baseurl$(bare@), "https://elsewhere.invalid", "which can be set afterwards")

test_case("http/timeouts")
rem Both take milliseconds. Only the connect timeout has a getter; the
rem response timeout is exercised for reachability rather than a value.
http_timeout(c@, 5000)
assert_eq(http_timeout(c@), 5000, "http_timeout holds what it was given")
http_timeout(c@, 30000)
assert_eq(http_timeout(c@), 30000, "and takes a new value")
http_responsetimeout(c@, 15000)

test_case("http/request-headers")
assert_eq(http_headercount(c@), 0, "a new client carries no headers")

http_header(c@, "X-One", "first")
http_header(c@, "X-Two", "second")
assert_eq(http_headercount(c@), 2, "http_header adds them")
assert_eq(http_header$(c@, "X-One"), "first", "and http_header$ reads one back")
assert_eq(http_header$(c@, "X-Absent"), "", "a header that was never set reads empty")

http_header(c@, "X-One", "changed")
assert_eq(http_headercount(c@), 2, "setting an existing name replaces rather than adds")
assert_eq(http_header$(c@, "X-One"), "changed", "with the new value")

http_headerremove(c@, "X-One")
assert_eq(http_headercount(c@), 1, "http_headerremove takes one out")
assert_eq(http_header$(c@, "X-One"), "", "and it is gone")

http_headerclear(c@)
assert_eq(http_headercount(c@), 0, "http_headerclear empties them")

test_case("http/query-parameters")
http_param(c@, "page", "2")
http_param(c@, "sort", "name")
assert_eq(http_paramcount(c@), 2, "http_param stores query parameters")
assert_eq(http_param$(c@, "page"), "2", "http_param stores a query parameter")
assert_eq(http_param$(c@, "absent"), "", "and an unset one reads empty")

http_paramremove(c@, "page")
assert_eq(http_param$(c@, "page"), "", "http_paramremove takes one out")
http_paramclear(c@)
assert_eq(http_param$(c@, "sort"), "", "and http_paramclear takes the rest")
assert_eq(http_paramcount(c@), 0, "nothing is left after a clear")

test_case("http/cookies")
assert_eq(http_cookiecount(c@), 0, "a new client carries no cookies")
http_cookie(c@, "session", "abc123")
http_cookie(c@, "theme", "dark")
assert_eq(http_cookiecount(c@), 2, "http_cookie adds them")
assert_eq(http_cookie$(c@, "session"), "abc123", "http_cookie$ reads one back")

http_cookieremove(c@, "session")
assert_eq(http_cookiecount(c@), 1, "http_cookieremove takes one out")
http_cookieclear(c@)
assert_eq(http_cookiecount(c@), 0, "and http_cookieclear takes the rest")

test_case("http/authentication")
rem None of the three has a getter -- the credential is not readable
rem back by design -- so what is asserted is that each is reachable and
rem leaves no error behind.
http_clearerror()
http_basicauth(c@, "user", "secret")
assert_eq(http_error(), 0, "http_basicauth sets without complaint")
http_bearerauth(c@, "a-token")
assert_eq(http_error(), 0, "http_bearerauth too")
http_customauth(c@, "Negotiate abc")
assert_eq(http_error(), 0, "and http_customauth")
http_clearauth(c@)
assert_eq(http_error(), 0, "http_clearauth removes whichever was set")

test_case("http/proxy")
http_proxy(c@, "proxy.invalid", 8080)
assert_eq(http_error(), 0, "http_proxy takes a host and a port")
http_proxyauth(c@, "puser", "ppass")
assert_eq(http_error(), 0, "http_proxyauth takes credentials for it")
http_clearproxy(c@)
assert_eq(http_error(), 0, "and http_clearproxy removes it")

test_case("http/behaviour-flags")
http_useragent(c@, "Phosphor-Test/1.0")
http_contenttype(c@, "application/json")
http_accept(c@, "application/json")
http_followredirects(c@, 1)
http_maxredirects(c@, 3)
http_validatessl(c@, 1)
assert_eq(http_error(), 0, "the whole configuration surface is reachable without a request")
rem Phosphor reads these back, which the reference left write-only.
assert_eq(http_useragent$(c@), "Phosphor-Test/1.0", "http_useragent$ reads the agent back")
assert_eq(http_contenttype$(c@), "application/json", "http_contenttype$ reads the content type back")
assert_eq(http_accept$(c@), "application/json", "http_accept$ reads the accept header back")
assert_eq(http_maxredirects(c@), 3, "http_maxredirects reads the cap back")
assert_eq(http_followredirects(c@), 1, "http_followredirects reads the flag back")
assert_eq(http_validatessl(c@), 1, "http_validatessl reads the flag back")

test_case("http/reset")
rem reset returns the client to how it left the factory, which is what
rem makes one client reusable for unrelated requests.
http_header(c@, "X-Kept", "value")
http_cookie(c@, "c", "v")
http_reset(c@)
assert_eq(http_headercount(c@), 0, "http_reset clears the headers")
assert_eq(http_cookiecount(c@), 0, "and the cookies")

test_case("http/forms")
f@ = http_form@()
assert_true(pnttonum(f@), "http_form@ answers a handle")
assert_eq(http_formfieldcount(f@), 0, "a new form is empty")
assert_eq(http_formfilecount(f@), 0, "of both kinds")

http_formfield(f@, "name", "Alice")
http_formfield(f@, "city", "Lisbon")
assert_eq(http_formfieldcount(f@), 2, "http_formfield adds text fields")

rem The url-encoded rendering is the only way to see a form without
rem sending it, and it walks the TEXT fields only.
enc$ = http_formurlencoded$(f@)
assert_true(instr(enc$, "name=Alice"), "http_formurlencoded$ renders a field")
assert_true(instr(enc$, "&"), "and joins them with an ampersand")

test_case("http/form-files")
rem A file field needs a file that exists, so one is made under bin\ .
p$ = "bin/phosphor_http_upload.txt"
file_writealltext(p$, "payload")

http_formfile(f@, "attachment", p$)
assert_eq(http_formfilecount(f@), 1, "http_formfile adds a file field")
http_formfilenamed(f@, "renamed", p$, "other.txt")
assert_eq(http_formfilecount(f@), 2, "http_formfilenamed adds one under a chosen name")
http_formfiletype(f@, "typed", p$, "typed.txt", "text/plain")
assert_eq(http_formfilecount(f@), 3, "http_formfiletype adds one with a stated type")

rem The rendering still shows only the text fields, so a file field's
rem name is absent -- Phosphor's instr answers 0 (not -1) when missing.
assert_eq(instr(http_formurlencoded$(f@), "attachment"), 0, "the url-encoded form skips file fields")

http_formclear(f@)
assert_eq(http_formfieldcount(f@), 0, "http_formclear empties the text fields")
assert_eq(http_formfilecount(f@), 0, "and the file fields")
http_formfree(f@)
file_delete(p$)

test_case("http/encoding-helpers")
rem Four pure functions with no client and no network in them.
rem
rem A space is %20 and not '+'. '+' is form encoding and correct in a
rem form body, but these functions build URLs, where '+' is an ordinary
rem character, so the reference shows "hello%20world%20%26%20more".
assert_eq(http_urlencode$("a b"), "a%20b", "http_urlencode$ percent-encodes a space")
assert_eq(http_urlencode$("a+b"), "a%2Bb", "and a literal plus is %2B, which is why the two never collide")
assert_eq(http_urldecode$("a%20b"), "a b", "http_urldecode$ puts it back")
assert_eq(http_urldecode$("a+b"), "a b", "and still reads the form spelling, so old data keeps working")
assert_eq(http_urldecode$("a%2Bb"), "a+b", "while %2B stays a plus")
assert_eq(http_urldecode$(http_urlencode$("a=b&c")), "a=b&c", "and the pair round-trips")

assert_eq(http_htmlencode$("<b>"), "&lt;b&gt;", "http_htmlencode$ escapes markup")
assert_eq(http_htmldecode$("&lt;b&gt;"), "<b>", "http_htmldecode$ puts it back")
assert_eq(http_htmldecode$(http_htmlencode$("a & b")), "a & b", "and that pair round-trips too")

test_case("http/errors")
http_clearerror()
assert_eq(http_error(), 0, "http_clearerror clears the code")
assert_true(len(http_strerror$(0)), "http_strerror$ names a code")

test_case("http/handles")
rem The registry is what lets a fabricated handle be refused without
rem following it.
junk@ = pointer@(305419896)
http_clearerror()
n = http_headercount(junk@)
assert_eq(n, 0, "an invented client answers nothing")
assert_true(http_error(), "and says so")

test_case("http/ca bundle path")
assert_eq(http_ca_file$("/etc/ssl/certs/ca.pem"), "/etc/ssl/certs/ca.pem", "http_ca_file$ records and returns the CA bundle path")

http_free(c@)
http_free(bare@)
