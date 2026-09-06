rem A program with no window at all, run THROUGH `phosphor --gui`.
rem
rem That is the point: what is under test is the HANDOFF -- that the console
rem host finds phosphorgui, spawns it, lets its output through unchanged and
rem gives back its exit code. A window would only get in the way of seeing it.
println "handoff ok"
