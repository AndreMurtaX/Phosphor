rem ---------------------------------------------------------------
rem RESUME after a fault in a loop's OWN code: the while / do while
rem test, the repeat-until test, the for increment and the for limit
rem check. Those are statements of their own for error purposes:
rem
rem   resume       retries that test (or that increment), and nothing
rem                else -- the last body statement does NOT run again;
rem   resume next  continues AFTER THE LOOP, because the test could
rem                not say yes. Never an endless retry, never a silent
rem                end of the program, never a function returning its
rem                default with work still to do.
rem
rem Until 2026-10-09 the loop's own code carried no statement boundary,
rem so a fault there was blamed on the body's LAST statement. `resume
rem next` jumped to where that statement ends -- the loop tail -- and
rem faulted again; the handler's second `resume next` then went on past
rem the handler, which at top level ENDED THE PROGRAM at exit 0 with
rem the rest of the file unrun, and inside a function returned 0.
rem `resume` re-ran the last body statement instead of the test.
rem
rem Every expected value below is worked out by hand beside its case.
rem Each trap is disarmed before the checks (see 49_on_error.bas).
rem ---------------------------------------------------------------

rem 9223372036854775807 is the largest int%; one more is an overflow.
big% = 9223372036854775806

test_case("loop tail/while test faults on a later pass: resume next leaves the loop")
rem d = 2: pass 1 tests 10/2 = 5 > 1, body runs, d = 1.
rem pass 2 tests 10/1 = 10 > 1, body runs, d = 0.
rem pass 3 tests 10/0: the fault. resume next -> after the loop.
d = 2
body = 0
hits = 0
after = 0
on error goto wh1
while 10 / d > 1
  body += 1
  d -= 1
endwhile
after = 1
on error goto 0
assert_eq(hits, 1, "the handler ran once, not once per re-fault")
assert_eq(body, 2, "the body ran twice")
assert_eq(after, 1, "resume next continued after the loop, not off the end")
goto wh1_done
wh1:
  hits += 1
  resume next
wh1_done:

test_case("loop tail/while test faults: resume retries the TEST, not the body")
rem d = 5: pass 1 tests 10/5 = 2 > 1, body: body = 1, d = 5 - 5 = 0.
rem pass 2 tests 10/0: fault. The handler sets d = 100 and resumes.
rem The retry re-evaluates 10/100 = 0.1 > 1: false, the loop ends.
rem d stays 100. (Re-running the body's last line made it 95.)
d = 5
body = 0
hits = 0
on error goto wh2
while 10 / d > 1
  body += 1
  d -= 5
endwhile
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(body, 1, "the body ran once")
assert_eq(d, 100, "the retry ran the test, not d -= 5")
goto wh2_done
wh2:
  hits += 1
  d = 100
  resume
wh2_done:

test_case("loop tail/while retry that lets the loop run on")
rem d = 1: pass 1 tests 2 < 10/1 = 10, body: c = 1, d = 0.
rem pass 2 tests 2 < 10/0: fault, handler sets d = 2, resume.
rem retry: 2 < 10/2 = 5, true: body c = 2, d = 1.
rem pass 3: 2 < 10/1 = 10, true: body c = 3, d = 0.
rem pass 4: fault again; handler (hits 2) sets d = 98, resume.
rem retry: 2 < 10/98 is false: the loop ends with c = 3.
d = 1
c = 0
hits = 0
on error goto wh3
while 2 < 10 / d
  c += 1
  d -= 1
endwhile
on error goto 0
assert_eq(hits, 2, "two faults")
assert_eq(c, 3, "three passes of the body")
assert_eq(d, 98, "the second retry re-tested with d = 98")
goto wh3_done
wh3:
  hits += 1
  if hits = 1 then
    d = 2
  else
    d = 98
  endif
  resume
wh3_done:

test_case("loop tail/do while test faults: resume next leaves the loop")
rem Same arithmetic as the first while case: two passes, one fault.
d = 2
body = 0
hits = 0
after = 0
on error goto dw1
do while 10 / d > 1
  body += 1
  d -= 1
loop
after = 1
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(body, 2, "two passes")
assert_eq(after, 1, "continued after the loop")
goto dw1_done
dw1:
  hits += 1
  resume next
dw1_done:

test_case("loop tail/do while test faults: resume retries the test")
d = 5
body = 0
hits = 0
on error goto dw2
do while 10 / d > 1
  body += 1
  d -= 5
loop
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(body, 1, "one pass")
assert_eq(d, 100, "the retry ran the test, not d -= 5")
goto dw2_done
dw2:
  hits += 1
  d = 100
  resume
dw2_done:

test_case("loop tail/repeat-until test faults: resume next leaves the loop")
rem d = 2: pass 1 body: body = 1, d = 1; test 10/1 = 10 < 1 false, again.
rem pass 2 body: body = 2, d = 0; test 10/0: fault. resume next -> after.
d = 2
body = 0
hits = 0
after = 0
on error goto ru1
repeat
  body += 1
  d -= 1
until 10 / d < 1
after = 1
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(body, 2, "two passes")
assert_eq(after, 1, "continued after the loop")
goto ru1_done
ru1:
  hits += 1
  resume next
ru1_done:

test_case("loop tail/repeat-until test faults: resume retries the test")
rem d = 1: pass 1 body: body = 1, d = 0; test 10/0 faults.
rem The handler sets d = 100; the retry tests 10/100 = 0.1 < 1: true, done.
rem (Re-running the body's last line instead made d = 99 and body stayed 1.)
d = 1
body = 0
hits = 0
on error goto ru2
repeat
  body += 1
  d -= 1
until 10 / d < 1
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(body, 1, "one pass")
assert_eq(d, 100, "the retry ran the test, not d -= 1")
goto ru2_done
ru2:
  hits += 1
  d = 100
  resume
ru2_done:

test_case("loop tail/for increment overflows at top level: resume next leaves the loop")
rem i% = big%: pass 1 (n = 1); increment -> big% + 1 = the largest int%,
rem which is <= the limit: pass 2 (n = 2); increment overflows: fault.
rem resume next -> after the loop; i% keeps the largest int%.
n = 0
hits = 0
after = 0
on error goto fi1
for i% = big% to 9223372036854775807
  n += 1
next
after = 1
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(n, 2, "two passes")
assert_eq(after, 1, "continued after the loop")
assert_int(i%, 9223372036854775807, "the failed increment left i% alone")
goto fi1_done
fi1:
  hits += 1
  resume next
fi1_done:

test_case("loop tail/for increment overflows: resume retries the increment")
rem As above to the first fault (n = 2). The handler puts i% back to
rem big% and resumes: the increment runs again (-> largest int%), the
rem limit check passes, pass 3 (n = 3), the increment faults again and
rem the second handler entry says resume next.
n = 0
hits = 0
on error goto fi2
for i% = big% to 9223372036854775807
  n += 1
next
on error goto 0
assert_eq(hits, 2, "two faults")
assert_eq(n, 3, "three passes: the retried increment let one more run")
goto fi2_done
fi2:
  hits += 1
  if hits = 1 then
    i% = big%
    resume
  endif
  resume next
fi2_done:

test_case("loop tail/continue lands on the faulting increment")
rem Every pass leaves by `continue` from inside an if, so the faulting
rem increment is reached from `continue`, not from the body's last line.
rem Two passes (n = 2, m = 0), then the increment overflows.
n = 0
m = 0
hits = 0
after = 0
on error goto fi3
for i% = big% to 9223372036854775807
  n += 1
  if n > 0 then
    continue
  endif
  m += 1
next
after = 1
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(n, 2, "two passes")
assert_eq(m, 0, "continue skipped the rest every time")
assert_eq(after, 1, "continued after the loop")
goto fi3_done
fi3:
  hits += 1
  resume next
fi3_done:

test_case("loop tail/for limit check faults: resume retries the check, not the header")
rem A string loop variable against a numeric limit cannot be compared:
rem the limit check faults before the first pass. The start value comes
rem from start$(), which counts its calls. The handler retries twice and
rem then says resume next. Retrying the CHECK calls start$() once in all;
rem retrying the whole `for` line called it three times.
starts = 0
body = 0
hits = 0
after = 0
on error goto fl1
for s$ = start$() to 3
  body += 1
next
after = 1
on error goto 0
assert_eq(hits, 3, "three faults: two retries and a resume next")
assert_eq(starts, 1, "the header ran once")
assert_eq(body, 0, "the body never ran")
assert_eq(after, 1, "continued after the loop")
goto fl1_done
fl1:
  hits += 1
  if hits < 3 then resume
  resume next
fl1_done:

test_case("loop tail/inside a function: the for increment overflow")
rem countup() runs the same two passes and then returns n * 10 = 20.
rem Before, resume next went to the loop tail, re-faulted, and the second
rem resume next ended the function: it returned 0, its default.
hits = 0
on error goto fn1
r = countup()
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(r, 20, "the function ran on after the loop and returned n * 10")
goto fn1_done
fn1:
  hits += 1
  resume next
fn1_done:

test_case("loop tail/inside a function: the while test")
rem halves(3): pass 1 tests 12/3 = 4 > 1, k = 1, d = 2; pass 2 12/2 = 6 > 1,
rem k = 2, d = 1; pass 3 12/1 = 12 > 1, k = 3, d = 0; pass 4 faults.
rem resume next -> after the loop: the function returns k + 100 = 103.
hits = 0
on error goto fn2
r = halves(3)
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(r, 103, "returned k + 100 from after the loop")
goto fn2_done
fn2:
  hits += 1
  resume next
fn2_done:

test_case("loop tail/inside a function: repeat-until retried")
rem untilfix(): pass 1 body k = 1, d = 0; the test 5/d faults; the handler
rem sets the GLOBAL fixd = 1 and resumes; the retried test reads 5/1 = 5 > 2
rem (the test divides by d + fixd): true, the loop ends; return k = 1.
rem Re-running the body's last line (d -= 1, d = -1) gave 5/0 again.
hits = 0
fixd = 0
on error goto fn3
r = untilfix()
on error goto 0
assert_eq(hits, 1, "one fault")
assert_eq(r, 1, "one pass, then the retried test ended the loop")
goto fn3_done
fn3:
  hits += 1
  fixd = 1
  resume
fn3_done:

test_case("loop tail/nested: an inner while test faults on every outer pass")
rem Outer k = 1..3. Inner: d = 2, two passes (10/2, 10/1), then 10/0.
rem resume next leaves the INNER loop only; the outer runs on.
rem 3 faults, 3 outer passes, 2 * 3 = 6 inner passes.
outer = 0
inner = 0
hits = 0
on error goto ne1
for k = 1 to 3
  outer += 1
  d = 2
  while 10 / d > 1
    inner += 1
    d -= 1
  endwhile
next
on error goto 0
assert_eq(hits, 3, "one fault per outer pass")
assert_eq(outer, 3, "the outer loop ran all three passes")
assert_eq(inner, 6, "two inner passes each time")
goto ne1_done
ne1:
  hits += 1
  resume next
ne1_done:

test_case("loop tail/nested: an inner increment fault leaves only the inner loop")
rem Outer while w < 2. Inner for: two passes, then the increment overflows.
rem resume next leaves the inner for; the outer while tests again.
rem 2 outer passes, 2 faults, 4 inner passes.
w = 0
inner = 0
hits = 0
on error goto ne2
while w < 2
  w += 1
  for i% = big% to 9223372036854775807
    inner += 1
  next
endwhile
on error goto 0
assert_eq(hits, 2, "one fault per outer pass")
assert_eq(w, 2, "two outer passes")
assert_eq(inner, 4, "two inner passes each time")
goto ne2_done
ne2:
  hits += 1
  resume next
ne2_done:

test_case("loop tail/on error call: a handler answering 0 continues after the loop")
rem The function handler's 0 means resume next; same arithmetic as the
rem first while case.
callhits = 0
d = 2
body = 0
after = 0
on error call loopfix
while 10 / d > 1
  body += 1
  d -= 1
endwhile
after = 1
on error goto 0
assert_eq(callhits, 1, "the handler function was called once")
assert_eq(body, 2, "two passes")
assert_eq(after, 1, "continued after the loop")

test_case("loop tail/the rest of the file still runs")
rem The old top-level failure ended the program here at exit 0; this case
rem existing in the golden's passed: count is part of what it pins.
assert_true(1 = 1, "reached the end of the file")

function start$()
  starts += 1
  return "a"
endfunction

function countup() local n, i%
  n = 0
  for i% = 9223372036854775806 to 9223372036854775807
    n += 1
  next
  return n * 10
endfunction

function halves(d) local k
  k = 0
  while 12 / d > 1
    k += 1
    d -= 1
  endwhile
  return k + 100
endfunction

function untilfix() local k, d
  k = 0
  d = 1
  repeat
    rem A bound, so the old behaviour ends instead of looping for ever.
    if k >= 5 then break
    k += 1
    d -= 1
  until 5 / (d + fixd) > 2
  return k
endfunction

function loopfix(code, msg$)
  callhits += 1
  return 0
endfunction
