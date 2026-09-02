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
