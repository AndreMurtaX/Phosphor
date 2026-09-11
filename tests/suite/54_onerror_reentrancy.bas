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

test_case("select/a SELECT's subject belongs to the activation, not the program")
rem The FOR bound above, one construct along, and the same defect: the subject is
rem evaluated ONCE into a hidden temporary and reloaded before every case test, so
rem it has to survive the case EXPRESSIONS -- and a case expression is an
rem arbitrary expression that can call a function that re-enters this same SELECT.
rem While that temporary was a program-wide global the inner activation overwrote
rem it, and the outer SELECT then compared the INNER subject against its own
rem remaining labels. selre(2) answered -1; the same logic as an if/elseif chain,
rem and the same SELECT with the call hoisted out of the label, both answer 2.
rem
rem The subject is typed vtAny and now lives in a frame slot, so the string case
rem is here as well: it is the only kind of value that reaches that slot which a
rem FOR bound never could.
assert_eq(selre(1), -1, "the level that genuinely matches no label")
assert_eq(selre(2), 2, "case 2 still matches after a case expression re-entered")
assert_eq(selre(3), 3, "and case 3, one level deeper again")
assert_eq(selstr$("a"), "?", "the string subject that matches nothing")
assert_eq(selstr$("b"), "B", "and one that matches after the same re-entry")

rem ---------------------------------------------------------------
rem A JUMP OUT OF A FUNCTION IS REFUSED ONLY IF IT DOES NOT COME BACK.
rem
rem There is no label inside a function -- labels are recorded by the
rem top-level loop alone -- so every jump from inside one names a
rem label outside it. The first version of that check refused all of
rem them, and its reviewer measured twelve programs that answer
rem correctly WITHOUT the check and were refused WITH it.
rem
rem These pin the ones that must stay legal, because a jump that
rem RETURNS leaves nothing behind: gosub, on <expr> gosub, and an
rem `on error goto` handler installed inside a function body. The
rem shapes that never come back are pinned as refusals: plain goto
rem in tests/negative/28, on <expr> goto in tests/negative/30. They
rem need two files because they reach the check from two different
rem procedures.
rem
rem The last pair is the argument in one line: the same loop body
rem answers 10 whether its handler sits in the function that faults
rem or in the caller one frame up. Where the handler is installed is
rem not what makes it work, so refusing one of the two placements was
rem refusing a placement, not a defect.
rem ---------------------------------------------------------------

gtot = 0
assert_eq(gacc(3), 3, "a gosub inside a function reaches a top-level sub")
assert_eq(gacc(4), 4, "and again, from a second call")
assert_eq(gtot, 7, "the sub saw both visits")
assert_eq(grec(3), 6, "a gosub from a RECURSIVE function")
assert_eq(glog$, "3,2,1,0,", "at every level of the recursion")
assert_eq(gpick(1), 11, "on <expr> gosub, first label")
assert_eq(gpick(2), 22, "on <expr> gosub, second label")
assert_eq(ghand(), 5, "a handler installed INSIDE a function body runs")
assert_eq(gretry(), 5, "and plain resume retries the failing statement")
rem 0, AND IT USED TO BE 10 -- the expectation pinned the defect.
rem
rem `s = s - 10 / (i - 2)` is the LAST statement of the loop body, and `resume
rem next` used to leave the BLOCK: it scanned forward for the next statement
rem boundary, found `return s` past the loop, and the loop was abandoned after one
rem pass. So 10 was i=1's answer alone, written down as correct.
rem
rem Resuming continues the loop now. i=1 gives 10, i=2 faults and is skipped, i=3
rem gives 10 - 10/1 = 0. The same three-pass arithmetic the suite already pins one
rem line at a time elsewhere, arriving here because the loop is no longer cut off.
assert_eq(ginner(), 0, "an error raised inside a for, handled from in-function")
assert_eq(gouter(), 0, "and the same body with the handler one frame UP agrees")


function selre(n)
  select case n
  case selg(n)
    return 1
  case 2
    return 2
  case 3
    return 3
  endselect
  return -1
endfunction

function selg(n)
  if n > 1 then return selre(n - 1)
  return 99
endfunction

function selstr$(s$)
  select case s$
  case selgs$(s$)
    return "first"
  case "b"
    return "B"
  case "c"
    return "C"
  endselect
  return "?"
endfunction

function selgs$(s$)
  if s$ = "b" then return selstr$("a")
  return "zzz"
endfunction


function gacc(n)
  gcur = n
  gosub gaddit
  return gcur
endfunction

function grec(n)
  gcur = n
  gosub gnote
  if n <= 0 then return 0
  return n + grec(n - 1)
endfunction

function gpick(k)
  gr = 0
  on k gosub gone, gtwo
  return gr
endfunction

function ghand()
  on error goto gh
  gx = 1 / 0
  return 5
endfunction

function gretry()
  gd = 0
  on error goto gh2
  gx = 10 / gd
  return gx
endfunction

function ginner() local i, s
  on error goto gh
  for i = 1 to 3
    s = s - 10 / (i - 2)
  next
  return s
endfunction

function gouterbody() local i, s
  for i = 1 to 3
    s = s - 10 / (i - 2)
  next
  return s
endfunction

function gouter()
  on error goto gh
  return gouterbody()
endfunction


rem ---------------------------------------------------------------
rem RESUME NEXT CONTINUES IN CONTROL-FLOW ORDER, NOT IN TEXT ORDER.
rem
rem The resume point used to be found by scanning forward for the next
rem statement boundary, and only a STATEMENT carries one -- the code a
rem block generates for itself does not. So past the last statement of a
rem `then` block the scan found the `else` block; past a case arm it
rem found the next arm; and past a loop body it found the statement
rem AFTER the loop, stepping over the increment and the back-jump.
rem
rem A fault on the last line of a block therefore ran the branch that was
rem NOT taken, ran the arm that did NOT match, and abandoned a loop after
rem one pass -- silently, exit 0. Every on-error test in this suite put
rem its faulting statement before the end of its block, so none of them
rem could see it.
rem
rem The compiler writes the answer down now: each statement's boundary
rem records where that statement's code ends, which IS the continuation.
rem ---------------------------------------------------------------

test_case("resume/the branch not taken stays not taken")
rntook$ = ""
on error goto rnh
if 1 = 1 then
  rntook$ = rntook$ + "then,"
  rnx = 1 / 0
else
  rntook$ = rntook$ + "ELSE,"
end if
rntook$ = rntook$ + "after,"
goto rn1
rnh:
resume next
rn1:
on error goto 0
assert_eq(rntook$, "then,after,", "the else arm did not run")

test_case("resume/and the arm that did not match")
rnarm$ = ""
rnk = 1
on error goto rnh2
select case rnk
case 1
  rnarm$ = rnarm$ + "one,"
  rny = 1 / 0
case 2
  rnarm$ = rnarm$ + "TWO,"
case 3
  rnarm$ = rnarm$ + "THREE,"
end select
rnarm$ = rnarm$ + "after,"
goto rn2
rnh2:
resume next
rn2:
on error goto 0
assert_eq(rnarm$, "one,after,", "no later arm ran")

test_case("resume/a loop is not abandoned after one pass")
rem The faulting line is the LAST of the body, which is the whole point: the
rem loop's increment and test come after it in the instruction stream and used
rem to be stepped over.
rnw = 0
rnwi = 0
on error goto rnh3
while rnwi < 3
  rnwi = rnwi + 1
  rnw = rnw + 1
  rnz = 1 / 0
endwhile
goto rn3
rnh3:
resume next
rn3:
on error goto 0
assert_eq(rnw, 3, "a while loop ran all three passes")

rnf = 0
on error goto rnh4
for rnfi = 1 to 4
  rnf = rnf + 1
  rnq = 1 / 0
next
goto rn4
rnh4:
resume next
rn4:
on error goto 0
assert_eq(rnf, 4, "and a for loop ran all four")

rnr = 0
on error goto rnh5
repeat
  rnr = rnr + 1
  rnp = 1 / 0
until rnr >= 3
goto rn5
rnh5:
resume next
rn5:
on error goto 0
assert_eq(rnr, 3, "and a repeat loop ran to its own condition")

test_case("resume/and the ordinary case is unchanged")
rem A fault that is NOT the last statement of its block still resumes at the
rem line after it, which is what every other test here relies on.
rnmid$ = ""
on error goto rnh6
if 1 = 1 then
  rnmid$ = rnmid$ + "a,"
  rnm = 1 / 0
  rnmid$ = rnmid$ + "b,"
else
  rnmid$ = rnmid$ + "ELSE,"
end if
rnmid$ = rnmid$ + "c,"
goto rn6
rnh6:
resume next
rn6:
on error goto 0
assert_eq(rnmid$, "a,b,c,", "the rest of the block still runs")

rem ---------------------------------------------------------------
rem A HANDLER INSTALLED IN A CALL THAT RETURNED IS NOT AN ABANDONED ONE.
rem
rem The VM refuses a program whose `on error goto` handler runs off the end
rem while the call it was raised inside is still open -- through callfunc that
rem call's caller used to pop an operand it still needed and run the tail of
rem the program a second time, and tests/negative/33 and /34 pin the refusal.
rem
rem This is the shape one term away from it, and it is CORRECT. `abarm` installs
rem the handler and RETURNS NORMALLY, so the install depth stays at 1 for the
rem rest of the run while nothing at all is open. The later fault happens at TOP
rem LEVEL, the handler never resumes, and the program ends inside it.
rem
rem A check that asked only "was the handler installed inside a function" would
rem refuse this program: measured, it did, and it took a second reading of the
rem VM's own state to see why. What separates the two is where the FAILING
rem STATEMENT ran, not where the handler was installed.
rem
rem This block is deliberately the LAST executable one: entering a handler that
rem never resumes means control does not come back, so the statements after it
rem are the handler's own and the program ends by running off the end of the
rem file. That is exactly the exit the VM check sits on, which is the point --
rem the `end` above is reached only if this fault does not happen.
rem ---------------------------------------------------------------
test_case("onerror/a handler installed in a call that RETURNED is not abandoned")
assert_eq(abarm(1), 2, "the function that installed the handler returned normally")
abq = 1 / 0
assert_true(0, "the top-level fault must reach the handler, not this line")

end

function abarm(n) local z
  on error goto abend
  z = n + 1
  return z
endfunction

gaddit:
gtot = gtot + gcur
return

gnote:
glog$ = glog$ + str$(gcur) + ","
return

gone:
gr = 11
return

gtwo:
gr = 22
return

gh:
resume next

gh2:
gd = 2
resume

rem The handler for the block above. It never resumes, and the program ENDS
rem here, running off the end of the file with the handler still active -- the
rem VM's abandoned-activation check reads that exit and must let this through,
rem because the call the handler was installed in returned long ago and the
rem fault it took was raised at top level, with nothing open.
abend:
assert_eq(abq, 0, "the faulting assignment never completed")
assert_true(1, "and the handler ran to the end of the program without resuming")
