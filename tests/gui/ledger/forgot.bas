rem ---------------------------------------------------------------
rem THIS FILE MUST FAIL. test-gui.{ps1,sh} run it by name, apart from the
rem corpus, and demand exit 1, "passed: 1 / failed: 4" and the four
rem reasons below on stderr.
rem
rem The GUI runner answers every modal from a queue (gui_test_answer) and
rem never shows one. It said a forgotten answer "fails on the count", and
rem nothing read the count: three unanswered modals ended `passed: 3`
rem (an adversarial review, 2026-10-08). Its ledger, read when a file
rem ends, now fails the run for each of the three ways a queue can be
rem wrong -- and each is provoked once here:
rem   * a modal asked with no answer queued (cancelled, never shown);
rem   * an answer taken by a different kind of modal than it named;
rem   * an answer queued and never used.
rem
rem The same review found an event handler's fault was SWALLOWED: the
rem GUI records it as gui_error() 2 and carries on, so an assertion
rem after the faulting line in a handler simply never ran, and the file
rem passed. The ledger now counts handler faults too. One fault here is
rem acknowledged with gui_test_handler_faults() -- that is the one
rem passing assertion, and it must NOT fail the run -- and a second is
rem left unacknowledged, which must.
rem ---------------------------------------------------------------

zero = 0

x = msgbox("asked, and nothing was queued for it")
x = gui_test_answer(1, "", "input")
x = msgbox("takes the answer queued for an input")
x = gui_test_answer(1, "never used")

f@ = form@()
b@ = button@(f@)
button_onclick@(b@, "on_fault")
button_click@(b@)
assert_eq(gui_test_handler_faults(), 1, "a fault provoked on purpose is acknowledged")
button_click@(b@)

function on_fault(sender@)
  y = 1 / zero
  return 0
endfunction
