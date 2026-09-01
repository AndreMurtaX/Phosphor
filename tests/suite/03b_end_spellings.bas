rem ---------------------------------------------------------------
rem Two-word block terminators (Plan9Basic style): end if, end while,
rem end select, end function -- equivalent to endif/endwhile/etc.
rem The one-word forms and the bare END statement are covered by
rem 02_control_flow and 03a_functions.
rem ---------------------------------------------------------------

function sq(n)
  return n * n
end function

test_case("spelling/end-if")
r = 0
if 1 = 1 then
  r = 5
end if
assert_eq(r, 5)

test_case("spelling/end-while")
i = 0
while i < 3
  i = i + 1
end while
assert_eq(i, 3)

test_case("spelling/end-select")
n = 2
r = 0
select case n
  case 2
    r = 20
end select
assert_eq(r, 20)

test_case("spelling/end-function")
assert_eq(sq(6), 36)
