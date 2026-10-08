rem ---------------------------------------------------------------
rem A NETWORK WAIT IS CHARGED TO THE RUN'S BUDGET (2026-10-08, second
rem adversarial round).
rem
rem A budget measured in steps did not move while the network waited, so
rem every request was handed the whole remaining allowance again: two
rem requests to a trickling peer held a run 51 s on a 25.6 s budget. A
rem request is now priced as pause() prices a wait -- BudgetUnitsPerMs a
rem millisecond -- and the charge that spends the budget makes the verb
rem answer the budget's own refusal, as pause() does.
rem
rem The arithmetic, not a run, sets the expectations. The runner's budget
rem is worth 25600 ms of waiting; http_test_spend(19000) leaves about
rem 6600. The peer's /trickle takes four seconds, so the FIRST request
rem completes (20 bytes) and leaves about 2600; the SECOND would need
rem four more, is cut at the deadline, and its charge spends the budget.
rem Uncharged, the second would be handed 6600 again and complete.
rem ---------------------------------------------------------------

v6$ = server_url_ipv6$("plain")
raised = 0
msg$ = ""

test_case("budget-wait/a request's wait is charged, and the one that spends the budget is refused")
assert_eq(http_test_spend(19000), 1, "the budget holds after 19 s of it are spent")
on error goto trapped
b$ = http_get$(v6$ + "/trickle")
on error goto 0
assert_eq(raised, 0, "the first request fits in what is left")
assert_eq(len(b$), 20, "and its whole body arrives")
on error goto trapped
b$ = http_get$(v6$ + "/trickle")
on error goto 0
assert_eq(raised, 1, "the second, charged with the first's wait, spends the budget and is refused")
rem Compared whole, by the VM's own =: once the budget is spent every
rem library call that charges is refused too, instr among them.
rem BudgetRefusal writes "<name>: <why>", and the why for a step budget
rem is "the run has spent its step budget of N inside library calls".
assert_true(msg$ = "http_get$: the run has spent its step budget of 1000000 inside library calls", "with the budget's own message, as pause() gives")
raised = 0
t0 = now()
on error goto trapped
s = http_status(v6$ + "/")
on error goto 0
assert_eq(raised, 1, "and a request after that is refused too")
assert_true(millisecondsbetween(now(), t0) < 500, "without dialling anything")
end

trapped:
raised = 1
msg$ = errmsg$()
resume next
