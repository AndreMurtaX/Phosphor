rem ---------------------------------------------------------------
rem EVERY PACKAGE TEST RUNS UNDER A LIVE BUDGET (ledger n17).
rem
rem zip, gzip, base64 and sqlite each ask the library budget before a
rem loop or an allocation sized by the script. That question is only a
rem question when a ceiling is installed: with none, the budget is
rem inert and BudgetAllows/BudgetCharge answer "go ahead" without
rem measuring anything. The package runner used to install none, so a
rem meter that charged nothing -- or charged wildly too much -- could
rem not fail one package test on either OS.
rem
rem The runner now installs the ceiling docs/embedding.md prescribes,
rem MaxSteps = 1000000, so every file in this corpus also proves its
rem package works within the budget an embedder is told to set. This
rem file pins that the ceiling is there: test_budget_active() is a
rem test-only name (tests/PhosphorTestLib.pas) that answers 1 when the
rem run's budget is armed and 0 when it is inert.
rem ---------------------------------------------------------------

test_case("budget/the package runner arms the library budget")
assert_eq(test_budget_active(), 1, "the run's budget is live, not inert")
