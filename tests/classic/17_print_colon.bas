rem ---------------------------------------------------------------
rem print and println end at a ":" too (ledger d65).
rem
rem ":" separates statements on one line, and eight other statement
rem parsers stop at it. print/println did not: where an item could come
rem next -- after the bare keyword, or after a trailing ";" or "," -- they
rem stopped only at the end of the line, so "println : x = 1" read ":" as
rem the start of an expression and failed to compile.
rem
rem The output is compared BYTE FOR BYTE with 17_print_colon.expected,
rem which was written from the rules, not from a run: println adds one
rem line break and print none; ";" adds nothing between items and ","
rem adds a tab; a trailing separator adds nothing after the last item.
rem A fix that made "println :" compile but printed two breaks, or none,
rem fails here and would pass a test that only asked whether it compiled.
rem ---------------------------------------------------------------
println : println "after a bare println"
print : println "after a bare print"
print "a"; : println "b"
print "c", : println "d"
println "e"; : println "f"
x = 1 : println : x = 2
println str$(x)
