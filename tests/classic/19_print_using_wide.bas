rem PRINT USING past 1e255 and past 18 decimals -- the readable half of
rem tests/print_using_sweep.py, which crosses the whole range generatively.
rem
rem Until 2026-10-09 a Double was laid out by FPC's FloatToStrF(ffFixed, 18),
rem which answers in EXPONENT form once its text passes 255 characters: the
rem formatter split "1.0E+300" at its '.' and printed 1 for 1e300 in a "#"
rem field -- a wrong number with no overflow mark -- and FloatToStrF caps the
rem decimals at 18, so a field with 25 '#' after the point got 18.
rem
rem THE RULE (docs/language-reference.md, PRINT USING): the digits are the
rem value's own up to its 17th significant digit, every position past that
rem prints 0, and the value is rounded ONCE, half away from zero, at the 17th
rem significant digit or the field's last decimal, whichever comes first. A
rem field too narrow takes a leading '%' and then every digit. Each expected
rem line was computed from the EXACT binary value with Python's decimal module
rem (tests/print_using_sweep.py#reference), not read off a run.
rem
rem 1e300 is 1.00000000000000005250476...e300 exactly: 17 significant digits
rem round the 18th (a 5) up, so the field shows 10000000000000001 and zeros.
println using "#"; 1e300
println using "#"; -1e300
println using "###.##"; 1e300
rem The control: 1e255 printed this way before the change, and still does.
println using "#"; 1e255
println using "#"; 1e256
rem The largest Double, all 309 integer digits.
println using "#"; 1.7976931348623157e308
rem Grouping goes on through the zeros.
println using "#,###"; 1e20
rem Twenty-five decimals are twenty-five, not eighteen. 0.1 is
rem 0.1000000000000000055511151231257827... exactly: 17 significant digits
rem end in ...0001, and every place after them is 0.
println using "#.#########################"; 0.1
println using "#.############################################################"; 1 / 3
rem Rounding is of the exact value. 2.675 is 2.67499999999999982236... and
rem 0.015 is 0.01499999999999999944..., so both round DOWN at two decimals;
rem 0.125 is exact, a true tie, and goes away from zero.
println using "##.##"; 2.675
println using "#.##"; 0.015
println using "#.##"; 0.125
println using "#.##"; -0.125
rem The smallest subnormal, 4.9406564584124654e-324: below half of the last
rem place of a 30-decimal field it is 0; in a 340-decimal field its own 17
rem significant digits appear after 323 zeros, and zeros follow them.
println using "#.##############################"; 5e-324
println using "#.####################################################################################################################################################################################################################################################################################################################################################"; 5e-324
