rem AN `on error call` HANDLER WHOSE PARAMETERS DO NOT TAKE (number, string) IS
rem REFUSED -- AND THE REFUSAL STILL NAMES THE FAULT IT WAS CALLED FOR.
rem
rem The VM calls the handler with the error code and the message. Since
rem 2026-10-11 an argument is stored into its parameter as an assignment would
rem store it, so `msg` -- a number name -- refuses the message string, and the
rem program stops: language-reference.md, Error handling, says a handler must
rem take (code, msg$). The first version of that refusal reported only
rem "cannot pass string to number parameter msg of handler", and the division
rem by zero that the handler had been called for was never reported at all.
rem The diagnostic now ends "-- while handling: division by zero (line 13)".
on error call handler
x = 5 / 0
println "NEVER"
end

function handler(code, msg)
  println "NEVER: the handler ran"
  return 0
end function
