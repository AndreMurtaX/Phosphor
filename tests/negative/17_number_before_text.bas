rem The kind of a `+` is decided by its first operand. A string on the left makes
rem `+` concatenation, and `"score " + 5` converts the number with str$ (see
rem tests/suite/41_syntax_string_plus_number). The reverse -- a number on the left,
rem text on the right -- is arithmetic with a text operand, which is a type
rem mismatch, not a silent concatenation. MUST fail: put the text first, or str$
rem the number, but do not let the order quietly change what `+` means.
x = 5 + "x"
println x
