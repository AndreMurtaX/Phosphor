rem ---------------------------------------------------------------
rem PRINT USING cuts a format into fields by ONE grammar (round 3,
rem 2026-10-09; docs/decisions.md "PRINT USING format language").
rem
rem Before: a numeric field could start only at "#", "+", "$$" or "**", so
rem ".##" was a literal "." and then an INTEGER field -- 0.78 printed ". 1",
rem a different number with no mark. And the start condition took "+"
rem before "$$" or "**" while the consumer only skipped "$$"/"**" BEFORE a
rem "+": "+$$##.##" became a zero-width "+" field that printed its value as
rem an overflow ("%+5") and a second field that took the NEXT value, so
rem every later field shifted. "**$" (fill with a floating dollar) split the
rem same way, and a trailing "." or "," after a field was swallowed into it.
rem
rem THE EXPECTED LINES are tests/print_using_sweep.py using_line(), the
rem documented grammar implemented in Python from its text. Not from a run.
rem ---------------------------------------------------------------

rem --- a field with no integer positions
println using ".##"; 0.78
println using ".##"; 0.25
println using "Rate: .###"; 0.125
println using ".##"; 0.004
println using ".##"; 0.999
println using ".##"; 1.5
println using ".##"; -0.5
println using "+.##"; 0.5; -0.5
println using "[.##-]"; 0.5; -0.5
println using ".## .## .##"; 0.1; 0.2; 0.3
println using "$$.##"; 0.78
println using "**.##"; 0.78

rem --- a sign before a fill is one field
println using "+$$##.##"; 5
println using "+$$##.##"; 5; 6
println using "+$$##.##"; -5
println using "+**##.##"; 5
println using "+**##.##"; -5
println using "+**$##.##"; 5
println using "$$+##.##"; 5
println using "**+##.##"; 5
println using "<+$$##.##> <&>"; 5; "next"

rem --- asterisk fill with a floating dollar
println using "**$##.##"; 5
println using "**$#,###.##"; 1234.5
println using "**$##.##-"; -5

rem --- what is not part of a field stays text
println using "Total: ###.##."; 42.5
println using "##, ##"; 1; 2
println using "###-####"; 555; 1234
println using "+##-"; 7
println using "##.##^^^^"; 1.5
println using "+ #"; 3
