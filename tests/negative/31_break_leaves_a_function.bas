rem A BREAK inside a function that is DEFINED inside a loop body.
rem
rem ParseStatement accepts a `function` wherever a statement may appear, and
rem ParseBlockUntil calls ParseStatement -- so a function can be defined inside a
rem loop. Its body was then compiled with the compiler still counting the
rem ENCLOSING loop, and `break` was added to that loop's fixup list. PatchBreaks
rem pointed the jump at the instruction after `endwhile`.
rem
rem What that produced: calling f() jumped past the loop with f's activation frame
rem still pushed, so every statement after the loop ran again, and again. The
rem reported program printed its tail 262,146 times in six seconds and never
rem stopped -- no error, no exit code, nothing to read. A hang is worse than a
rem crash for exactly that reason.
rem
rem MUST fail. This is the GOTO defect of tests/negative/28 wearing different
rem syntax, and one sentence closes both: the compiler must scope control-flow
rem targets to the FUNCTION BEING COMPILED. The body is now compiled at loop
rem depth zero, so `break` in it has no loop to bind to and meets the check that
rem was already there.
rem
rem What is NOT refused, and tests/suite/02_control_flow.bas pins it: a `break` or
rem a `continue` in a loop the function DECLARES ITSELF, a `break` in an ordinary
rem top-level loop, and -- the one that proves the depth is restored rather than
rem discarded -- a `break` belonging to an outer loop whose body happens to define
rem a function.
i = 0
while i < 2
  function f()
    break
  endfunction
  i += 1
endwhile
println "loop done i="; i
println f()
println "after"
