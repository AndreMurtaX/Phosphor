rem `let a, b` declares several names at once (each default-initialised); `let a = 5`
rem assigns one. The two forms do not combine: `let a, b = 5` is ambiguous -- which
rem name would take the 5? -- so it is rejected rather than guessing. MUST fail.
rem Assign one name at a time (`let a = 5 : let b = 5`) when both should hold it.
let a, b = 5
println a
