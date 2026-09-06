rem Nested BLOCKS, which recurse on a path that never touches ParseExpr.
rem
rem A depth ceiling was added for parentheses and written in the belief that
rem ParseExpr is "the one place a nested expression passes through". Block
rem nesting goes ParseStatement -> ParseBlockUntil -> ParseStatement and never
rem passes through it at all, so it stayed unbounded: 20000 nested IFs -- one
rem loop of a code generator -- exhausted the process stack and KILLED the
rem process (0xC0000005 on Windows, exit 139 on Linux with nothing printed at
rem all). A stack overflow is not an exception, so the crash guard the host
rem installs never saw it either.
rem
rem 300 levels: past anything a person writes, and FAR short of the crash. That
rem gap is the point of the file -- before the fix this program compiled and ran
rem and exited 0, so it fails without the fix instead of being "rejected" by a
rem crash that would have gone green.
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
if 1 = 1 then
print 7
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
endif
