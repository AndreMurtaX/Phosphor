rem The same program must produce the same BYTES on Windows and Linux. That is the
rem project's central promise, and seven confirmed defects broke it the same way: a
rem library borrowed something from the MACHINE -- its line ending, its collation
rem order, its month names, its decimal separator, its OS error text, its directory
rem enumeration order -- and handed the difference to the program.
rem
rem This file is a golden, so it IS the parity check: the byte-exact comparison
rem runs on both platforms and any divergence fails the suite rather than being
rem noticed later.

rem --- month and day names come from the language, not the locale -------------
rem formatdatetime$("mmmm") answered "junho" here, "June" on an en-US box and "Jun"
rem under a C locale, for the same date: the ISO settings pinned the separators and
rem patterns but left the NAME ARRAYS taken from the machine.
d = strtodate("2024-06-15")
println "mmm    "; formatdatetime$("mmm", d)
println "mmmm   "; formatdatetime$("mmmm", d)
println "ddd    "; formatdatetime$("ddd", d)
println "dddd   "; formatdatetime$("dddd", d)
println "iso    "; datetostr$(d)

rem --- a string list ends its lines the way the engine does --------------------
rem The default was sLineBreak, so the same two-item list rendered as 10 bytes on
rem Windows and 8 on Linux.
l@ = strings@()
strings_add(l@, "one")
strings_add(l@, "two")
println "text   "; len(strings_text$(l@))
println "break  "; len(strings_linebreak$(l@))
rem and a program that WANTS CRLF can still say so
strings_linebreak(l@, chr$(13) + chr$(10))
println "crlf   "; len(strings_text$(l@))

rem --- a directory lists in one order everywhere -------------------------------
rem TStringList.Sort compares with the machine's collation, which orders "a-b.txt"
rem and "ab.txt" one way under a Windows locale and the other under a C locale.
dd$ = path_combine$(temppath$(), "phosphor_parity")
ok% = dir_create(dd$)
ok% = file_writealltext(path_combine$(dd$, "a-b.txt"), "1")
ok% = file_writealltext(path_combine$(dd$, "ab.txt"), "2")
ok% = file_writealltext(path_combine$(dd$, "B.txt"), "3")
ok% = file_writealltext(path_combine$(dd$, "e.txt"), "4")
n@ = strings@()
strings_text(n@, dir_getfiles$(dd$))
for i = 1 to strings_count(n@)
  println "  "; path_getfilename$(strings_strings$(n@, i))
next

rem --- the I/O error text is the language's, in UTF-8 --------------------------
rem SysErrorMessage returns the OS message in the machine's language and ANSI code
rem page: on a pt-BR Windows it carried a bare 0xE3 byte, which is not UTF-8.
x$ = file_readalltext$(path_combine$(dd$, "definitely_missing.txt"))
println "ioerr  "; iostrerror$()
println "bytes  "; bytelen(iostrerror$()) = len(iostrerror$())

ok% = file_delete(path_combine$(dd$, "a-b.txt"))
ok% = file_delete(path_combine$(dd$, "ab.txt"))
ok% = file_delete(path_combine$(dd$, "B.txt"))
ok% = file_delete(path_combine$(dd$, "e.txt"))
ok% = dir_delete(dd$)

rem --- a file open for reading can still be opened for writing -----------------
rem fmCreate alone takes an exclusive share on Windows and nothing at all on Linux,
rem so this errored on one platform and worked on the other.
sf$ = path_combine$(temppath$(), "phosphor_share.txt")
ok% = file_writealltext(sf$, "content")
open sf$ for input as #1
shared% = 1
on error goto noshare
open sf$ for output as #4
goto after_share
noshare:
shared% = 0
resume next
after_share:
on error goto 0
println "share  "; shared%
close #1
close #4
ok% = file_delete(sf$)
