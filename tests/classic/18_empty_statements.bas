rem ---------------------------------------------------------------
rem Empty statements (ledger n14), and `else` ending a statement in a
rem one-line if (ledger n27).
rem
rem n14: a ":" where a statement may begin is an empty statement, as in
rem classic BASIC -- "10 : print", "x = 1 : : y = 2", "lbl: : stmt", a
rem line that opens with ":" or ends with two. Every one of them failed
rem to compile, at program level, inside a block and inside a one-line
rem if alike, because the three loops that sequence statements each
rem expected a statement after every ":".
rem
rem n27: inside a one-line if, `else` ends the THEN branch's last
rem statement. A statement whose operand is optional -- a bare print or
rem println, print with a trailing separator, print using, print #n,
rem close, return -- took `else` for its operand and failed. Each one is
rem run with the condition both true and false below, so both arms of
rem every if execute, and the bytes they print are compared exactly.
rem
rem 18_empty_statements.expected was written from the rules, not from a
rem run: println adds one line break, print none, ";" nothing, "," a
rem tab; "##" right-aligns a number in two columns and "###" in three;
rem a format with no field is copied as it stands; a bare return in a
rem numeric function answers 0.
rem ---------------------------------------------------------------
x = 1 : : y = 2
println str$(x + y)
10 : println "numeric label"
20 :
here: : println "named label"
: println "leading colon"
println "trailing" : :
n = 0
while n < 2
  n = n + 1 : : println str$(n)
  :
wend
if 1 = 1 then : println "then after colon" : : println "twice"
if 1 = 2 then println "no" : : println "no" else : : println "else after colons"
if 1 = 2 then println "no" else println "no colon" : :

rem n27 -- each line runs once per arm
for i = 1 to 2
  if i = 1 then println else println "arm two"
next
for i = 1 to 2
  if i = 1 then print else print "B";
next
println "|"
for i = 1 to 2
  if i = 1 then print "a"; else print "b",
next
println "|"
for i = 1 to 2
  if i = 1 then print using "##"; i; else print using "###"; i
next
println "|"
for i = 1 to 2
  if i = 1 then print using "x"; else print using "y";
next
println "|"

function f(n)
  if n = 1 then return else return n * 10
endfunction
println str$(f(1)) + " " + str$(f(2))

f$ = path_combine$(temppath$(), "phosphor_classic_n27.txt")
open f$ for output as #1
for i = 1 to 2
  if i = 1 then print #1, "p"; else print #1, "q",
next
if 1 = 1 then close else println "no"
open f$ for input as #1
line input #1, s$
if 1 = 2 then println "no" else close
println s$ + "|"
