rem ---------------------------------------------------------------
rem A TYPED ARRAY HOLDS ITS OWN KIND, BY THE ASSIGNMENT'S RULE.
rem dim@ makes a numeric array, sdim@ a string one, pdim@ a handle
rem one. Writing an element is a store, so it takes exactly what a
rem name of the matching suffix takes: a numeric element what a plain
rem name holds (an int% or a Double, kept as given), a string element
rem what s$ holds, a pointer element what h@ holds. Anything else is
rem refused with the code `s$ = 5` gets (3, type mismatch), the
rem message names the array's kind, and the element is unchanged.
rem
rem Until 2026-10-12 every write was kept as given: a@[1] = "hi" put a
rem string into a dim@ array and sarr_get$ could answer an int
rem (stabilization ledger rows 2 and 13). Every element write goes
rem through the one setter (arr_set@ and its typed spellings), so the
rem cases below cover the bracket sugar, its 2-index form, the
rem compound form and a direct call.
rem
rem Each expected code is taken from an assignment to a name of the
rem matching suffix, made in the same case, so the case compares the
rem two doors rather than restating a number read off a run. Each
rem trap is disarmed before its checks (see 49_on_error.bas).
rem ---------------------------------------------------------------

test_case("array kind/a numeric array refuses a string, as x = \"hi\" does")
a@ = dim@(3)
a@[1] = 7
want = 0
code = 0
msg$ = ""
on error goto h1
x = "hi"
want = code
code = 0
a@[1] = "hi"
on error goto 0
assert_eq(want, 3, "the assignment's refusal is a type mismatch")
assert_eq(code, want, "the element write is refused the same way")
assert_true(instr(msg$, "numeric array") > 0, "the message names the array's kind")
assert_eq(a@[1], 7, "and the element is unchanged")
goto h1_done
h1:
  code = err()
  msg$ = errmsg$()
  resume next
h1_done:

test_case("array kind/a string array refuses a number, as s$ = 5 does")
s@ = sdim@(2)
s@[2] = "old"
want = 0
code = 0
msg$ = ""
on error goto h2
t$ = 5
want = code
code = 0
s@[2] = 5
on error goto 0
assert_eq(want, 3, "the assignment's refusal is a type mismatch")
assert_eq(code, want, "the element write is refused the same way")
assert_true(instr(msg$, "string array") > 0, "the message names the array's kind")
assert_true(sarr_get$(s@, 2) = "old", "sarr_get$ answers the string that was there")
goto h2_done
h2:
  code = err()
  msg$ = errmsg$()
  resume next
h2_done:

test_case("array kind/a pointer array refuses a number and a string, as h@ does")
p@ = pdim@(2)
p@[1] = a@
want = 0
code1 = 0
code2 = 0
code = 0
on error goto h3
q@ = 5
want = code
code = 0
p@[1] = 5
code1 = code
code = 0
p@[1] = "x"
code2 = code
on error goto 0
assert_eq(want, 3, "the assignment's refusal is a type mismatch")
assert_eq(code1, want, "a number into a pointer element is refused the same way")
assert_eq(code2, want, "and so is a string")
assert_true(arraytypename$(parr_get@(p@, 1)) = "numeric", "the element still holds a@")
goto h3_done
h3:
  code = err()
  resume next
h3_done:

test_case("array kind/a handle goes into neither a numeric nor a string array")
code1 = 0
code2 = 0
code = 0
on error goto h4
a@[2] = p@
code1 = code
code = 0
s@[1] = p@
code2 = code
on error goto 0
assert_eq(code1, 3, "a handle into a numeric element is a type mismatch")
assert_eq(code2, 3, "a handle into a string element is a type mismatch")
assert_eq(a@[2], 0, "the numeric element keeps its default")
assert_true(s@[1] = "", "the string element keeps its default")
goto h4_done
h4:
  code = err()
  resume next
h4_done:

test_case("array kind/a numeric element keeps an int% and a Double as a plain name does")
rem 2^53 + 1 = 9007199254740993 is exact only as an int%; a plain name
rem keeps it, so the element must print the same digits.
big = 9007199254740993
a@[3] = big
assert_true(str$(a@[3]) = str$(big), "an int% is stored exactly")
a@[2] = 2.5
assert_eq(a@[2], 2.5, "a Double is stored as given")
n% = 4
a@[1] = n%
assert_int(narr_get(a@, 1), n%, "an int% variable widens into the element")

test_case("array kind/the 2-index and direct-call doors ask the same rule")
rem The compound form a@[i] += v cannot reach a wrong kind: on a
rem numeric element 4 + "x" is refused by the '+' itself, and on a
rem string element "old" + 1 is the string "old1".
g@ = dim@(2, 3)
g@[2, 3] = 99
code1 = 0
code3 = 0
code = 0
on error goto h5
g@[2, 3] = "x"
code1 = code
code = 0
r@ = arr_set@(a@, 1, "x")
code3 = code
on error goto 0
assert_eq(code1, 3, "g@[2, 3] = \"x\" is refused")
assert_eq(g@[2, 3], 99, "and the element is unchanged")
assert_eq(code3, 3, "arr_set@ called by name is refused")
assert_int(narr_get(a@, 1), n%, "and the element is unchanged")
goto h5_done
h5:
  code = err()
  resume next
h5_done:

test_case("array kind/each kind still takes its own")
s@[1] = "ab"
s@[1] += "c"
assert_true(sarr_get$(s@, 1) = "abc", "a string array takes a string")
p@[2] = s@
assert_true(arraytypename$(parr_get@(p@, 2)) = "string", "a pointer array takes a handle")
a@[1] += 1
assert_int(narr_get(a@, 1), n% + 1, "a numeric array takes a number")

end
