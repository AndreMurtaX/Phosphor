rem ---------------------------------------------------------------
rem ON ERROR -- catchable runtime errors. A runtime error jumps to the
rem installed handler instead of aborting the program; err()/errmsg$()/
rem erl() read what happened, `resume next` continues past the failing
rem statement, `resume` retries it, `on error goto 0` disables, and
rem error() raises a catchable error. A handler catches errors raised in
rem called functions too (recover and continue with goto).
rem ---------------------------------------------------------------

test_case("onerror/catch and resume next")
caught = 0
after = 0
code1 = 0
line1 = 0
on error goto h1
x = 5 / 0
after = 42
assert_eq(caught, 1, "the handler ran on a division by zero")
assert_eq(after, 42, "resume next continued after the failing statement")
assert_eq(code1, 2, "err() reported the div-by-zero code")
assert_true(line1, "erl() reported the failing source line")
on error goto 0
goto skip1
h1:
  caught = 1
  code1 = err()
  line1 = erl()
  resume next
skip1:

test_case("onerror/resume retries the fixed statement")
denom = 0
tries = 0
on error goto h2
q = 100 / denom
assert_eq(q, 50, "resume retried the statement with the fixed denominator")
assert_eq(tries, 1, "the handler ran exactly once")
on error goto 0
goto skip2
h2:
  tries = tries + 1
  denom = 2
  resume
skip2:

test_case("onerror/error() raises a catchable error")
msg$ = ""
on error goto h3
error("boom")
assert_eq(msg$, "boom", "the custom message reached the handler")
on error goto 0
goto skip3
h3:
  msg$ = errmsg$()
  resume next
skip3:

test_case("onerror/err_clear resets the state")
on error goto h4
badcode = 0
z = 1 / 0
assert_eq(badcode, 2, "the div-by-zero code was read")
err_clear()
assert_eq(err(), 0, "err_clear reset the code to none")
on error goto 0
goto skip4
h4:
  badcode = err()
  resume next
skip4:

test_case("onerror/an error inside a called function is caught")
fcaught = 0
on error goto h5
r = risky(0)
assert_eq(fcaught, 1, "the handler caught an error raised inside risky()")
on error goto 0
goto done
h5:
  fcaught = 1
  goto done
done:

test_case("onerror/call a handler function")
rem `on error call func` runs func(code%, msg$) on a fault; returning 0 resumes
rem at the next statement (returning non-zero would abort -- see negative 14).
callcount = 0
callcode = 0
callmsg$ = ""
after_call = 0
on error call on_fault
w = 1 / 0
after_call = 7
assert_eq(callcount, 1, "the handler function was called once")
assert_eq(callcode, 2, "it received the div-by-zero code")
assert_eq(callmsg$, "division by zero", "and the message")
assert_eq(after_call, 7, "execution resumed at the statement after the fault")
on error goto 0

function risky(n)
  return 10 / n
endfunction

function on_fault(code, msg$)
  callcount = callcount + 1
  callcode = code
  callmsg$ = msg$
  return 0
endfunction
