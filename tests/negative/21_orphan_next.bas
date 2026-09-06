rem A `next` with no `for` used to be a SILENT NO-OP. A lone identifier compiles
rem to a variable read and a discard, so a typo that deleted the `for` line left a
rem program that still ran -- once, with the loop gone -- and said nothing.
println "this line runs"
next
