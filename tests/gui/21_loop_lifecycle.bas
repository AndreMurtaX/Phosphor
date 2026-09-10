rem ---------------------------------------------------------------
rem THE MESSAGE LOOP'S LIFECYCLE: entering it, leaving it, and
rem entering it again.
rem
rem Three defects lived here, all of them found by the 2026-09-06
rem sweep and none of them visible to any test, because nothing
rem asserted what app_run does after it has been left once.
rem
rem 1. app_quit() did not wake app_run(). The loop was one call to
rem    Application.HandleMessage -- dispatch, then block in Idle --
rem    with nothing in between, so a script's app_quit, which always
rem    runs inside a dispatched event, set the flag and then walked
rem    straight into a wait for a message that never came. With no
rem    window shown it hung 5 runs out of 5.
rem
rem 2. Closing ANY window called Application.Terminate, so a program
rem    showing two windows lost its loop when either was closed --
rem    the other still open and still expected to work.
rem
rem 3. That flag has no public way to be cleared, so every later
rem    app_run() in the process returned instantly having dispatched
rem    nothing. The playbook's round 28 records this exact defect as
rem    fixed for app_quit, and it was: the fix landed there and this
rem    second caller kept doing it. THE SECOND CALL IS THE TEST.
rem
rem The mirror is the last case and it matters as much: closing the
rem LAST window must still end the loop, or one hang has been traded
rem for another.
rem ---------------------------------------------------------------

test_case("gui/loop: app_quit leaves it with no window shown")
q = 0
qt@ = timer@()
timer_interval@(qt@, 40)
timer_ontimer@(qt@, "quitstep")
timer_start@(qt@)
app_run()
assert_true(q >= 1, "the timer ran and app_quit was reached")

test_case("gui/loop: closing one of two windows keeps it running")
n = 0
a@ = form@("window A", 300, 200)
b@ = form@("window B", 300, 200)
form_show@(a@)
form_show@(b@)
t@ = timer@()
timer_interval@(t@, 40)
timer_ontimer@(t@, "twostep")
timer_start@(t@)
app_run()
assert_true(n >= 4, "the loop outlived the close of one window")
assert_eq(form_visible(a@), 0, "A was closed")
assert_eq(form_visible(b@), 1, "B is still shown")

test_case("gui/loop: and a SECOND app_run still enters it")
n = 0
timer_start@(t@)
app_run()
assert_true(n >= 4, "the second call dispatched events too")

test_case("gui/loop: closing the LAST window ends it")
m = 0
c@ = form@("only window", 300, 200)
form_show@(c@)
form_close@(b@)
lt@ = timer@()
timer_interval@(lt@, 40)
timer_ontimer@(lt@, "laststep")
timer_start@(lt@)
app_run()
assert_true(m >= 2, "the loop ran")
assert_eq(form_visible(c@), 0, "and the last window closed, which ended it")

function quitstep(sender@)
  q = q + 1
  timer_stop@(sender@)
  app_quit()
  return 0
end function

function twostep(sender@)
  n = n + 1
  if n = 2 then
    form_close@(a@)
  end if
  if n = 4 then
    timer_stop@(sender@)
    app_quit()
  end if
  return 0
end function

function laststep(sender@)
  m = m + 1
  if m = 2 then
    timer_stop@(sender@)
    form_close@(c@)
  end if
  return 0
end function
