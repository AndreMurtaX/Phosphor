rem A pointer the program invented must be rejected by ArrayLib with a clear
rem message, not followed. Before the HandleRegistry change this reached
rem "TObject(p) is TBasArrayBase", which dereferences the address: recoverable
rem on Windows, a hard crash on Android and Linux.
rem This file MUST fail, and the reported detail must be the library's own
rem message rather than an access violation.
junk@ = pointer@(305419896)
n = ndims(junk@)
println "must not get here: "; n
