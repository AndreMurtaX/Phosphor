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
