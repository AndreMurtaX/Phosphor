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
rem ---------------------------------------------------------------------------
rem THE STRING FIELDS COUNT CHARACTERS, and until this section existed nothing
rem here said so: every case above uses an ASCII VALUE, and on ASCII a byte-based
rem field is indistinguishable from a character-based one. '!' took Copy(sv,1,1),
rem a one-BYTE slice, so it wrote the LEAD BYTE of a two-byte character to stdout
rem -- 5B C3 5D, a lone 0xC3 between the brackets, which is not valid UTF-8 and
rem which nothing reading this file's bytes can decode. A \...\ field truncated
rem the same way and padded by bytes, so a field holding an accented word came
rem out a column NARROWER than the same field holding an ASCII one.
rem
rem The widths are the point: the two "caf" lines below must be the same number
rem of columns as each other.
println using "[!]"; chr$(233) + "cole"
println using "[\\  \\]"; "caf" + chr$(233)
println using "[\\    \\]"; "caf" + chr$(233)
println using "[\\    \\]"; "cafe"
rem an astral character is one column too, not four
println using "[!]"; chr$(128512)
println using "[\\  \\]"; chr$(128512) + chr$(128512) + chr$(128512)
rem '&' takes the whole string whatever it holds
println using "[&]"; chr$(26085) + "x"
rem rtab$ has always padded to CHARACTERS; the field has to agree with it
println "[" + rtab$("caf" + chr$(233), 6) + "]"
