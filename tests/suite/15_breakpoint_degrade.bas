rem ---------------------------------------------------------------
rem BREAKPOINT must never park the VM when nobody can answer it.
rem
rem The engine reports a breakpoint's frame through a single host seam,
rem OnBreakpoint, and then continues -- always. It calls the seam only
rem while tracing is on AND a callback is installed; a headless host
rem installs none, so BREAKPOINT degrades to a report-and-continue that
rem touches nothing. The engine never waits for an answer, so a host that
rem cannot show a modal (a background thread, a phone) cannot deadlock.
rem
rem If it ever waited instead, this file would stop producing output and
rem the runner would kill it on timeout, which is the failure this guards.
rem ---------------------------------------------------------------

test_case("breakpoint/trace-off-is-skipped")
n = 7
s$ = "frame"
rem With trace off the command does nothing, but still has to pop the
rem message and the operands it was given.
breakpoint "ignored while trace is off", n, s$
assert_eq(n, 7, "trace off leaves the numeric operand untouched")
assert_eq(s$, "frame", "and the string operand as well")

test_case("breakpoint/no-host-continues")
trace 1
breakpoint "degrade check", n, s$
trace 0
assert_eq(n, 7, "execution continued past the breakpoint")
assert_eq(s$, "frame", "and the operands were popped in the right order")

test_case("breakpoint/no-variables")
trace 1
breakpoint "bare breakpoint"
trace 0
assert_true(1, "a breakpoint carrying no variables also continues")
