rem ---------------------------------------------------------------
rem The host-services seam, from the side that HAS a host.
rem
rem tests/suite/17_host_services pins the other side: run headless,
rem under phosphortest, processmessages() answers 0 and the clipboard
rem answers "" with strerror() non-zero -- the absent-service answers.
rem Both halves are needed, and only this one proves a host can fill
rem the seam at all. It could not be written before, because no host
rem in the tree assigned HostServices: phosphorgui, the one program
rem written to provide an event loop and a clipboard, left all four
rem methods nil, so processmessages() answered 0 inside a running GUI.
rem scripts/check-seams.py is what now refuses to let that recur.
rem
rem A NOTE ON handlemessage(). It WAITS for a message. In this
rem unattended runner nothing will ever arrive, so a real wait is a
rem hang, not a test -- the runner therefore reports that it cannot
rem handle one, which is exactly what 0 means and is true of it. The
rem interactive host installs the real, blocking version.
rem ---------------------------------------------------------------

test_case("hostservices/the pump is really there")

rem 1, not 0: a host pumped. Under phosphortest this same call is 0.
assert_eq(processmessages(), 1, "processmessages reports that a host pumped")
assert_eq(processmessages(), 1, "and again -- it is not a one-shot")

assert_eq(handlemessage(), 0, "handlemessage reports it cannot wait in an unattended runner")

test_case("hostservices/the clipboard round-trips")

rem The clipboard is the machine's, not the suite's, so what was on it
rem is put back at the end. A test that quietly eats what you copied is
rem a bad neighbour.
was$ = pastetext$()

s$ = copytext$("phosphor clipboard probe")
assert_eq(s$, "phosphor clipboard probe", "copytext$ answers the text it stored")
assert_eq(strerror(), 0, "and reports no error, because there IS a clipboard here")

assert_eq(pastetext$(), "phosphor clipboard probe", "pastetext$ reads back what was put there")
assert_eq(strerror(), 0, "still no error")

rem A round trip through multi-byte characters, because the clipboard crosses
rem a UTF-16 boundary on Windows and a UTF-8 one on gtk. chr$ takes a CODEPOINT,
rem not a byte -- chr$(233) is one character and two bytes -- so len and bytelen
rem disagree here, which is exactly the case worth carrying across the boundary.
u$ = "caf" + chr$(233) + " -- " + chr$(8364)
assert_eq(len(u$), 9, "nine characters")
assert_eq(bytelen(u$), 12, "and twelve bytes")
copytext$(u$)
assert_eq(pastetext$(), u$, "and every byte survives the platform's own encoding")
assert_eq(strerror(), 0, "with no error")

rem An empty string is a value, not an absence: storing it must not read
rem back as "the clipboard is missing".
copytext$("")
assert_eq(pastetext$(), "", "an empty clipboard reads back empty")
assert_eq(strerror(), 0, "which is a stored value, not a missing service")

copytext$(was$)
