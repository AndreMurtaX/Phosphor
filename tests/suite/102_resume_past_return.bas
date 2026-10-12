rem ---------------------------------------------------------------
rem RESUME NEXT after a fault inside a `return` expression ENDS THE
rem FUNCTION. "Past the failing statement" is where execution would
rem have gone had it succeeded (language-reference.md, Error
rem handling), and a `return` that succeeds leaves the function. So
rem nothing after the return runs, and the function hands back the
rem default value for its type -- 0, or "" for a $ name -- exactly as
rem the reference says for a fault on a function's last statement.
rem
rem Until 2026-10-11 a return statement "ended" at the next line of
rem text: f(0) below ran the line after its return and answered 99, a
rem value no path of f can return for n = 0; a return inside an `if`
rem ran the code meant for the other case; and a return inside a loop
rem carried on with the loop. All at exit 0.
rem
rem Every expected value is the default for the function's suffix,
rem or arithmetic written beside the case. Each trap is disarmed
rem before its checks (see 49_on_error.bas).
rem ---------------------------------------------------------------

test_case("return/fault on a function's first return: nothing after it runs")
rem f(0): 10 / 0 faults inside the return. The function ends: 0.
ran = 0
hits = 0
on error goto h1
r = f(0)
on error goto 0
assert_eq(hits, 1, "the handler ran once")
assert_eq(r, 0, "f(0) is the default 0, not the 99 of the later return")
assert_eq(ran, 0, "the line after the return never ran")
goto h1_done
h1:
  hits += 1
  resume next
h1_done:

test_case("return/the same function, succeeding, is untouched")
rem f(2) = 10 / 2 = 5, and the line after the return is still unreached.
ran = 0
assert_eq(f(2), 5, "f(2) = 10 / 2")
assert_eq(ran, 0, "nothing after a successful return runs either")

test_case("return/inside an if block: the other case's code does not run")
rem g(0): the then-block's return faults. The code meant for n <> 0
rem must not run with n = 0; the function ends with 0.
other = 0
hits = 0
on error goto h2
r = g(0)
on error goto 0
assert_eq(hits, 1, "the handler ran once")
assert_eq(r, 0, "g(0) is the default 0")
assert_eq(other, 0, "the code for n <> 0 did not run")
goto h2_done
h2:
  hits += 1
  resume next
h2_done:

test_case("return/inside a for loop: the loop does not carry on")
rem a@ = [5, 0, 7]: pass 1 skips (5 <> 0); pass 2 returns 100 / 0 and
rem faults. The function ends with 0: no pass 3, no "fell out" -1.
a@ = dim@(3)
a@[1] = 5
a@[3] = 7
passes = 0
fell = 0
hits = 0
on error goto h3
r = findzero(a@)
on error goto 0
assert_eq(hits, 1, "the handler ran once")
assert_eq(r, 0, "findzero is the default 0, not the -1 after the loop")
assert_eq(passes, 2, "the loop stopped at the faulting pass")
assert_eq(fell, 0, "the code after the loop did not run")
goto h3_done
h3:
  hits += 1
  resume next
h3_done:

test_case("return/inside a while loop and a select arm")
rem w(3): the loop body's return 1 / (k - 3) faults with k = 3 on the
rem first pass; the function ends with 0 and the loop never goes round.
rem s$(2): the case 2 arm's return faults; the function ends with "",
rem and neither the next arm nor the line after endselect runs.
passes = 0
fell = 0
hits = 0
on error goto h4
r = w(3)
t$ = sel$(2)
on error goto 0
assert_eq(hits, 2, "two faults, one handler run each")
assert_eq(r, 0, "w(3) is the default 0")
assert_eq(passes, 1, "the while body ran once")
assert_true(t$ = "", "sel$(2) is the default empty string")
assert_eq(fell, 0, "no code after either return ran")
goto h4_done
h4:
  hits += 1
  resume next
h4_done:

test_case("return/on error call: a zero-returning handler ends the function too")
rem The handler is a function returning 0, which continues as resume
rem next does. f(0) ends with 0; the line after its return never runs.
ran = 0
callhits = 0
on error call fix
r = f(0)
on error goto 0
assert_eq(callhits, 1, "the call handler ran once")
assert_eq(r, 0, "f(0) is the default 0 under on error call")
assert_eq(ran, 0, "the line after the return never ran")

test_case("return/a fault in a callee ends the callee, and the caller's return goes on")
rem outer(0) = 1 + f(0). f's return faults and f ends with 0, so
rem outer's own return succeeds with 1 + 0 = 1.
ran = 0
hits = 0
on error goto h5
r = outer(0)
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(r, 1, "outer(0) = 1 + 0")
assert_eq(ran, 0, "nothing after f's return ran")
goto h5_done
h5:
  hits += 1
  resume next
h5_done:

end

function f(n)
  return 10 / n
  ran = 1
  return 99
end function

function g(n)
  if n = 0 then
    return 10 / n
  end if
  other = 1
  return n * 2
end function

function findzero(a@)
  for i = 1 to 3
    passes += 1
    if a@[i] = 0 then return 100 / a@[i]
  next
  fell = 1
  return -1
end function

rem The `passes < 3` term bounds the loop for the old behaviour, which
rem went round again after each fault: it then failed three assertions
rem below instead of hanging the runner.
function w(k)
  while k > 0 and passes < 3
    passes += 1
    return 1 / (k - 3)
  end while
  fell = 1
  return -1
end function

function sel$(k)
  select case k
    case 1
      return "one"
    case 2
      return str$(1 / 0)
    case else
      fell = 1
      return "other"
  end select
  fell = 1
  return "after"
end function

function outer(n)
  return 1 + f(n)
end function

function fix(code, msg$)
  callhits += 1
  return 0
end function
