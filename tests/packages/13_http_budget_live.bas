rem ---------------------------------------------------------------
rem THE HTTP RUNNER ARMS THE BUDGET TOO (ledger n17).
rem
rem A file whose name contains "http" runs under phosphorhttptest, a
rem separate host from the one 12_budget_live.bas asks, so it is asked
rem separately -- the same gap fixed in one runner would have stayed
rem open in the other. It never contacts the server the runner stands
rem up. test_budget_active() answers 1 when the run's library budget is
rem armed and 0 when it is inert.
rem ---------------------------------------------------------------

test_case("budget/the http runner arms the library budget")
assert_eq(test_budget_active(), 1, "the run's budget is live, not inert")
