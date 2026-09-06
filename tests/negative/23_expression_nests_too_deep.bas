rem A recursive-descent parser re-enters ParseExpr for every '(' and every call
rem argument, several stack frames deeper each time. Fifty thousand of them --
rem seconds of typing, or one line of a generator gone wrong -- exhausted the
rem process stack and KILLED the process: exit 139, STATUS_STACK_OVERFLOW, and
rem not one byte on stdout or stderr. A stack overflow is not an exception, so
rem the host's crash guard never saw it either. There is now a depth ceiling and
rem this is a compile error like any other.
rem
rem 300 levels: far past anything a person writes, and far short of a crash.
x = ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
println x
