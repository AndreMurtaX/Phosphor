rem eof/lof/loc/input$ are parsed as special forms because they take a #channel.
rem A function with one of those names used to compile cleanly and then never be
rem called: every call site was rewritten into the file opcode instead, so the
rem body below was unreachable and eof(1) answered a file position. Silently
rem unreachable code is worse than a rejected name.
function eof(kind)
  return kind * 100
endfunction
println eof(1)
