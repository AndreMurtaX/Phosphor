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

test_case("callback/it reaches the library too, in the same order a direct call uses")

rem callfunc used to see only the program's own routines, so a name from the
rem library was a runtime error while the identical direct call worked. It now
rem asks the program FIRST and the library SECOND -- opCall's order -- so an
rem indirect call means what a direct one means, including which of two
rem same-named things wins.
assert_eq(callfunc("sqr", 9), 3, "a library function by name")
assert_eq(callfunc$("ucase$", "phosphor"), "PHOSPHOR", "and one that answers a string")
assert_eq(callfunc("len", "abcd"), 4, "and one taking a string, answering a number")

test_case("callback/more than one argument")

rem The registry resolves by argument KINDS, so a per-kind signature for every
rem arity would be 5^n keys. The arguments are registered as "any kind" instead,
rem one signature per arity -- which is why these work at all.
assert_eq(callfunc$("mid$", "abcdefgh", 3, 4), "cdef", "three arguments through to a library function")
assert_eq(callfunc("max", 7, 12), 12, "two arguments")
assert_eq(callfunc$("replacestr$", "a-b-c", "-", "+"), "a+b+c", "three strings")

test_case("callback/the program's own routine still wins")

rem shadow$ is defined below and also names nothing in the library; triple% is
rem the program's. If the library were consulted first, a program could not
rem override anything, and an event handler named like a built-in would silently
rem call the built-in.
assert_eq(callfunc%("triple%", 5), 15, "the program's routine is found first")

test_case("callback/a name in neither is one error, not two")

rem One question from the caller's side -- "can this be called?" -- so one answer.
caught = 0
on error goto h_none
x = callfunc("neither_program_nor_library", 1, 2, 3)
assert_eq(caught, 1, "an unknown name is refused however many arguments it was given")
on error goto 0
goto skip_none
h_none:
  caught = 1
  resume next
skip_none:

test_case("callback/asking before calling")

rem A dispatch table whose names come from data cannot be checked when the
rem program is packed -- a name in a dictionary is not an instruction. It can be
rem checked by the PROGRAM, where the table is built, which turns a failure that
rem would surface on some rare branch into one that surfaces at startup.
assert_true(funcexists?("sqr") = true, "a library name is callable")
assert_true(funcexists?("triple%") = true, "and one of this program's own routines")
assert_true(funcexists?("TRIPLE%") = true, "the question is case-insensitive, like the call")
assert_true(funcexists?("no_such_name_anywhere") = false, "and a name in neither is not")

rem It answers about the NAME, not the arity: the kinds of a call that has not
rem happened yet are not knowable, so a predicate about them would be guessing.
assert_true(funcexists?("mid$") = true, "a name that exists under several arities is still just there")

function identity@(h@)
  return h@
endfunction

function triple%(n)
  return n * 3
endfunction

function positive?(n)
  return n > 0
endfunction

rem The two routines the next block needs. shadow_that_faults calls a name that
rem does not exist, so IT fails with peUnknownFunction -- the same code the VM
rem used to read as "there is no such routine".
function shadow_that_faults(n)
  return no_such_helper(n)
endfunction

function plain_double(n)
  return n * 2
endfunction

test_case("callback/a routine that faults is NOT replaced by the library")
rem CallByName used to decide by the ERROR CODE: it called the program's routine
rem and fell through to the library whenever the answer came back
rem peUnknownFunction, on the reading that the code meant "there is no such
rem routine". It also means "the routine ran and hit a name IT could not
rem resolve" -- and then a DIFFERENT function ran under the same name and its
rem answer came back as if nothing had happened. abs(-5) reported the missing
rem name; callfunc("abs", -5) quietly answered 5, the library's. Existence now
rem decides, by name AND arity, exactly as a direct call decides.
caught% = 0
on error goto cbf
z = callfunc("shadow_that_faults", 1)
goto after_cbf
cbf:
caught% = 1
resume next
after_cbf:
on error goto 0
assert_eq(caught%, 1, "the program's own routine faulting is the answer")
assert_true(instr(errmsg$(), "no_such_helper") > 0, "and the message names what IT could not find")

rem the two halves that must keep working
assert_eq(callfunc("abs", -5), 5, "a name the program does not define still reaches the library")
assert_eq(callfunc("plain_double", 21), 42, "and one it does define still runs")
