rem ---------------------------------------------------------------
rem A bare RETURN.
rem
rem `return` with nothing after it used to be "Return value expected",
rem which made every procedure in the language pretend to be a
rem function. It now gives back exactly what ENDFUNCTION gives when
rem control falls off the end, so the two mean the same thing.
rem
rem Everything a bare RETURN can be followed by is exercised here:
rem end of line, a colon, and being the last thing in a function.
rem ---------------------------------------------------------------

test_case("return/bare-numeric")
counter = 0
bump()
assert_eq(counter, 1, "a procedure with a bare return ran")
bump()
bump()
assert_eq(counter, 3, "and again")

test_case("return/bare-is-zero")
assert_eq(bump(), 0, "the value it gives back is the same as falling off the end")
assert_eq(falls_off(), 0, "which is zero")

test_case("return/bare-early-exit")
rem The reason for the feature: leaving early without inventing a value.
counter = 0
guarded(0)
assert_eq(counter, 0, "the guard returned before doing the work")
guarded(1)
assert_eq(counter, 1, "and let it through otherwise")

test_case("return/bare-after-colon")
counter = 0
colon_form(0)
assert_eq(counter, 0, "a bare return before a colon")
colon_form(1)
assert_eq(counter, 5, "and the statement after it")

test_case("return/bare-string")
assert_eq(bare_str$(), "", "a string function gives back an empty string")
assert_eq(bare_str$() + "x", "x", "which is usable")
assert_eq(falls_off_str$(), "", "the same as falling off the end")

test_case("return/value-return-still-works")
assert_eq(doubled(21), 42, "a return with a value is untouched")
assert_eq(named$("a"), "hello a", "for strings too")
assert_eq(counter, 5, "and nothing above disturbed the global")

test_case("return/outside-a-function")
rem RETURN outside a function is a different statement entirely -- it
rem pairs with GOSUB -- and is handled before any of this.
gosubbed = 0
gosub mark
assert_eq(gosubbed, 1, "GOSUB and RETURN still pair up")
goto done
mark:
gosubbed = 1
return
done:
assert_eq(gosubbed, 1, "and control came back")

function bump()
  counter = counter + 1
  return
endfunction

function falls_off()
  counter = counter + 0
endfunction

function guarded(go)
  if go = 0 then return
  counter = counter + 1
endfunction

function colon_form(go)
  if go = 0 then return
  counter = 5 : counter = counter + 0
endfunction

function bare_str$()
  return
endfunction

function falls_off_str$()
  counter = counter + 0
endfunction

function doubled(n)
  return n * 2
endfunction

function named$(who$)
  return "hello " + who$
endfunction
