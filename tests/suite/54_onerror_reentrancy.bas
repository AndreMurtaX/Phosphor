rem ---------------------------------------------------------------
rem ON ERROR across re-entrant calls.
rem
rem A handler runs at the level it was INSTALLED at; `resume` returns
rem to the level the failing STATEMENT ran at. Everything between the
rem two -- the caller's half-evaluated operands and every activation
rem frame down to the faulting one -- is still needed by the pending
rem resume, and the handler used to run directly on top of it.
rem
rem The results were silent: `1000 + risky(0)` came back as 12,
rem because the handler's own `zz = 7` landed in the slot holding the
rem 1000. Every suite stayed green throughout.
rem ---------------------------------------------------------------

function risky(n)
  q = 10 / n
  return 5
endfunction

function other(z)
  return z
endfunction

function deep(n)
  if n <= 0 then return 0
  return callfunc("deep", n - 1)
endfunction

function bad()
  z = 1 / 0
  return 99
endfunction

test_case("onerror/the caller's half-built expression survives the handler")
on error goto h1
r = 1000 + risky(0)
goto after1
h1:
zz = 7
resume next
after1:
on error goto 0
assert_eq(r, 1005, "the handler's own pushes used to overwrite the pending 1000")
assert_eq(zz, 7, "and the handler's variable is still what it set")

test_case("onerror/a function called BY the handler does not eat the faulting frame")
on error goto h2
r2 = risky(0)
goto after2
h2:
t = other(777)
resume next
after2:
on error goto 0
assert_eq(t, 777, "the handler's own call works")
assert_eq(r2, 5, "and the resumed function still returns to its real caller")

test_case("onerror/`on error call` resumes instead of spinning on pc = -1")
rem The handler routine's frame was pushed into the slot the FAULTING function
rem occupied, writing the -1 'no return address' sentinel into it. Resuming then
rem returned to pc -1 and the interpreter read out of bounds, forever.
on error call oops
r3 = risky(0)
on error goto 0
assert_eq(r3, 5, "the fault is swallowed and the function finishes")
assert_eq(handled%, 1, "the handler routine really ran")

test_case("onerror/a fault inside callfunc is handled ONCE, by the outer level")
rem The handler belongs to the outer activation. Running it inside the nested one
rem executed the rest of the program there, fell off the end, and then let the
rem caller run everything a second time.
trace$ = ""
on error goto h4
x4 = callfunc("bad")
trace$ = trace$ + "after|"
goto after4
h4:
trace$ = trace$ + "caught|"
resume next
after4:
on error goto 0
assert_eq(trace$, "caught|after|", "caught once, then resumed exactly once")
assert_eq(errmsg$(), "division by zero", "and the message is the real one")

test_case("onerror/re-entrant recursion is bounded instead of segfaulting")
rem callfunc re-enters the interpreter with a NATIVE call, so this spends process
rem stack. 20000 levels used to raise EStackOverflow deep inside, leave the frame
rem stack thousands deep because no unwinding ran, and then segfault while the
rem handler tried to resume.
caught5% = 0
on error goto h5
x5 = callfunc("deep", 20000)
goto after5
h5:
caught5% = 1
resume next
after5:
on error goto 0
assert_eq(caught5%, 1, "a catchable error, not a crash")
assert_true(instr(errmsg$(), "too deep") > 0, "and it says what happened")

test_case("onerror/ordinary recursion is NOT bounded by that limit")
rem An ordinary call is a jump inside one interpreter loop and costs heap, not
rem process stack, so the re-entrancy ceiling must not touch it.
assert_eq(sumto(2000), 2001000, "2000 ordinary recursive calls still work")

test_case("onerror/callfunc under the ceiling still works normally")
assert_eq(callfunc("deep", 200), 0, "200 re-entrant levels are fine")
assert_eq(callfunc("other", 42), 42, "and so is one")

test_case("onerror/resume (retry) really re-runs the failing statement")
rem `resume` retries the STATEMENT that failed, so the handler has to change
rem something for the retry to succeed -- otherwise it retries forever, which is
rem the correct behaviour and was worth confirming while writing this.
tries% = 0
d6 = 0
on error goto h6
q6 = 10 / d6
goto after6
h6:
tries% = tries% + 1
d6 = 2
resume
after6:
on error goto 0
assert_eq(tries%, 1, "the handler ran once")
assert_eq(q6, 5, "and the retried statement then produced its real value")

function sumto(n)
  if n <= 0 then return 0
  return n + sumto(n - 1)
endfunction

function oops(code, msg$)
  handled% = 1
  return 0
endfunction
