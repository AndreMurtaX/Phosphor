rem The streamed channel window is 64 KB. Everything that crosses that edge has to
rem behave as though it were not there -- and two things did not, both found by an
rem adversarial hunt and both silent.
rem
rem These write files a little larger than the window on purpose; they live in the
rem system temp directory and are deleted at the end.

d$ = temppath$()

rem --- a FIELD longer than the window --------------------------------------
rem The read-ahead looked for any terminator at or after the cursor, and the blanks
rem BEFORE the field are terminators: the space after "a," satisfied it at once, so
rem the loop stopped pulling and INPUT # returned 65533 bytes of a 70000-byte field.
rem No error, and the next INPUT # started in the middle of the value.
f$ = path_combine$(d$, "phosphor_win_field.txt")
big$ = string$(70000, 66)
ok% = file_writealltext(f$, "a, " + big$ + chr$(10))
open f$ for input as #1
input #1, x$, y$
close #1
println "first field  "; x$
println "second field "; len(y$)
println "intact       "; y$ = big$

rem --- a QUOTED field longer than the window --------------------------------
rem The old scan did not model a quoted field at all: its end is the closing quote,
rem not the first blank inside it.
q$ = path_combine$(d$, "phosphor_win_quoted.txt")
inner$ = string$(70000, 67)
ok% = file_writealltext(q$, chr$(34) + "lead " + inner$ + chr$(34) + chr$(10))
open q$ for input as #2
input #2, qq$
close #2
println "quoted len   "; len(qq$)
println "quoted head  "; left$(qq$, 5)

rem --- a CRLF landing exactly on the window edge -----------------------------
rem The step over the pair stopped after the CR when the LF had not been read yet,
rem so the LF began the next read and a two-line file came back as three.
g$ = path_combine$(d$, "phosphor_win_crlf.txt")
ok% = file_writealltext(g$, string$(65535, 65) + chr$(13) + chr$(10) + "B" + chr$(13) + chr$(10))
open g$ for input as #3
n% = 0
while eof(3) = false
  line input #3, l$
  n% = n% + 1
  println "line "; n%; " len "; len(l$)
wend
close #3
println "line count   "; n%

ok% = file_delete(f$)
ok% = file_delete(q$)
ok% = file_delete(g$)
