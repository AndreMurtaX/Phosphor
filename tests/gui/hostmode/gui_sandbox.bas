rem A GUI program that ASKS THE SANDBOX something, for the hostmode case that
rem checks --sandbox reaches a GUI run (ledger d51).
rem
rem That case used to run gui.bas, which touches no path, so it passed with the
rem right root, a bogus one, or none at all -- a test of the sandbox that could
rem not fail. This one makes a form, so the GUI functions must be registered,
rem and then asks two things only a bound sandbox answers:
rem   * which root is bound -- the runner compares it with the cage it passed;
rem   * whether ".." is visible -- the parent of wherever the program stands
rem     always exists, so an unconfined run answers 1, and a run confined to
rem     the cage answers 0, because ".." is outside it.
rem It writes nothing: a probe of the sandbox that wrote outside it on a run
rem with no sandbox would be the escape it exists to rule out.
f@ = form@()
form_caption@(f@, "registrado")
println "gui ok: " + form_caption$(f@)
println "root=" + sandboxroot$() + "|"
println "parent visible: " + str$(dir_exists(".."))
