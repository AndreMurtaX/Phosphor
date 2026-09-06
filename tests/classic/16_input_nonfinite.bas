rem ---------------------------------------------------------------
rem A numeric INPUT field that parses to a NON-FINITE Double must be refused
rem with a catchable error, never stored.
rem
rem TryStrToFloat answers a field like "1e999" with +Inf, and the engine's
rem finiteness gate (FiniteD, in PhosphorValue) promises the rest of the engine
rem that no TValue ever holds one -- which is what makes it safe to run with the
rem invalid-operation trap unmasked. CoerceField had no such guard on the plain
rem number branch, so `input x` stored the Inf and the next operation on it
rem (x - x, an Inf to NaN) raised EInvalidOp OUTSIDE the error path: the process
rem died with "unhandled EInvalidOp" at exit 3 and the program could not catch
rem it. In an embedded host that is the HOST's process. (2026-09-06.)
rem
rem A field is DATA, not source, so the same text arrives from a file as readily
rem as from a keyboard: both doors reach the same CoerceField and both are
rem tested here. The console fields come from 16_input_nonfinite.in.
rem ---------------------------------------------------------------

rem --- door 1: the console -----------------------------------------------
msg$ = ""
x = 7
on error goto h1
input x
println "console kept x = "; x
println "console said: "; msg$
on error goto 0
goto after1
h1:
  msg$ = errmsg$()
  resume next
after1:

rem The very operation that used to kill the process, now reached with the
rem variable the refusal left alone.
println "x - x = "; x - x

rem A negative overflow is the same refusal, and a finite field after it still
rem reads -- the guard must not swallow ordinary input.
msg2$ = ""
y = 9
on error goto h2
input y
println "console kept y = "; y
println "console said: "; msg2$
on error goto 0
goto after2
h2:
  msg2$ = errmsg$()
  resume next
after2:

input z
println "console read z = "; z

rem --- door 2: a data file (input #) --------------------------------------
f$ = path_combine$(temppath$(), "phosphor_nonfinite.txt")
open f$ for output as #1
println #1, "1e999"
println #1, "-1e999"
println #1, "6.25"
close #1

fmsg$ = ""
a = 1
b = 2
on error goto h3
open f$ for input as #2
input #2, a
println "file kept a = "; a
println "file said: "; fmsg$
input #2, b
println "file kept b = "; b
println "file said: "; fmsg$
input #2, c
println "file read c = "; c
close #2
on error goto 0
goto after3
h3:
  fmsg$ = errmsg$()
  resume next
after3:

println "deleted: "; file_delete(f$)
println "still running"
