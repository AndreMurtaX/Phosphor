rem Fails on purpose: the exit code must be the program's, not the host's
rem opinion of it. A runner that reports every run as a success is no runner.
println "about to fail"
x% = 1 / 0
