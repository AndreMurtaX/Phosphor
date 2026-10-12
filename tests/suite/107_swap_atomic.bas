rem ---------------------------------------------------------------
rem SWAP IS ALL-OR-NOTHING.
rem `swap a, b` stores b's value into a and a's into b, each by the
rem rule an assignment uses (coerced to the suffix, or refused). If
rem either store would be refused, NEITHER is done: the statement
rem fails with the refusal's code and both values are as they were.
rem
rem Until 2026-10-12 the two stores were simply done in order, so
rem `swap x, n%` with x = 1e300 stored n% into x and then failed to
rem store 1e300 into n%; under `resume next` the 1e300 was gone
rem (stabilization ledger row 3). An element's index was also
rem evaluated twice -- once to read, once to write -- so
rem `swap a@[1], a@[a@[1]]` wrote a different element from the one
rem it read.
rem
rem Each expected code is taken from the assignment that would have
rem been refused, made in the same case (1 overflow, 3 type
rem mismatch). Each trap is disarmed before its checks.
rem ---------------------------------------------------------------

test_case("swap/a refused second store leaves both scalars unchanged")
rem n% = 1e300 is an overflow; x = n% is not. Either order.
x = 1e300
n% = 5
want = 0
code1 = 0
code2 = 0
code = 0
on error goto h1
m% = 1e300
want = code
code = 0
swap x, n%
code1 = code
code = 0
swap n%, x
code2 = code
on error goto 0
assert_eq(want, 1, "n% = 1e300 is an overflow")
assert_eq(code1, want, "swap x, n% is refused the same way")
assert_eq(code2, want, "and so is swap n%, x")
assert_eq(x, 1e300, "x keeps 1e300")
assert_int(n%, 5, "n% keeps 5")
goto h1_done
h1:
  code = err()
  resume next
h1_done:

test_case("swap/an element and a scalar: the same, either order")
a@ = dim@(3)
a@[1] = 1e300
n% = 5
code1 = 0
code2 = 0
code = 0
on error goto h2
swap a@[1], n%
code1 = code
code = 0
swap n%, a@[1]
code2 = code
on error goto 0
assert_eq(code1, 1, "swap a@[1], n% is an overflow")
assert_eq(code2, 1, "swap n%, a@[1] is an overflow")
assert_eq(a@[1], 1e300, "the element keeps 1e300")
assert_int(n%, 5, "n% keeps 5")
goto h2_done
h2:
  code = err()
  resume next
h2_done:

test_case("swap/a kind mismatch leaves both unchanged")
rem s$ = 2 and a@[i] = "two" (a numeric array) are both refused.
s$ = "two"
x = 2
t@ = sdim@(2)
t@[1] = "one"
a@[2] = 7
code1 = 0
code2 = 0
code3 = 0
code = 0
on error goto h3
swap s$, x
code1 = code
code = 0
swap a@[2], s$
code2 = code
code = 0
swap a@[2], t@[1]
code3 = code
on error goto 0
assert_eq(code1, 3, "swap s$, x is a type mismatch")
assert_eq(code2, 3, "swap a@[2], s$ is a type mismatch")
assert_eq(code3, 3, "swap of a numeric and a string element is a type mismatch")
assert_true(s$ = "two", "s$ is unchanged")
assert_eq(x, 2, "x is unchanged")
assert_eq(a@[2], 7, "the numeric element is unchanged")
assert_true(t@[1] = "one", "the string element is unchanged")
goto h3_done
h3:
  code = err()
  resume next
h3_done:

test_case("swap/an index out of range is refused before anything is written")
a@[3] = 9
code = 0
on error goto h4
swap a@[3], a@[4]
on error goto 0
assert_eq(code, 6, "index 4 of a 3-element array is out of range")
assert_eq(a@[3], 9, "a@[3] is unchanged")
goto h4_done
h4:
  code = err()
  resume next
h4_done:

test_case("swap/a refused swap inside a function leaves its locals unchanged")
rem Locals are frame slots, a separate store path. The trap is the
rem caller's; resume next continues inside the function, at its
rem return. str$(1e300) is "1E300", as str$(x) above spells it.
code = 0
r$ = ""
on error goto h5
r$ = local_swap$()
on error goto 0
assert_eq(code, 1, "the swap inside the function is an overflow")
assert_true(r$ = str$(1e300) + " 5", "both locals are unchanged")
goto h5_done
h5:
  code = err()
  resume next
h5_done:

test_case("swap/a swap that fits stores each value by the assignment rule")
rem k% = 2.5 holds what the store rule makes of 2.5; after the swap
rem n% must hold the same, and x the 5 that n% held.
x = 2.5
n% = 5
k% = 2.5
swap x, n%
assert_int(n%, k%, "n% holds what k% = 2.5 holds")
assert_eq(x, 5, "x holds 5")
s$ = "a"
u$ = "b"
swap s$, u$
assert_true(s$ + u$ = "ba", "two strings exchange")

test_case("swap/an element's indices are evaluated once")
rem a@[1] = 2 and a@[2] = 10: the second target reads a@[a@[1]] =
rem a@[2]. The exchange is between elements 1 and 2 as they were
rem read, so a@[1] becomes 10 and a@[2] becomes 2 -- not a write to
rem a@[a@[1]] re-read after a@[1] changed (a@[10], out of range).
a@[1] = 2
a@[2] = 10
swap a@[1], a@[a@[1]]
assert_eq(a@[1], 10, "a@[1] took a@[2]'s value")
assert_eq(a@[2], 2, "a@[2] took a@[1]'s value")
calls = 0
a@[3] = 30
y = 4
swap a@[bump()], y
assert_eq(calls, 1, "the index expression ran once")
assert_eq(a@[3], 4, "a@[3] took y's value")
assert_eq(y, 30, "y took a@[3]'s value")

end

function bump()
  calls = calls + 1
  return 3
end function

function local_swap$() local lx, ln%
  lx = 1e300
  ln% = 5
  swap lx, ln%
  return str$(lx) + " " + str$(ln%)
end function
