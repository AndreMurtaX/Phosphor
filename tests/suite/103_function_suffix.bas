rem ---------------------------------------------------------------
rem A FUNCTION'S PARAMETERS AND ITS RESULT OBEY THEIR SUFFIXES.
rem language-reference.md: "The suffix decides what the name may
rem hold: an assignment coerces the value to it or refuses", and for
rem functions "The name's suffix is the return type". Binding an
rem argument is a store into the parameter and returning is a store
rem into the function's name, so each is coerced or refused exactly
rem as the assignment `n% = 2.5` is -- never kept as given.
rem
rem Until 2026-10-11 neither was asked: twice%(2.5) answered 5 while
rem twice%(n%) with n% = 2.5 answered 4, avg%(1, 2) answered 1.5, and
rem a $ function could hand back an int that failed far from the call.
rem
rem Every expected value is taken from an assignment to a name of the
rem same suffix, in the same case, so the case compares the two doors
rem rather than restating a number read off a run. Refusals carry the
rem error code the reference lists (1 overflow, 3 type mismatch). Each
rem trap is disarmed before its checks (see 49_on_error.bas).
rem ---------------------------------------------------------------

test_case("suffix/an int% parameter is coerced as an assignment is")
rem n% = 2.5 holds what the store rule makes of 2.5; the parameter
rem must hold the same, so twice%(2.5) = twice%(n%) = 2 * n%.
n% = 2.5
m% = 3.5
assert_eq(twice%(2.5), n% * 2, "twice%(2.5) binds 2.5 as n% = 2.5 does")
assert_int(twice%(2.5), twice%(n%), "the literal and the variable agree")
assert_int(twice%(3.5), m% * 2, "twice%(3.5) binds 3.5 as m% = 3.5 does")

test_case("suffix/an int% result is coerced as an assignment is")
rem (1 + 2) / 2 = 1.5. k% = 1.5 holds what the store rule makes of
rem it, and the function's result must be that same int%.
k% = 1.5
assert_eq(avg%(1, 2), k%, "avg%(1, 2) is the int% that k% = 1.5 holds")
assert_true(avg%(1, 2) = k%, "and compares equal to it")
assert_true(str$(avg%(1, 2)) = str$(k%), "and prints as the int% does")

test_case("suffix/a parameter with no suffix keeps what it is given")
rem A plain name holds an int% or a Double unchanged: 2.5 stays 2.5,
rem and 2^53 + 1 = 9007199254740993 stays exact (no Double holds it).
assert_eq(same(2.5), 2.5, "a Double passes through unchanged")
assert_true(str$(same(9007199254740993)) = "9007199254740993", "an int% stays exact")

test_case("suffix/a $ parameter refuses a number, at the call")
rem s$ = 123 is refused (type mismatch, code 3); so is binding 123 to a$.
code = 0
msg$ = ""
ran = 0
on error goto h1
r = slen(123)
on error goto 0
assert_eq(code, 3, "a type mismatch")
assert_true(instr(msg$, "parameter a$ of slen") > 0, "the message names the parameter and the function")
assert_eq(ran, 0, "the body never ran")
goto h1_done
h1:
  code = err()
  msg$ = errmsg$()
  resume next
h1_done:

test_case("suffix/a $ function refuses to return a number")
rem s$ = 7 is refused; so is returning 7 from name$. resume next then
rem ends the function with its default, "".
code = 0
msg$ = ""
on error goto h2
t$ = name$(7)
on error goto 0
assert_eq(code, 3, "a type mismatch")
assert_true(instr(msg$, "string function name$") > 0, "the message names the function")
assert_true(t$ = "", "resume next ended the function with the default")
goto h2_done
h2:
  code = err()
  msg$ = errmsg$()
  resume next
h2_done:

test_case("suffix/a number function refuses to return a string")
code = 0
on error goto h3
r = num("abc")
on error goto 0
assert_eq(code, 3, "a type mismatch")
goto h3_done
h3:
  code = err()
  resume next
h3_done:

test_case("suffix/an int% parameter refuses what n% = 1e300 refuses")
rem 1e300 is outside int%: the assignment reports an overflow (code 1),
rem and so does binding it.
code1 = 0
code2 = 0
on error goto h4
n% = 1e300
code1 = code2
code2 = 0
r = twice%(1e300)
on error goto 0
assert_eq(code1, 1, "the assignment's refusal is an overflow")
assert_eq(code2, 1, "binding the parameter is refused the same way")
goto h4_done
h4:
  code2 = err()
  resume next
h4_done:

test_case("suffix/bool and handle parameters refuse a number")
code1 = 0
code2 = 0
on error goto h5
r = isyes(1)
code1 = code2
code2 = 0
r = hnum(5)
on error goto 0
assert_eq(code1, 3, "1 into b? is a type mismatch")
assert_eq(code2, 3, "5 into p@ is a type mismatch")
goto h5_done
h5:
  code2 = err()
  resume next
h5_done:

test_case("suffix/callfunc binds and returns by the same rule")
rem The re-entrant door: callfunc% reaches twice% with 2.5 and must
rem bind it as the direct call does.
assert_int(callfunc%("twice%", 2.5), n% * 2, "callfunc% binds 2.5 as n% = 2.5 does")
code = 0
on error goto h6
r = callfunc("slen", 123)
on error goto 0
assert_eq(code, 3, "callfunc into a $ parameter refuses a number")
goto h6_done
h6:
  code = err()
  resume next
h6_done:

end

function twice%(n%)
  return n% * 2
end function

function avg%(a, b)
  return (a + b) / 2
end function

function same(x)
  return x
end function

function slen(a$)
  ran = 1
  return len(a$)
end function

function name$(x)
  return x
end function

function num(x$)
  return x$
end function

function isyes(b?)
  return 1
end function

function hnum(p@)
  return 1
end function
