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

test_case("onerror/`resume next` at the END of a body ends the function")
rem THE HANG. "The statement after the failing one" was looked up in the code as
rem laid out, not in the BODY that faulted. When the fault is the last statement of
rem a function there is no next statement in it, and the scan walked out of the body
rem into the main program -- landing on the very statement that had called the
rem function, which called it again, and again: this program printed its first line
rem millions of times before anyone stopped it.
rem
rem What it must do instead: the function ENDS, returning the default value for its
rem type, and the caller's half-built expression carries on with that -- the same
rem thing falling off the end of a body always does. The 1000 keeps the overlap
rem honest at the same time.
rem
rem tries7% IS THE GUARD. The definition sits immediately before the call on
rem purpose, so a regression resumes onto that call; the fourth visit stops
rem faulting, so a regression FAILS these assertions instead of hanging the suite.
tries7% = 0
caught7% = 0
r7 = -1
on error goto h7

function tailfault(n)
  tries7% = tries7% + 1
  if tries7% > 3 then return -1
  return no_such_name_at_all(n)
endfunction

r7 = 1000 + tailfault(5)
goto after7
h7:
caught7% = caught7% + 1
resume next
after7:
on error goto 0
assert_eq(tries7%, 1, "the body ran once -- a regression calls it again for ever")
assert_eq(caught7%, 1, "and the handler ran once")
assert_eq(r7, 1000, "the function ended with its type's default and 1000 + it finished")

test_case("onerror/... and a string function ends with the empty string")
rem The default is the RETURN TYPE's, so the $ suffix decides it here.
tries8% = 0
s8$ = "unset"
on error goto h8

function tailfault$(s$)
  tries8% = tries8% + 1
  if tries8% > 3 then return "guard"
  return no_such_name_at_all$(s$)
endfunction

s8$ = "[" + tailfault$("x") + "]"
goto after8
h8:
resume next
after8:
on error goto 0
assert_eq(tries8%, 1, "the body ran once")
assert_eq(s8$, "[]", "the string function ended empty and the concatenation finished")

test_case("onerror/the resume point follows the CALLER once the callee has returned")
rem The current statement was left pointing INSIDE a function that had already
rem returned, because only entering a body moved it and returning never moved it
rem back. The fault here is the caller's own `/ 0`, and the resume point named a
rem statement of plain9 -- a frame that no longer existed.
rem
rem THE HANDLER COUNT IS WHAT CATCHES IT. Ending that dead frame hands its default
rem back into the MIDDLE of `plain9(1) / d9`, which divides by zero a second time,
rem so the handler runs twice for one mistake; every other visible result of this
rem test case is the same either way, and asserting them alone tested nothing.
rem d9 is the guard -- a regression that instead resumes onto the faulting call
rem comes back here, so the fourth visit removes the fault and these assertions
rem fail instead of the suite hanging.
tries9% = 0
step9% = 0
caught9% = 0
d9 = 0
q9 = -1
on error goto h9

function plain9(n)
  tries9% = tries9% + 1
  if tries9% > 3 then d9 = 1
  return n
endfunction

q9 = plain9(1) / d9
step9% = 7
goto after9
h9:
caught9% = caught9% + 1
resume next
after9:
on error goto 0
assert_eq(caught9%, 1, "one fault, one handler run -- a stale resume point faults again")
assert_eq(tries9%, 1, "the callee ran once")
assert_eq(step9%, 7, "the statement after the failing one really ran")
assert_eq(q9, -1, "and the failing assignment left its variable alone")

test_case("onerror/`resume next` may END the call a re-entrant activation was launched for")
rem The fault is the LAST statement of worker10, and worker10 is running under
rem callfunc -- a NATIVE re-entry, whose frame has no return address (-1) because
rem the activation stops by frame level instead. Ending the function there has to
rem stop this activation the way opRetFunc does, with the value on the stack;
rem resuming to that -1 is the out-of-bounds spin the third case above is about.
hcount10% = 0
r10 = callfunc("worker10")
on error goto 0
assert_eq(r10, 0, "callfunc got the ended function's default back")
assert_eq(hcount10%, 1, "and the handler installed inside it ran once")

function worker10()
  on error call count10
  return no_such_name_at_all(1)
endfunction

function count10(code, msg$)
  hcount10% = hcount10% + 1
  return 0
endfunction

function sumto(n)
  if n <= 0 then return 0
  return n + sumto(n - 1)
endfunction

function oops(code, msg$)
  handled% = 1
  return 0
endfunction

test_case("for/a loop's upper bound belongs to the activation, not the program")
rem The bound was evaluated once into a hidden GLOBAL, so a function that recursed
rem from inside its own loop had the inner call rewrite the outer loop's limit: the
rem outer loop stopped after one pass. f(2) answered 2 and f(3) answered 3.
assert_eq(recsum(1), 1, "one level")
assert_eq(recsum(2), 4, "two iterations, each adding 1 + recsum(1)")
assert_eq(recsum(3), 15, "and the same shape one level deeper")
assert_eq(nested(4), 16, "a nested loop in a function is unaffected")
assert_eq(downrec(2), 5, "and so is a negative step")

function recsum(n) local i, s
  s = 0
  for i = 1 to n
    s = s + 1
    if n > 1 then s = s + recsum(n - 1)
  next
  return s
endfunction

function nested(n) local i, j, s
  s = 0
  for i = 1 to n
    for j = 1 to n
      s = s + 1
    next
  next
  return s
endfunction

function downrec(n) local i, s
  s = 0
  for i = n to 1 step -1
    s = s + i
    if n > 1 then s = s + downrec(n - 1)
  next
  return s
endfunction
