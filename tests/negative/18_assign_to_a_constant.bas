rem A name declared `const` is a fixed value substituted where it is used, not a
rem variable slot. Writing to it later is a bug the language catches at compile
rem time: a constant and a same-named variable can never quietly coexist (once
rem they did -- the const held its value and a shadow variable took the write).
rem MUST fail. tests/suite/43_syntax_const holds the meaning; this holds the error.
const MAXLIVES = 3
MAXLIVES = 4
println MAXLIVES
