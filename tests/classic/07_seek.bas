rem Streaming input and random access: OPEN FOR BINARY, SEEK, a live LOF, a
rem 1-based LOC, and a line that spans the read-window boundary.
f$ = path_combine$(temppath$(), "phosphor_seek_test.bin")

rem eight known bytes: 10 20 30 40 50 60 70 80
b$ = ""
for i = 1 to 8
  b$ = b$ + bytestr$(i * 10)
next
ok% = file_writealltext(f$, b$)

rem --- binary mode: read at an arbitrary position, forwards and backwards ----
open f$ for binary as #1
println "lof         "; lof(1)
println "loc at open "; loc(1)
seek #1, 5
println "loc seek 5  "; loc(1)
c$ = input$(2, #1)
println "bytes 5,6   "; byteat(c$, 1); " "; byteat(c$, 2)
println "loc after   "; loc(1)
seek #1, loc(1)
println "seek loc noop "; loc(1)
seek #1, 1
println "byte 1 again "; byteat(input$(1, #1), 1)
close #1

rem --- binary mode: overwrite one byte in place, size unchanged --------------
open f$ for binary as #1
seek #1, 3
print #1, bytestr$(199)
close #1
r$ = file_readalltext$(f$)
println "patched 3   "; byteat(r$, 3); " size "; bytelen(r$)
println "neighbours  "; byteat(r$, 2); " "; byteat(r$, 4)

rem --- binary mode: seek past the end grows the file -------------------------
open f$ for binary as #1
seek #1, lof(1) + 1
print #1, bytestr$(111)
close #1
println "grown       "; file_getsize(f$); " last "; byteat(file_readalltext$(f$), 9)
ok% = file_delete(f$)

rem --- streaming: a file well past the 64 KB read window ---------------------
g$ = path_combine$(temppath$(), "phosphor_seek_stream.txt")
open g$ for output as #2
for i = 1 to 4000
  println #2, "line "; i; " padding-padding-padding"
next
close #2
open g$ for input as #3
n% = 0
last$ = ""
while eof(3) = false
  line input #3, last$
  n% = n% + 1
wend
close #3
println "stream lines "; n%
println "last line   "; last$
ok% = file_delete(g$)

rem --- guards: a channel op must not silently do something else ---------------
rem Each of these was found by an adversarial hunt and reproduced with the shipped
rem binary. None of them errored; they quietly did the wrong thing.
g$ = path_combine$(temppath$(), "phosphor_seek_guard.txt")

rem SEEK on an APPEND channel turned append-only into overwrite and ate the log.
ok% = file_writealltext(g$, "AAAAAAAAAA")
open g$ for append as #5
caught% = 0
on error goto gseek
seek #5, 1
goto after_gseek
gseek:
caught% = 1
resume next
after_gseek:
on error goto 0
print #5, "ZZZ"
close #5
println "seek on append "; caught%; " log kept "; left$(file_readalltext$(g$), 10)

rem CLOSE with a negative number hit an internal "close everything" sentinel.
open g$ for input as #6
open g$ for input as #7
n% = 0 - 1
caught% = 0
on error goto gclose
close #n%
goto after_gclose
gclose:
caught% = 1
resume next
after_gclose:
on error goto 0
println "close #-1      "; caught%; " still open "; eof(6) = false
close #6
close #7

rem SEEK past 2 GB was clamped to 2147483647, so two positions collapsed onto one.
open g$ for binary as #8
seek #8, 5000000000
println "seek past 2GB  "; loc(8)
close #8
ok% = file_delete(g$)
