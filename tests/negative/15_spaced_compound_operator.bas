rem A compound-assignment operator is a single token: `+=`, not `+` then `=`.
rem Writing the two apart (`x + = 1`) is not a spaced-out `+=` -- it is `x + ...`
rem with a stray `=` that cannot begin a value, so the expression is rejected.
rem MUST fail: the space is meaningful, and the language does not paper over it.
x = 0
x + = 1
println x
