rem PRINT USING -- classic formatted output.
rem Numeric fields: digit positions, decimals, grouping, signs, fills, overflow.
println using "###.##"; 3.14159
println using "###.##"; 3
println using "#,###.##"; 1234567.5
println using "$$###.##"; 42.5
println using "**#.#"; 7.25
println using "+#.##"; 3.5
println using "#.##-"; 0 - 4.2
rem String fields: & whole, ! first char, \  \ fixed width (escaped backslashes).
println using "Item & is $#.##"; "pen"; 2.5
println using "!"; "hello"
println using "[\\  \\]"; "world"
rem The format repeats while values remain.
println using "<#> "; 1; 2; 3
rem PRINT (no newline) then a trailing marker.
print using "###"; 5
println "|end"
rem A format string carries BYTES, not just ASCII. Each character of the format was
rem copied through by Char concatenation, so an accented format printed "?? 7 ??"
rem -- four bytes destroyed -- while every golden here stayed green because none of
rem them held a byte >= 128. (scripts/check-codepage.py now enforces the rule.)
f$ = chr$(225) + " ## " + chr$(233)
println using f$; 7
println "fmt bytes "; bytelen(f$)
rem The literal text between fields keeps its bytes too.
println using "caf" + chr$(233) + ": ###"; 42
