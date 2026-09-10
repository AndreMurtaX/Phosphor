rem Classic # file I/O: OPEN/PRINT#/CLOSE, then OPEN input/LINE INPUT#/INPUT#/EOF.
f$ = path_combine$(temppath$(), "phosphor_classic_io.txt")

open f$ for output as #1
println #1, "alpha"
println #1, "beta"
print #1, "x"; "y"; "z"
println #1, ""
println #1, 42; ","; "gamma"
close #1

rem read every line back with LINE INPUT # and count with EOF
open f$ for input as #2
n% = 0
while not eof(2)
  line input #2, s$
  n% = n% + 1
  println n%; ": "; s$
wend
println "lines: "; n%
println "lof: "; lof(2)
close #2

rem read a comma record with INPUT # (number, then string field)
open f$ for input as #3
line input #3, junk$
line input #3, junk$
line input #3, junk$
input #3, num%, word$
println "record: "; num%; "/"; word$
close #3

rem APPEND adds without truncating
open f$ for append as #4
println #4, "delta"
close #4
open f$ for input as #5
tot% = 0
while not eof(5)
  line input #5, s$
  tot% = tot% + 1
wend
println "after append: "; tot%
close #5

rem INPUT$ reads a fixed number of bytes from a file
open f$ for input as #6
head$ = input$(5, #6)
println "head: ["; head$; "]"
close #6

ok% = file_delete(f$)
println "deleted: "; ok%

rem The #channel of a PRINT # is held in a temporary across every item printed,
rem and an item is an arbitrary expression -- a recursive one re-enters the same
rem statement with a different channel. While that temporary was a program-wide
rem global rather than the activation's, the inner call overwrote it and the
rem OUTER statement's remaining items went to the inner channel: two open files
rem is what makes it visible. Below, walk(2) prints to #8 and its inner walk(1)
rem to #7, so the outer's closing ">" landed in the #7 file and #8 never got one.
g7$ = path_combine$(temppath$(), "phosphor_classic_ch7.txt")
g8$ = path_combine$(temppath$(), "phosphor_classic_ch8.txt")
open g7$ for output as #7
open g8$ for output as #8
depth% = walk(2)
close #7
close #8
println "ch7: ["; file_readalltext$(g7$); "]"
println "ch8: ["; file_readalltext$(g8$); "]"
ok7% = file_delete(g7$)
ok8% = file_delete(g8$)
println "cleaned: "; ok7% + ok8%

function walk(n) local c
  if n <= 0 then return 0
  c = 6 + n
  print #c, "<"; walk(n - 1); ">"
  return n
endfunction
