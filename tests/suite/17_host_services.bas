rem ---------------------------------------------------------------
rem The engine asks the host for platform services, rather than
rem reaching into a windowing framework for them.
rem
rem In a lesser design processmessages/handlemessage would call into an
rem application event loop and copytext$/pastetext$ into a system
rem clipboard service -- and those imports would drag a whole GUI
rem framework into anything that wanted left$(). In Phosphor they go
rem through HostServices instead: a record of method seams on the VM
rem (wired like OnOutput/OnBreakpoint) that a host fills in and a
rem headless runner leaves empty.
rem
rem Empty is a real answer, not a failure. This runner has no event
rem loop and no clipboard, so the functions say so instead of pretending
rem or crashing -- and that is what is pinned here, because the failure
rem it guards against is an access violation on a nil method.
rem ---------------------------------------------------------------

test_case("hostservices/processmessages-answers-honestly")
rem Returns 1 where a host installed a pump, 0 where none exists.
rem This runner installs none, so the answer is 0 and the important
rem part is that asking does not fault.
r = processmessages()
assert_eq(r, 0, "no event loop here, so processmessages reports none")

test_case("hostservices/handlemessage-answers-honestly")
r = handlemessage()
assert_eq(r, 0, "and neither is there anything to wait for")

test_case("hostservices/clipboard-reports-unavailable")
rem copytext$ returns the text it stored, or "" when it could not.
rem With no host clipboard it cannot, and must not raise.
s$ = copytext$("something")
assert_eq(s$, "", "no clipboard service, so nothing was stored")

test_case("hostservices/paste-reports-unavailable")
p$ = pastetext$()
assert_eq(p$, "", "and nothing can be read back")

test_case("hostservices/the-error-is-reported-not-swallowed")
rem strerror() carries the last host-services error code. A missing clipboard is
rem an error the script can see, which is how it could offer a fallback.
s$ = copytext$("x")
e = strerror()
ok = 0
if e <> 0 then ok = 1
assert_eq(ok, 1, "the failure is visible to the script, not silent")

test_case("hostservices/string-functions-still-work")
rem The point of the extraction: everything else in the string library is
rem untouched and no longer needs a window to run.
assert_eq(ucase$("plan9"), "PLAN9", "ucase$ survives losing the GUI dependency")
assert_eq(left$("Hello", 3), "Hel", "and so does left$")
