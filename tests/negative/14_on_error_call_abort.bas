rem an `on error call` handler that returns non-zero aborts the program: the
rem error is re-raised rather than swallowed, so the program is rejected.
on error call fatal
x = 1 / 0
end

function fatal(code, msg$)
  return 1
end function
