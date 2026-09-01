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

end

1000 g = 42
return
