rem ---------------------------------------------------------------
rem A HUGE COUNT IS REFUSED AT EVERY POSITION, NOT ONLY AT POSITION 1.
rem
rem CheckRange, shared by every positional buffer operation, tested
rem `pos + count - 1 > len`. Each operand was bounded on its own and the
rem SUM was not, so a count saturated to the largest Int64 -- what
rem ArgI64 makes of 9223372036854775807 -- at a position of 2 or more
rem overflowed the sum to a negative number and PASSED. Measured before
rem the repair, on an 8-byte buffer at exit 0: buffer_fillrange answered
rem 9223372036854775807 bytes "filled", buffer_slice$ answered "" where
rem it owed an error. Position 1 was refused correctly, which is exactly
rem why a sweep that only tried position 1 saw nothing (ledger n1).
rem
rem Every case asks for the refusal 57_buffer.bas already pins for an
rem ordinary run-off -- "runs past the end" -- and for the buffer to be
rem unharmed. The last case keeps the boundary honest: a count that
rem fits exactly is still accepted.
rem ---------------------------------------------------------------

b@ = buffer_fromstr@("abcdefgh")
big = 9223372036854775807

test_case("range/buffer_fillrange refuses a huge count at position 2")
caught% = 0
msg$ = ""
on error goto fr
z% = buffer_fillrange(b@, 2, big, 65)
goto after_fr
fr:
caught% = 1
msg$ = errmsg$()
resume next
after_fr:
on error goto 0
assert_eq(caught%, 1, "the overflowing count is refused, not reported as filled")
assert_true(instr(msg$, "runs past the end"), "with the run-off message")
assert_eq(buffer_tostr$(b@), "abcdefgh", "and the buffer is unharmed")

test_case("range/buffer_slice$ refuses a huge count at position 3")
caught% = 0
msg$ = ""
on error goto sl
z$ = buffer_slice$(b@, 3, big)
goto after_sl
sl:
caught% = 1
msg$ = errmsg$()
resume next
after_sl:
on error goto 0
assert_eq(caught%, 1, "the overflowing count is refused, not answered with an empty string")
assert_true(instr(msg$, "runs past the end"), "with the run-off message")

test_case("range/buffer_copy refuses a huge count with both positions past 1")
rem BOTH sides at position 2 or more. A first draft put one side at 1, and that
rem side's check refused correctly -- so the case passed against the broken
rem build and measured nothing. Only when both sums can overflow does the copy
rem reach the defect.
d@ = buffer_new@(8)
caught% = 0
on error goto cs
z% = buffer_copy(d@, 2, b@, 3, big)
goto after_cs
cs:
caught% = 1
resume next
after_cs:
on error goto 0
assert_eq(caught%, 1, "a huge count from source 3 into destination 2 is refused")
assert_eq(buffer_tostr$(b@), "abcdefgh", "the source is unharmed")

test_case("range/the last position and a count that fits exactly still work")
assert_eq(buffer_fillrange(b@, 2, 7, 90), 7, "positions 2..8 are exactly 7 bytes")
assert_eq(buffer_tostr$(b@), "aZZZZZZZ", "and they are the ones filled")
assert_eq(buffer_slice$(b@, 9, 0), "", "an empty range at length+1 is a legal no-op")
