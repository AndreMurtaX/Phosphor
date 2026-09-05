rem ---------------------------------------------------------------
rem Documentation examples, run rather than read (Phosphor's oracle 16).
rem
rem Plan9Basic's 16_doc_examples exists because a documented example --
rem string$(3, "ab") claimed to return "ababab" -- did not even compile.
rem The lesson: every self-contained `expr -> value` claim the docs make
rem must be typed back into the interpreter and checked, so a page can
rem never quietly lie about what a function returns.
rem
rem This is the Phosphor equivalent, and it is NOT a port. Two things
rem differ from Plan9Basic's file:
rem
rem   1. Phosphor's own docs make FEW self-contained value claims -- the
rem      genuine ones are the arithmetic rules in docs/decisions.md and
rem      docs/roadmap.md (7/2 -> 3.5, 7\2 -> 3, 10/4 -> 2.5, 3+4 stays
rem      int, 2^0.5 is meaningful, sqr is square root). Those are typed
rem      back verbatim below, each citing its page. All of them hold:
rem      combing every docs/*.md turned up no page that lies, so there
rem      was no doc to fix this round.
rem
rem   2. The string/number built-in examples are CURATED to cover the
rem      same ground Plan9Basic's 16 does, over the functions Phosphor
rem      actually ships (docs/roadmap.md's StrLib/NumLib inventory), with
rem      every value confirmed against Phosphor's REAL output by running
rem      it -- never assumed from Plan9Basic's value. Where Phosphor is
rem      base-1 the value diverges from Plan9Basic's base-0 one, and the
rem      divergence is the point: an assertion of the base-1 answer would
rem      HARD-fail if the function were base-0 (see mid$ and instr).
rem
rem The origin bug, made right: Plan9Basic documented string$(3,"ab") as
rem "ababab" and it did not compile. In Phosphor string$ repeats a
rem CHARACTER BY CODE (string$(3, 65) -> "AAA"); the string-repeat the
rem broken doc actually wanted is mulstring$("ab", 3) -> "ababab". Both
rem are asserted below, so this file pins the exact shape that tripped
rem the reference.
rem ---------------------------------------------------------------

test_case("docs/decisions.md-arithmetic")
rem Each line here is a value docs/decisions.md or docs/roadmap.md states
rem outright, typed back and checked against the running interpreter.
assert_eq(2 + 3, 5, "decisions.md line 126: assert_eq(2+3,5)")
assert_eq(3 + 4, 7, "roadmap.md line 69: 3+4 stays int")
assert_eq(7 / 2, 3.5, "decisions.md line 42: 7/2 is 3.5 (slash is real division)")
assert_eq(10 / 4, 2.5, "roadmap.md line 69/227: 10/4 is double 2.5")
assert_eq(7 \ 2, 3, "decisions.md line 44: 7\\2 is 3 (backslash is integer division)")
assert_near(2 ^ 0.5, 1.4142135623730951, 0.0000000001, "decisions.md line 45: 2^0.5 is meaningful (always double)")

test_case("docs/decisions.md-dispatch")
rem decisions.md lines 126-127 state these as DISPATCH claims: 2+3 widens
rem to assert_eq:nn, while 7\2 stays an int% and binds to assert_int:%%
rem exactly. A passing assert_int(7\2,3) IS the proof it stayed int% --
rem had 7\2 been a double, no %% overload would match and the file would
rem fail to run at all.
rem decisions.md line 127: assert_int(7\2,3) dispatches to %% exactly.
assert_int(7 \ 2, 3)

test_case("docs/curated/number-builtins")
rem docs/roadmap.md line 158 lists NumLib; docs/decisions.md line 93 says
rem sqr is square root. Values confirmed against Phosphor's real output.
assert_eq(sqr(9), 3, "decisions.md line 93: sqr() is square root")
assert_eq(abs(-7), 7, "abs of a negative")
assert_eq(sgn(-5), -1, "sgn of a negative")
assert_eq(min(3, 8), 3, "min of two numbers")
assert_eq(max(3, 8), 8, "max of two numbers")
assert_eq(round(2.5), 2, "round is banker's rounding: 2.5 rounds to even 2")
assert_eq(round(3.5), 4, "and 3.5 rounds to even 4")
assert_eq(fix(3.9), 3, "fix truncates toward zero")
assert_eq(cint(2.5), 2, "cint rounds to nearest, half to even")

test_case("docs/curated/string-builtins")
rem docs/roadmap.md lines 161-164 list StrLib. Phosphor is base-1 and
rem UTF-8; values confirmed by running, not copied from Plan9Basic.
assert_eq(len("Hello"), 5, "len counts characters")
assert_eq(left$("Hello", 3), "Hel", "left$ takes the first n")
assert_eq(right$("Hello", 2), "lo", "right$ takes the last n")
assert_eq(mid$("Hello", 1, 3), "Hel", "mid$ is base-1: start 1, length 3 (Plan9Basic base-0 gave 'ell')")
assert_eq(mid$("Hello", 2), "ello", "mid$ two-arg runs to the end")
assert_eq(ucase$("Hello"), "HELLO", "ucase$ upcases")
assert_eq(lcase$("Hello"), "hello", "lcase$ downcases")
assert_eq(trim$("  Hi  "), "Hi", "trim$ strips both ends")
assert_eq(str$(42), "42", "str$ is the locale-invariant number-to-string (alias of stri$)")
assert_eq(val("42"), 42, "val parses a number")
assert_eq(chr$(65), "A", "chr$ of a code")
assert_eq(asc("A"), 65, "asc of a character")
assert_eq(space$(5), "     ", "space$ makes n blanks")
assert_eq(string$(3, 65), "AAA", "string$ repeats a CHARACTER BY CODE (nn signature)")
assert_eq(mulstring$("ab", 3), "ababab", "mulstring$ repeats a STRING -- the 'ababab' the broken reference doc wanted")
assert_eq(hex$(255), "FF", "hex$ of 255")
assert_eq(bin$(10), "1010", "bin$ of 10")
assert_eq(instr("Hello", "ll"), 3, "instr is 1-based: 'll' starts at position 3 (Plan9Basic base-0 gave 2)")
assert_eq(instr("Hello", "zz"), 0, "instr returns 0 when absent")

test_case("docs/curated/byte-buffer")
rem docs/language-reference.md, "A buffer, when you need to write bytes" makes two
rem self-contained value claims. Both are typed back here rather than trusted, which
rem is the entire reason this file exists: a documented example that does not run is
rem the defect Plan9Basic's own 16 was written to catch.
db@ = buffer_new@(3)
x = buffer_set(db@, 2, 128)
dp$ = path_combine$(temppath$(), "phosphor_doc_bytes.bin")
ok = file_writeallbytes(dp$, db@)
dr@ = file_readallbytes@(dp$)
assert_eq(buffer_len(dr@), 3, "the page says '3 bytes'")
assert_eq(buffer_get(dr@, 2), 128, "and 'second is 128'")
ok = file_delete(dp$)
dh@ = buffer_new@(4)
x = buffer_setint(dh@, 1, 4, 305419896, true)
assert_eq(buffer_getint(dh@, 1, 4, true), 305419896, "and the big-endian round trip prints 305419896")
