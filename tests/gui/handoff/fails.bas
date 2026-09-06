rem Fails on purpose: the handoff must give back the FAILING exit code, not
rem its own. A wrapper that swallows the child's status is a wrapper that
rem reports every run as a success.
println "about to fail"
x% = 1 / 0
