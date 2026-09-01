rem ---------------------------------------------------------------
rem ELSE on the same line as its IF.
rem
rem `if C then A else B` compiles to the same shape a block IF does:
rem a conditional jump to B, then A, then a jump past B.
rem
rem The whole risk of this feature is BINDING -- which IF an ELSE
rem belongs to. An ELSE binds to a one-line IF only when the two are
rem on the same source line, and the count of open one-line IFs is
rem reset at every line break. The section below named after
rem space_invaders is the case that made this a rule rather than an
rem assumption: it exists in Demos/space_invaders.bas and the wrong
rem binding inverts its logic silently rather than failing.
rem ---------------------------------------------------------------

test_case("inline-else/basic")
r = 0
if 1 = 1 then r = 10 else r = 20
assert_eq(r, 10, "the true branch ran")
if 1 = 2 then r = 10 else r = 20
assert_eq(r, 20, "and the false branch, when it should")

test_case("inline-else/only-one-branch-runs")
rem Falling through from the true branch into the false one is the
rem failure this feature can have, and it is silent: the answer is
rem simply the false branch's every time.
count = 0
if 1 = 1 then count = count + 1 else count = count + 100
assert_eq(count, 1, "the true branch did not fall into the false one")
count = 0
if 1 = 2 then count = count + 1 else count = count + 100
assert_eq(count, 100, "and the false branch did not run the true one first")

test_case("inline-else/strings")
s$ = ""
if 1 = 1 then s$ = "yes" else s$ = "no"
assert_eq(s$, "yes", "string assignment in both branches")
if 1 = 2 then s$ = "yes" else s$ = "no"
assert_eq(s$, "no", "the other way")

test_case("inline-else/calls")
counter = 0
if 1 = 1 then bump(1) else bump(100)
assert_eq(counter, 1, "a call in the true branch")
if 1 = 2 then bump(1) else bump(100)
assert_eq(counter, 101, "and in the false branch")

test_case("inline-else/inside-a-loop")
total = 0
for i = 1 to 10
  if i mod 2 = 0 then total = total + i else total = total - i
next
assert_eq(total, 5, "even added, odd subtracted, over ten")

test_case("inline-else/no-else-still-works")
rem A one-line IF without an ELSE must be exactly what it always was.
r = 0
if 1 = 1 then r = 1
assert_eq(r, 1, "taken")
if 1 = 2 then r = 99
assert_eq(r, 1, "and not taken")

test_case("inline-else/nested-on-one-line")
rem Two one-line IFs on one line. The ELSE belongs to the INNER one,
rem and the outer IF must skip the whole thing when it is false.
r = 0
if 1 = 1 then if 1 = 2 then r = 1 else r = 2
assert_eq(r, 2, "inner false, so the inner else ran")
r = 0
if 1 = 2 then if 1 = 1 then r = 1 else r = 2
assert_eq(r, 0, "outer false, so neither branch ran")

test_case("inline-else/space-invaders-shape")
rem Straight out of Demos/space_invaders.bas: a block IF whose true
rem branch is a one-line IF, followed by an ELSE that belongs to the
rem OUTER one. If the inline count survives the line break, that ELSE
rem binds to the inner IF instead, inverting the logic and leaving
rem `end if` matched against nothing.
dirX = 1
near = 0
drop = 0
if dirX > 0 then
  if near = 1 then drop = 1
else
  if near = 0 then drop = 2
end if
assert_eq(drop, 0, "dirX positive, near false: neither branch set drop")

dirX = 1
near = 1
drop = 0
if dirX > 0 then
  if near = 1 then drop = 1
else
  if near = 0 then drop = 2
end if
assert_eq(drop, 1, "dirX positive, near true: the inner IF of the TRUE branch")

dirX = -1
near = 0
drop = 0
if dirX > 0 then
  if near = 1 then drop = 1
else
  if near = 0 then drop = 2
end if
assert_eq(drop, 2, "dirX negative: the ELSE belongs to the outer IF")

dirX = -1
near = 1
drop = 0
if dirX > 0 then
  if near = 1 then drop = 1
else
  if near = 0 then drop = 2
end if
assert_eq(drop, 0, "dirX negative, near true: the outer else's inner IF is false")

test_case("inline-else/block-else-untouched")
r = 0
if 1 = 2 then
  r = 1
else
  r = 2
end if
assert_eq(r, 2, "a plain block ELSE still works")

if 1 = 1 then
  r = 3
else
  r = 4
end if
assert_eq(r, 3, "both ways round")

test_case("inline-else/else-if-chain-untouched")
r = 0
if 1 = 2 then
  r = 1
else if 1 = 1 then
  r = 2
else
  r = 3
end if
assert_eq(r, 2, "ELSE IF chains are a different construction and unaffected")

function bump(by)
  counter = counter + by
  return
endfunction
