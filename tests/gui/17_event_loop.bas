rem ---------------------------------------------------------------
rem THE REAL MESSAGE LOOP. Every other GUI file here fires events
rem synchronously -- button_click(b@) calls the handler directly --
rem which proves the wiring and never starts a loop. So app_run(),
rem the verb every interactive Phosphor GUI program ends with, and
rem app_quit(), the only way back out of it, had never run.
rem examples/gui_demo.bas calls app_run() and is compile-checked; a
rem program that enters the loop and cannot leave it would still have
rem passed everything.
rem
rem This file enters the loop for real. A timer fires INSIDE it -- so
rem the widgetset is dispatching, not this script -- the handler asks
rem to quit, and app_run() returns. If it did not return, the runner's
rem watchdog reports a failure and ends the process, because a suite
rem that hangs tells you nothing and blocks everything behind it.
rem ---------------------------------------------------------------

ticks = 0
seen$ = ""

function on_tick(sender@)
  ticks = ticks + 1
  rem The sender is the live timer handle: stopping it through the handle
  rem we were handed is what proves it is the timer and not a copy.
  timer_stop@(sender@)
  seen$ = seen$ + "t"
  app_quit()
  return 0
endfunction

test_case("eventloop/a timer fires inside app_run and app_quit ends it")

f@ = form@()
form_show(f@)

t@ = timer@()
timer_interval@(t@, 30)
timer_ontimer@(t@, "on_tick")
timer_start@(t@)
assert_eq(gui_error(), 0, "the timer was wired with no error")
assert_eq(timer_enabled(t@), 1, "and is running before the loop starts")

rem Blocks here until the handler calls app_quit(). Reaching the next line
rem at all is half the assertion.
app_run()

assert_eq(ticks, 1, "the timer handler ran inside the real message loop")
assert_eq(seen$, "t", "and ran exactly once")
assert_eq(timer_enabled(t@), 0, "the handler stopped the timer through the sender it was given")

test_case("eventloop/the loop can be entered again")

rem app_quit() must leave the application usable, not poisoned: a host that
rem runs one script and then another (the embedding case) would otherwise get
rem a loop that returns immediately for ever after.
ticks = 0
seen$ = ""
timer_interval@(t@, 30)
timer_start@(t@)
app_run()
assert_eq(ticks, 1, "a second app_run also dispatched the timer")

form_close@(f@)
