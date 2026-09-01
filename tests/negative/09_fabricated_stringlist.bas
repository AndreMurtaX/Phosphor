rem ---------------------------------------------------------------
rem A pointer the program invented must be refused by StrListLib with
rem the library's own message, not followed. MUST fail.
rem
rem Until 2026-08-20 it was followed. ValidateStringList tested
rem Assigned and then cast, so strings_count on an invented number
rem read from that address: an access violation on Windows, and on
rem Android and Linux not something the process survives. 65 of this
rem library's signatures take a pointer and every one was reachable
rem that way -- it had been missed by the HandleRegistry conversion
rem of item 3.4, and was found by a coverage test written for other
rem reasons.
rem
rem The detail this file reports must be StrListLib's own wording.
rem ---------------------------------------------------------------
junk@ = pointer@(305419896)
n = strings_count(junk@)
println "must not get here: "; n
