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
