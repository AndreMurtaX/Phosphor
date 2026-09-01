rem ---------------------------------------------------------------
rem String append, and the peephole that rewrites it.
rem
rem `s$ = s$ + x` emits PUSH$ v / <push> / ADD$ / POPSTORE$ v, and
rem TCompiler.AssignAppend rewrites exactly that shape into
rem NOP / <push> / NOP / APPEND$ v, so the destination never reaches
rem the stack and its buffer can grow in place instead of being
rem copied whole on every iteration.
rem
rem Everything below is about the rewrite being invisible. Two of
rem these cases emit the same four token kinds and MUST NOT be
rem rewritten -- a different destination variable, and a longer
rem expression where pairing the first push with the last ADD$ would
rem take the wrong operand off the stack.
rem ---------------------------------------------------------------

test_case("append/constant")
s$ = ""
s$ = s$ + "x"
assert_eq(s$, "x", "one append to an empty string")
s$ = s$ + "y"
assert_eq(s$, "xy", "and a second")

test_case("append/variable")
s$ = "a"
t$ = "b"
s$ = s$ + t$
assert_eq(s$, "ab", "appending another variable")
assert_eq(t$, "b", "which is left alone")

test_case("append/self")
rem The source and the destination are one buffer here, so the append
rem finds it shared and allocates -- exactly as the old sequence
rem always did. Right answer is the whole requirement.
s$ = "ab"
s$ = s$ + s$
assert_eq(s$, "abab", "a string appended to itself")
s$ = s$ + s$
assert_eq(s$, "abababab", "twice")

test_case("append/different-destination-is-not-an-append")
rem Same four token kinds, different operands. If the peephole ignored
rem the operands this would silently become t$ = t$ + "z".
s$ = "keep"
t$ = "y"
s$ = t$ + "z"
assert_eq(s$, "yz", "s$ took the whole expression")
assert_eq(t$, "y", "and t$ was not appended to")

test_case("append/longer-expression-is-not-an-append")
rem Six instructions, not four. Pairing the first PUSH$ with the last
rem ADD$ would append the wrong thing.
s$ = "a"
t$ = "b"
s$ = s$ + t$ + "c"
assert_eq(s$, "abc", "three terms still concatenate left to right")
s$ = "a"
s$ = "z" + s$ + t$
assert_eq(s$, "zab", "and a leading constant is not a destination")

test_case("append/empty-operands")
s$ = ""
s$ = s$ + ""
assert_eq(s$, "", "empty plus empty")
s$ = s$ + "q"
assert_eq(s$, "q", "then something")
s$ = s$ + ""
assert_eq(s$, "q", "then nothing again")

test_case("append/in-a-loop")
s$ = ""
for i = 1 to 200
  s$ = s$ + "-"
next
assert_eq(len(s$), 200, "two hundred appends give two hundred characters")
assert_eq(mid$(s$, 1, 3), "---", "and they are the right ones")
assert_eq(instr(s$, "x"), 0, "with nothing else in there")

test_case("append/interleaved-with-other-strings")
rem The append must not disturb neighbouring string variables, which
rem live in the same heap the rewritten instruction now writes to
rem directly instead of through the stack.
a$ = "A"
b$ = "B"
c$ = ""
for i = 1 to 50
  c$ = c$ + "."
next
assert_eq(a$, "A", "the string before it is intact")
assert_eq(b$, "B", "and the one after")
assert_eq(len(c$), 50, "and the built one is right")

test_case("append/local-destination")
assert_eq(build$(5), ".....", "a local variable appends the same way")
assert_eq(build$(0), "", "including zero times")
assert_eq(build$(1), ".", "and once")

test_case("append/across-a-label")
rem A jump target must not land inside a rewritten window. It cannot
rem here -- the four instructions are one statement -- but a label
rem immediately before one has to still work.
s$ = ""
i = 0
top:
i = i + 1
s$ = s$ + "*"
if i < 4 then goto top
assert_eq(s$, "****", "a loop built with GOTO around the append")

test_case("append/after-the-loop-the-value-survives")
rem The rewritten instruction clears the stack slot it consumed. If it
rem cleared the wrong thing, the value built above would not be here.
assert_eq(len(s$), 4, "still four")
assert_eq(s$ + "!", "****!", "and still usable in another expression")

function build$(n) local out$, k
  out$ = ""
  for k = 1 to n
    out$ = out$ + "."
  next
  return out$
endfunction
