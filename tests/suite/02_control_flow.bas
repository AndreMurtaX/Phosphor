rem ---------------------------------------------------------------
rem Control flow: IF, WHILE, DO/LOOP, REPEAT, FOR, SELECT CASE,
rem GOTO/GOSUB, BREAK/CONTINUE, ON..GOTO.
rem ---------------------------------------------------------------

test_case("flow/if-else")
r = 0
if 1 = 1 then
  r = 1
else
  r = 2
endif
assert_eq(r, 1, "then branch")

r = 0
if 1 = 2 then
  r = 1
else
  r = 2
endif
assert_eq(r, 2, "else branch")

test_case("flow/if-inline")
r = 0
if 5 > 3 then r = 99
assert_eq(r, 99)

test_case("flow/if-nested")
r = 0
if 1 = 1 then
  if 2 = 2 then
    r = 7
  endif
endif
assert_eq(r, 7)

test_case("flow/while")
i = 0
s = 0
while i < 5
  i = i + 1
  s = s + i
endwhile
assert_eq(i, 5, "counter")
assert_eq(s, 15, "sum 1..5")

test_case("flow/while-never-runs")
i = 0
while i > 10
  i = i + 1
endwhile
assert_eq(i, 0)

test_case("flow/do-loop")
i = 0
do while i < 3
  i = i + 1
loop
assert_eq(i, 3)

test_case("flow/repeat-until")
i = 0
repeat
  i = i + 1
until i >= 4
assert_eq(i, 4, "repeat body always runs at least once")

test_case("flow/for-next")
s = 0
for i = 1 to 5
  s = s + i
next
assert_eq(s, 15)

test_case("flow/for-step")
s = 0
for i = 10 to 1 step -2
  s = s + i
next
assert_eq(s, 30, "10+8+6+4+2")

s = 0
for i = 0 to 10 step 5
  s = s + i
next
assert_eq(s, 15, "0+5+10")

test_case("flow/for-nested")
c = 0
for i = 1 to 3
  for j = 1 to 4
    c = c + 1
  next
next
assert_eq(c, 12)

test_case("flow/break")
c = 0
for i = 1 to 100
  if i > 5 then break
  c = c + 1
next
assert_eq(c, 5)

test_case("flow/continue")
s = 0
for i = 1 to 6
  if i mod 2 = 0 then continue
  s = s + i
next
assert_eq(s, 9, "1+3+5")

test_case("flow/select-case")
n = 2
r = 0
select case n
  case 1
    r = 10
  case 2
    r = 20
  case 3
    r = 30
endselect
assert_eq(r, 20)

n = 99
r = 0
select case n
  case 1
    r = 10
  case else
    r = -1
endselect
assert_eq(r, -1, "case else")

test_case("flow/gosub")
g = 0
gosub 1000
assert_eq(g, 42)

test_case("flow/goto")
h = 0
goto 2000
h = -1
2000 h = 5
assert_eq(h, 5, "the skipped line must not run")


test_case("control/break is scoped to the function being compiled")
rem A function can be DEFINED inside a loop body -- ParseStatement accepts one
rem wherever a statement may appear. Its body used to be compiled with the
rem ENCLOSING loop still counted, so a `break` in it was fixed up to jump past
rem that loop, with the function's frame still pushed: the tail of the program
rem ran for ever. tests/negative/31 pins the refusal. These pin what must stay
rem legal, because zeroing the depth for a function body would be easy to do in
rem a way that took the working cases with it.
assert_eq(firstover(3), 4, "break in a loop the function declares itself")
assert_eq(evens(6), 12, "and continue in one")
brk = 0
while brk < 100
  brk += 1
  if brk = 5 then
    break
  end if
endwhile
assert_eq(brk, 5, "break in an ordinary top-level loop")
rem THE ONE THAT PROVES THE DEPTH IS RESTORED and not merely discarded: this
rem loop's own break must still find this loop, even though its body defines a
rem function in between.
outer = 0
while outer < 100
  function definedinside()
    return 0
  endfunction
  outer += 1
  if outer = 7 then
    break
  end if
endwhile
assert_eq(outer, 7, "an outer loop whose body defines a function still breaks")

rem AND THE ONE THAT PROVES THE DEPTH IS NOT THE STATE. The assertion above
rem passed while the defect below was live, because `definedinside` contains no
rem loop of its own. The fixup lists are INDEXED BY the depth, and PushLoop
rem clears the slot it is about to use -- so a loop inside the function body,
rem pushing at depth 0, erased the ENCLOSING loop's recorded break sites. The
rem outer break then kept its placeholder operand and jumped to instruction 0,
rem restarting the whole program with no error and no exit: five seconds of that
rem is five megabytes of output. Every assertion here needs the inner LOOP.
withloop = 0
while withloop < 100
  withloop += 1
  if withloop = 3 then
    break
  end if
  function hasloop() local j
    j = 0
    while j < 4
      j += 1
    endwhile
    return j
  endfunction
  rem The mirror. PopLoop only decrements, so after this function's loop pops,
  rem its already-patched break sites were still sitting in the slot -- and the
  rem enclosing loop re-patched them to its own exit, jumping out of the frame.
  function ownbreak() local j
    j = 0
    while j < 9
      j += 1
      if j = 3 then
        break
      end if
    endwhile
    return j
  endfunction
endwhile
assert_eq(withloop, 3, "an outer break survives a loop inside a function in its body")
assert_eq(hasloop(), 4, "and that inner loop still runs to its own end")
assert_eq(ownbreak(), 3, "a break inside a function defined in a loop is the function's own")

function firstover(limit) local i
  for i = 1 to 100
    if i > limit then
      break
    end if
  next
  return i
endfunction

function evens(n) local i, s
  for i = 1 to n
    if (i mod 2) <> 0 then
      continue
    end if
    s = s + i
  next
  return s
endfunction

end

1000 g = 42
return
