rem The suffix on a name IS its type, and a `const` declaration is a binding like
rem any other -- so the literal has to fit the name. This program used to RUN and
rem print 5: a `$` name holding an Int64, substituted verbatim wherever it was
rem used. Nothing complained here, and the first line that did arithmetic with it
rem got "cannot add text to a number" -- an operator's message, about a line the
rem author had written as a declaration, with no suffix left in the value for
rem anything downstream to recover the intent from. `const i% = 1.5`, `const b? =
rem 7` and `const h@ = 3` were accepted the same way; the last two name kinds no
rem literal can ever produce.
rem MUST fail, at the DECLARATION -- line 13, not wherever the name is used.
rem Write the literal the name asks for. tests/suite/43_syntax_const holds the
rem half that still compiles, including the coercion `const i% = 1.5` now takes.
const s$ = 5
println s$
