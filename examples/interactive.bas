rem interactive.bas -- console INPUT, the classic way.
rem
rem Reads answers from the keyboard with INPUT (typed values) and LINE INPUT (a
rem whole line), then prints a summary. Run it and type at the prompts:
rem
rem   phosphor run examples/interactive.bas
rem
rem INPUT prints a "? " prompt; a string prompt with ';' keeps it, with ',' drops
rem it. INPUT coerces each field to the variable's type, so age% must be a number.

input "Your name"; name$
input "Your age", age%
input "Two numbers, comma-separated"; a, b
line input "One free-form line: " ; note$

println ""
println "Hello, " + name$ + "!"
println using "Next year you will be ###."; age% + 1
println using "Your numbers add to #,###."; a + b
println "You wrote: " + note$
