rem A GUI test file that HANGS, on purpose: it enters the message loop and
rem nothing ever calls app_quit(). It is not in the GUI corpus -- a file that
rem must fail cannot sit in a list of files that must pass -- and
rem scripts/test-gui.{ps1,sh} run it by name, with a short watchdog, to pin
rem what the runner does when a test hangs (ledger d56).
rem
rem What must happen: the case before the hang is counted, the watchdog
rem reports the hang as a failure, and the process ENDS -- exit 4, the
rem summary written, within seconds. What used to happen: the watchdog
rem called Application.Terminate, which the LCL never clears, so app_run()
rem returned, the case below RAN, and every later app_run() in the file
rem returned at once without dispatching anything -- one hang reported as a
rem screenful of failures about other things.
rem
rem AND THE REPORT AT THE HANG READS THE LEDGER (2026-10-08, second
rem adversarial round). An answer is queued here and never used; the
rem watchdog's report used to name only the hang, though what the ledger
rem holds may be why a file hung. So the failures are two -- the hang and
rem the unused answer -- and stderr must name the second.
test_case("watchdog/before the hang")
assert_eq(1, 1, "this ran before the loop was entered")
x = gui_test_answer(1, "queued before the hang, never used")
f@ = form@("hang", 120, 80)
app_run()
test_case("watchdog/after the hang")
assert_eq(1, 1, "this must never run: the hang ends the file")
