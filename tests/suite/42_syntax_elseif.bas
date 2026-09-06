rem ---------------------------------------------------------------
rem ELSEIF written as one word.
rem
rem It builds the chain `else if` already builds, down to the same
rem two markers, so the resolver never learns which spelling was
rem used. WEND beside ENDWHILE and NEXT beside ENDFOR already make
rem doubled spellings this language's habit.
rem
rem The word is recognised CONTEXTUALLY -- at the start of a
rem statement, and only when it is not being assigned to. It is not
rem a lexer keyword and must never become one: the lexer decides an
rem identifier's kind before it looks for a '(', so a word in that
rem table stops being available as a function name as well as a
rem variable name. `elseif = 5` compiles and runs on the shipped
rem binary, and the section at the end proves it still does.
rem ---------------------------------------------------------------

test_case("elseif/first-branch")
r = 0
if 1 = 1 then
  r = 1
elseif 1 = 2 then
  r = 2
else
  r = 3
end if
assert_eq(r, 1, "the IF branch won")

test_case("elseif/middle-branch")
r = 0
if 1 = 2 then
  r = 1
elseif 1 = 1 then
  r = 2
else
  r = 3
end if
assert_eq(r, 2, "the ELSEIF branch")

test_case("elseif/final-else")
r = 0
if 1 = 2 then
  r = 1
elseif 2 = 3 then
  r = 2
else
  r = 3
end if
assert_eq(r, 3, "neither test passed, so the ELSE")

test_case("elseif/several-in-a-chain")
for i = 1 to 5
  r = 0
  if i = 1 then
    r = 10
  elseif i = 2 then
    r = 20
  elseif i = 3 then
    r = 30
  elseif i = 4 then
    r = 40
  else
    r = 50
  end if
  assert_eq(r, i * 10, "branch " + i)
next

test_case("elseif/no-trailing-else")
r = 0
if 1 = 2 then
  r = 1
elseif 1 = 1 then
  r = 2
end if
assert_eq(r, 2, "a chain that ends without an ELSE")

r = 99
if 1 = 2 then
  r = 1
elseif 2 = 3 then
  r = 2
end if
assert_eq(r, 99, "and one where nothing matched")

test_case("elseif/two-words-still-work")
r = 0
if 1 = 2 then
  r = 1
else if 1 = 1 then
  r = 2
else
  r = 3
end if
assert_eq(r, 2, "the two-word spelling is untouched")

test_case("elseif/mixed-spellings-in-one-chain")
r = 0
if 1 = 2 then
  r = 1
elseif 2 = 3 then
  r = 2
else if 1 = 1 then
  r = 3
else
  r = 4
end if
assert_eq(r, 3, "one word and two words in the same chain")

test_case("elseif/still-an-ordinary-variable")
rem The whole reason this is contextual. If ELSEIF ever becomes a
rem lexer keyword, every one of these stops compiling -- and so does
rem any user function named elseif, because the lexer decides an
rem identifier's kind before it looks for a bracket.
elseif = 5
assert_eq(elseif, 5, "elseif holds a number")
elseif = elseif + 2
assert_eq(elseif, 7, "and takes an assignment")
elseif += 3
assert_eq(elseif, 10, "including a compound one")
assert_eq(elseif * 2, 20, "and reads as a value")

const = 7
assert_eq(const, 7, "const is an ordinary variable too")
assert_eq(elseif + const, 17, "both at once")

test_case("elseif/the-orphan-check-must-not-eat-these")
rem 2026-09-06: a block terminator standing ALONE became an error, because a
rem stray `next` with no `for` had been a silent no-op. The first version of that
rem check fired on the WORD and broke every assertion above -- `elseif = 5` is an
rem assignment, not an orphan `elseif`. What makes it safe is that it fires only
rem when the next token ends the statement, so the word is being used for nothing.
rem Pinned for the whole family, not just elseif, so the next attempt to widen the
rem check fails here instead of in someone's program.
next = 1
endif = 2
wend = 3
loop = 4
until = 5
case = 6
endselect = 7
endfunction = 8
then = 9
to = 10
step = 11
local = 12
assert_eq(next + endif + wend + loop, 10, "next/endif/wend/loop are ordinary variables")
assert_eq(until + case + endselect + endfunction, 26, "and so are until/case/endselect/endfunction")
assert_eq(then + to + step + local, 42, "and the mid-line words then/to/step/local")
next += 1
assert_eq(next, 2, "a terminator name takes a compound assignment")
assert_eq(next * step, 22, "and reads as a value in an expression")
