rem callfunc naming a routine that does not exist is a runtime error, not a
rem silent no-op: the program is rejected rather than continuing on a value it
rem never produced. (An event never binds to an undefined handler either.)
x = callfunc("no_such_routine", 1)
