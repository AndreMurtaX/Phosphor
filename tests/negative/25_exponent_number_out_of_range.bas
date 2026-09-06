rem A number the machine cannot hold, written in exponent form.
rem
rem The same value spelled with plain digits -- `1` followed by 400 zeros -- was
rem already rejected here, because FPC's TryStrToFloat returns False on it. Write
rem it `1e999` and TryStrToFloat returns TRUE and hands back +Inf, so the literal
rem sailed through the lexer, into the constant pool, and opPushConst put a
rem non-finite Double into a variable.
rem
rem That falsifies the invariant FiniteD states in PhosphorValue -- "no TValue
rem ever holds a non-finite Double" -- which is the SOLE reason it is safe to run
rem with the invalid-operation trap unmasked. The next operation that turned the
rem Inf into a NaN (x - x, x / x, x * 0, x mod 2) raised EInvalidOp before
rem FiniteD could see it, and the process DIED at exit 3 -- with `on error goto`
rem already in force, and taking any embedding host down with it. A library fault
rem is a catchable error value, never a process death (docs/decisions.md).
rem
rem THIS FILE DELIBERATELY DOES NOTHING WITH x. Before the fix the assignment on
rem its own compiled and ran clean and exited 0, which is what makes this a real
rem test: a file that also did the arithmetic would have been "rejected" by the
rem crash, and gone green while proving nothing.
x = 1e999
