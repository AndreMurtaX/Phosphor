rem An unrecognised backslash escape is a lexer error rather than being
rem passed through, so a typo in an escape sequence is caught at compile
rem time instead of silently changing the string.
x$ = "a\zb"
print x$
