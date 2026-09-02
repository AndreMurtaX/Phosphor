rem ---------------------------------------------------------------
rem callfunc -- the indirect call, and with it the engine's host-callback
rem seam (the VM's CallUserFunc). A BASIC routine is chosen by name at run
rem time and invoked over the SAME globals and handles as its caller. This
rem is exactly the path a phase-2 GUI event dispatcher takes to reach a
rem handler; proving it here, headless and GUI-free, freezes the seam
rem before the LCL host is built on it.
rem ---------------------------------------------------------------

test_case("callfunc/one numeric argument")
assert_eq(callfunc("dbl", 21), 42, "callfunc ran dbl(21)")
assert_eq(callfunc("dbl", 0), 0, "and dbl(0)")
assert_near(callfunc("half", 5), 2.5, 0.0001, "a double argument and result survive")

test_case("callfunc/no argument")
assert_eq(callfunc("answer"), 42, "the no-argument form runs too")

test_case("callfunc/a string in and a string out")
rem The name is the routine's exact name, suffix and all; the suffix on
rem callfunc$ only says a string is expected back.
assert_eq(callfunc$("shout$", "hi"), "HI!", "callfunc$ ran shout$ and returned its text")

test_case("callfunc/shares the caller's globals")
rem The routine reads and writes the same globals as here -- the property an
rem event handler leans on when it bumps a score or flips a flag.
counter = 0
callfunc("bump")
callfunc("bump")
callfunc("bump")
assert_eq(counter, 3, "three indirect calls each moved the shared global")

test_case("callfunc/re-enters to any depth")
rem fact calls itself THROUGH callfunc, so the re-entrant seam is exercised
rem recursively, not just once.
assert_eq(callfunc("fact", 5), 120, "indirect recursion computes 5!")

test_case("callfunc/carries a handle both ways")
rem The GUI shape: a handler is handed the sender handle and can hand one
rem back. The array that returns is the same live object that went in.
a@ = dim@(3)
a@[1] = 99
b@ = callfunc@("identity@", a@)
assert_eq(b@[1], 99, "the handle that came back is the one that went in")
assert_eq(arraysize(b@), 3, "same live array, not a copy")

test_case("callfunc/called purely for effect")
rem A routine can be called as a statement; its return value is discarded.
callfunc("bump")
assert_eq(counter, 4, "the effect still happened")

test_case("callfunc/one spelling per return kind")
rem callfunc% reads an int% back and callfunc? a bool -- the % and ? spellings
rem complete the set (none / % / $ / @ / ?), one per value kind.
assert_eq(callfunc%("triple%", 7), 21, "callfunc% returns an int result")
assert_true(callfunc?("positive?", 5))
assert_false(callfunc?("positive?", 0 - 5))

function dbl(n)
  return n * 2
endfunction

function half(n)
  return n / 2
endfunction

function answer()
  return 42
endfunction

function shout$(s$)
  return ucase$(s$) + "!"
endfunction

function bump()
  counter = counter + 1
  return 0
endfunction

function fact(n)
  if n <= 1 then return 1
  return n * callfunc("fact", n - 1)
endfunction

function identity@(h@)
  return h@
endfunction

function triple%(n)
  return n * 3
endfunction

function positive?(n)
  return n > 0
endfunction
