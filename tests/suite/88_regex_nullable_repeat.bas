rem ---------------------------------------------------------------
rem  A REGEX CALL MUST NEVER END THE PROCESS (2026-10-09).
rem
rem  TRegExpr 0.987 recurses on the machine stack, at compile and at
rem  match, with no limit of its own. Four shapes ran it off the end:
rem
rem   D1 a repeated group that can match nothing, at the start of the
rem      pattern: (a{0,2}){2}. Its compiler walks the group, comes
rem      back to the repeat and walks it again, for ever. It believes
rem      a{0,2} has width, so it does not refuse the repeat itself.
rem   D2 a repeat with no upper count over such a group: b(a{0,2})+.
rem      The matcher takes the empty match again and again.
rem   D3 a counted backreference to a group that captured nothing:
rem      ()\1*x. The matcher counts empty copies to 2^31 and then
rem      backs off "that many bytes" -- past the end of the text.
rem   D4 a long text through a repeated group: (a|b)* costs four
rem      240-byte frames per byte, so 40000 bytes want 38 MB of a
rem      16 MB stack (8 MB on Linux).
rem
rem  On Windows the FIRST overflow in a thread was caught as "regex
rem  error: Stack overflow" and the SECOND was an access violation
rem  that ended the host: the stack's guard page is not re-armed. On
rem  Linux the first one ended it. So every refusal below is asked
rem  TWICE: the second call is the one that killed the process, and
rem  the last case proves the process is still here to answer.
rem
rem  The answer for a pattern Phosphor will not run is the library's
rem  error path for a pattern it cannot compile: code 6, a message
rem  beginning "regex error:", catchable, nothing raised past it.
rem  Each message names its reason; the reasons are matched here.
rem
rem  The allowed cases are worked by hand: b(a{0,2}){2} on "baaa"
rem  takes the b, then up to two a's twice -- all three a's; (a|b)*
rem  over a thousand a's is all of them; (a)\1{2} reads a, then two
rem  more copies of it.
rem ---------------------------------------------------------------

goto start

caught:
ec = err()
em$ = errmsg$()
resume next

start:

rem --- D1: the compiler's endless walk --------------------------------
test_case("regex/D1 a leading repeat of a group that can match nothing")
for t = 1 to 2
  ec = 0
  em$ = ""
  r$ = "untouched"
  on error goto caught
  r$ = regex_find$("(a{0,2}){2}", "aaa")
  on error goto 0
  assert_eq(ec, 6, "(a{0,2}){2} is refused as a regex error, call " + str$(t))
  assert_true(instr(em$, "regex error:") = 1, "the message is the library's own, call " + str$(t))
  assert_true(instr(em$, "compiler would recurse without end") > 0, "and names the endless compile, call " + str$(t))
  assert_eq(r$, "untouched", "nothing was assigned, call " + str$(t))
next

test_case("regex/D1 the other spellings of it")
ec = 0
on error goto caught
r = regex_findpos("(a{0,2}){1}", "aaa")
on error goto 0
assert_eq(ec, 6, "a count of one is refused too")
ec = 0
on error goto caught
r = regex_findpos("(b|a{0,1}){2}", "bab")
on error goto 0
assert_eq(ec, 6, "one optional branch is enough")
ec = 0
on error goto caught
r = regex_findpos("(?:a{0,2})+", "aaa")
on error goto 0
assert_eq(ec, 6, "a greedy + over a non-capturing group")
ec = 0
on error goto caught
r = regex_findpos("(a?)??", "aaa")
on error goto 0
assert_eq(ec, 6, "a lazy ?? over a group that a ? makes optional")
ec = 0
em$ = ""
on error goto caught
r@ = regex_findall@("^(a{0,2}){2}", "aaa")
on error goto 0
assert_eq(ec, 6, "an anchor in front does not stop the walk")
assert_true(instr(em$, "regex_findall@") > 0, "the message names the function")

test_case("regex/D1 the same group after a byte runs")
ec = 0
on error goto caught
r$ = regex_find$("b(a{0,2}){2}", "baaa")
on error goto 0
assert_eq(ec, 0, "b(a{0,2}){2} is allowed: the walk stops at the b")
assert_eq(r$, "baaa", "and it answers the b and all three a's")

rem --- D2: the matcher's endless empty repeat -------------------------
test_case("regex/D2 an unbounded repeat over a group that can match nothing")
for t = 1 to 2
  ec = 0
  em$ = ""
  on error goto caught
  r$ = regex_find$("b(a{0,2})+", "baa")
  on error goto 0
  assert_eq(ec, 6, "b(a{0,2})+ is refused, call " + str$(t))
  assert_true(instr(em$, "matcher would recurse without end") > 0, "and names the endless match, call " + str$(t))
next
ec = 0
on error goto caught
r$ = regex_find$("b(a{0,2})*?c", "baac")
on error goto 0
assert_eq(ec, 6, "the lazy form counts to 2^31 and is refused too")

rem --- D3: a counted backreference to nothing -------------------------
test_case("regex/D3 a counted backreference to a group that captured nothing")
for t = 1 to 2
  ec = 0
  em$ = ""
  on error goto caught
  r = regex_findlen("()\\1*?x", "a")
  on error goto 0
  assert_eq(ec, 6, "()\\1*?x is refused, call " + str$(t))
  assert_true(instr(em$, "past the end of the text") > 0, "and names the overread, call " + str$(t))
next
ec = 0
on error goto caught
r$ = regex_find$("(a)\\1{2}", "aaab")
on error goto 0
assert_eq(ec, 0, "a counted backreference to a group of one byte is allowed")
assert_eq(r$, "aaa", "and reads a, then two more copies of it")

rem --- D4: a text longer than the stack can follow --------------------
test_case("regex/D4 the stack a long text needs is counted before the call")
long$ = string$(40000, 97)
for t = 1 to 2
  ec = 0
  em$ = ""
  on error goto caught
  r = regex_findlen("(a|b)*", long$)
  on error goto 0
  assert_eq(ec, 6, "(a|b)* over 40000 bytes is refused, call " + str$(t))
  assert_true(instr(em$, "KB of stack") > 0, "and says how much stack it would want, call " + str$(t))
next
ec = 0
on error goto caught
r = regex_findlen("(a|b)*", string$(1000, 97))
on error goto 0
assert_eq(ec, 0, "the same pattern over a thousand bytes runs")
assert_eq(r, 1000, "and matches all of them")
ec = 0
on error goto caught
r = regex_findlen("a*", long$)
on error goto 0
assert_eq(ec, 0, "a one-byte repeat costs one frame for any length")
assert_eq(r, 40000, "and matches the whole text")

test_case("regex/the process is still here")
assert_eq(regex_find$("a+", "baa"), "aa", "an ordinary pattern answers after every refusal")
