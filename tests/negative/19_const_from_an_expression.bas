rem A `const` value is a single literal -- a number or a piece of text -- because
rem it is substituted verbatim where the name is used, not computed. `const N = 2 + 3`
rem asks for an expression, which const does not evaluate, so it is rejected for that
rem reason rather than a bare "expected end of line". MUST fail: write the literal
rem (`const N = 5`), or use an ordinary variable when the value must be computed.
const N = 2 + 3
println N
