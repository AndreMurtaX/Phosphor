rem ---------------------------------------------------------------
rem A number that came from the program is never narrowed unchecked.
rem
rem   i := Round(AsDouble(Args[1]));    // i: Integer
rem
rem did two wrong things at once. Round() of a Double outside Int64
rem range RAISES, and the assignment into a 32-bit Integer WRAPS -- so
rem an argument of 4294967297 became 1 and sailed through the bounds
rem check sitting directly beneath it.
rem
rem That idiom appeared at 131 sites. It is now one shared saturating
rem primitive (ArgI32/ArgI64 in PhosphorValue): too large clamps to the
rem limit, so the bounds check REJECTS it instead of being handed a
rem wrapped value that looks perfectly valid.
rem ---------------------------------------------------------------

test_case("bounds/a huge index is rejected, not wrapped into a valid one")
caught% = 0
d@ = dict@()
dict_set@(d@, "alpha", 1)
on error goto wrapped
k$ = dict_key$(d@, 4294967297)
goto after_wrapped
wrapped:
caught% = 1
resume next
after_wrapped:
on error goto 0
assert_eq(caught%, 1, "4294967297 truncated to 1 and returned 'alpha' before this")
assert_eq(dict_key$(d@, 1), "alpha", "and the real index still works")

test_case("bounds/mid$ with a count near the integer limit does not fault")
rem startCp + cnt wrapped negative, skipped the clamp, and indexed the codepoint
rem table out of bounds -- an access violation from an ordinary-looking call.
assert_eq(mid$("hello", 1, 2147483647), "hello", "a count past the end is just the rest")
assert_eq(mid$("hello", 2, 3), "ell", "and the ordinary case is unchanged")
assert_eq(mid$("hello", 9, 2), "", "a start past the end is empty")

test_case("bounds/left$ and right$ take an out-of-range count calmly")
assert_eq(left$("hello", 10 ^ 30), "hello", "clamped, not raised")
assert_eq(right$("hello", 10 ^ 30), "hello", "same on the other side")
assert_eq(left$("hello", 2), "he", "ordinary case")

test_case("bounds/an array whose dimensions multiply out too far is refused")
caught% = 0
on error goto toobig
a@ = dim@(9007199254740994, 2048)
goto after_big
toobig:
caught% = 1
resume next
after_big:
on error goto 0
assert_eq(caught%, 1, "the product wrapped and ubound then disagreed with the allocation")
b@ = dim@(3, 4)
arr_set@(b@, 3, 4, 7)
assert_eq(narr_get(b@, 3, 4), 7, "an ordinary array is unaffected")
assert_eq(ubound(b@, 1), 3, "and reports the size it was given")

test_case("num/rnd covers the range it was asked for")
rem The bound was narrowed to a 32-bit Integer, so rnd(3000000000) wrapped negative,
rem clamped to 1, and returned 0 every time -- forever, silently.
randomize
above% = 0
for i = 1 to 400
  if rnd(3000000000) > 2147483647 then above% = above% + 1
next
assert_true(above% > 0, "some draw lands above 2^31 when the bound is 3e9")
assert_true(rnd(10) < 10, "and a small bound still behaves")

test_case("num/a negative count is empty, not a fault")
assert_eq(space$(-5), "", "a negative width is nothing")
assert_eq(len(space$(5)), 5, "and an ordinary one is itself")
rem NOT tested here: space$(10 ^ 30). It no longer raises, but the saturated width
rem then asks for a 2 GB string, and a test that allocates 2 GB to prove a bounds
rem fix is a worse test than none. The clamping is covered by left$/right$ above.

test_case("str/hex$, bin$ and oct$ carry a full Int64")
rem Two defects met here. The narrowing sweep above briefly gave these three a
rem 32-bit argument -- they take a VALUE, not an index -- and ToRadix negated its
rem input to take the magnitude, which cannot represent -2^63, so hex$ of the
rem smallest Int64 returned a bare "-": a minus sign, no digits, reported as success.
lo% = -9223372036854775807
lo% = lo% - 1
assert_eq(hex$(lo%), "-8000000000000000", "sixteen digits, not eight and not none")
assert_eq(len(bin$(lo%)), 65, "a sign and sixty-four bits")
assert_eq(hex$(9223372036854775807), "7FFFFFFFFFFFFFFF", "and the other end of the range")
assert_eq(hex$(1099511627776), "10000000000", "a value well past 32 bits")
assert_eq(hex$(255), "FF", "ordinary values are unchanged")
assert_eq(bin$(255), "11111111", "in every base")
assert_eq(oct$(255), "377", "including octal")
assert_eq(hex$(0), "0", "and zero is still zero")
