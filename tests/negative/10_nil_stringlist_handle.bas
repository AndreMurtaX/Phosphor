rem ---------------------------------------------------------------
rem A NIL string-list handle is refused by StrListLib with its own
rem message -- the neighbour of 09, which invents a non-nil address.
rem MUST fail.
rem
rem This file was 10_fabricated_classname until 2026-10-06, and its
rem header said it provoked classname$ on nil, "which is still an
rem error rather than an answer". It is not: classname$ answers ""
rem for any handle the registry does not know, nil included
rem (tests/suite/24_platform_std.bas pins that). What kept this file
rem red was the line below, which never named classname$ at all --
rem and the runner, which accepted ANY non-zero exit, could not tell
rem a file rejected by the rule it names from one rejected by
rem another (ledger d53). Its reason is now recorded in
rem tests/negative/manifest.txt and compared, so it is named after
rem the rule it actually tests.
rem ---------------------------------------------------------------
n = strings_count(pointer@(0))
println "must not get here: "; n
