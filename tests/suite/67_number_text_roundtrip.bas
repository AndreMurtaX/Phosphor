rem ---------------------------------------------------------------
rem  A NUMBER MUST COME BACK AS THE NUMBER THAT WENT IN.
rem
rem  str$ and print both formatted a Double with 15 significant
rem  digits where IEEE-754 needs 17, so the text named a DIFFERENT
rem  number.  The work order's own recurrence,
rem  x = x * 1.0000001 + 0.000000123, lost 196 of its first 200
rem  values through val(str$(x)) -- and the two numbers PRINTED
rem  IDENTICALLY, so no golden and no amount of reading output could
rem  ever show it.  print # then input # is how a program persists a
rem  number, and it altered every computed value it wrote.
rem
rem  Worse than a lost digit: str$ of the largest Double emitted
rem  1.79769313486232E308, which is larger than MaxDouble, and the
rem  engine's own val() then refused its own output -- "val has no
rem  finite result for those arguments".  str$ was producing text
rem  val cannot read.
rem
rem  THE EXPECTATIONS HERE ARE NOT READ OFF A RUN.  The round trip
rem  is IEEE-754's property, not this engine's: 17 significant
rem  decimal digits distinguish every pair of Doubles, so a spelling
rem  that reads back as the value always exists.  It is asserted
rem  over swept ranges, because a list of literals someone chose is
rem  what let an earlier finiteness patch pass a byte-identical diff
rem  while a whole band of correct answers had been turned into 0.
rem
rem  The pinned SPELLINGS are the other half, and they pin two
rem  different things.  The short ones are the PRISTINE engine's
rem  answers: a fix that simply emitted 17 digits always would
rem  satisfy every round-trip assertion here and turn `println 1.5`
rem  into 1.5000000000000000E+000.  The two LONG ones say which rung
rem  of the ladder was taken, which no round-trip assertion can see
rem  -- every working ladder satisfies those -- and which is also
rem  the only way a difference between Windows and Linux could show
rem  itself, since the reader that decides a rung narrows an 80-bit
rem  intermediate on one of them and not the other.  Their digits
rem  come from the values' exact binary expansions, written out
rem  beside them, not from this engine.
rem ---------------------------------------------------------------

test_case("number-text/the work order's recurrence survives str$")
bad = 0
x = 1.0
for i = 1 to 200
  x = x * 1.0000001 + 0.000000123
  if val(str$(x)) <> x then bad = bad + 1
next
assert_eq(bad, 0, "196 of these 200 used to come back as a different number")

test_case("number-text/and it survives the OTHER text path")
rem  print, println, print # and string concatenation share one
rem  formatter (ValToStr); str$ has its own call site.  Fixing one
rem  and not the other is a green suite over a live defect, so both
rem  are swept.
bad = 0
x = 1.0
for i = 1 to 200
  x = x * 1.0000001 + 0.000000123
  if val("" + x) <> x then bad = bad + 1
next
assert_eq(bad, 0, "concatenation lost the same 196 values")

test_case("number-text/and it survives a file, which is how a program persists one")
rem  print # then input # is the work order's headline scenario and
rem  the only one of the four text paths that leaves the process.
rem  The file goes in the platform's temp directory, which the
rem  sandbox puts inside the runner's own root (see 58_sandbox), and
rem  is deleted again at the end.
f$ = path_combine$(temppath$(), "p9b_numtext_roundtrip.txt")
if file_exists(f$) <> 0 then file_delete(f$)
open f$ for output as #1
x = 1.0
for i = 1 to 200
  x = x * 1.0000001 + 0.000000123
  println #1, x
next
println #1, 0.0 * -1.0
close #1
bad = 0
open f$ for input as #2
x = 1.0
for i = 1 to 200
  x = x * 1.0000001 + 0.000000123
  input #2, back
  if back <> x then bad = bad + 1
next
input #2, negback
close #2
assert_eq(bad, 0, "every value written with print # read back with input #")
assert_eq(str$(negback), "-0", "and a negative zero kept its sign through the file")
assert_eq(file_delete(f$), 1, "the scratch file is removed again")

test_case("number-text/across the exponent range, not just around 1")
rem  The recurrence only visits numbers near 1.  This walks the same
rem  ratio up and down the format instead, so the exponential and
rem  the plain-decimal spellings are both exercised.
bad = 0
scale = 1.0
for i = 1 to 60
  scale = scale * 1000.0
  y = scale * 1.3333333333333333
  if val(str$(y)) <> y then bad = bad + 1
next
scale = 1.0
for i = 1 to 60
  scale = scale / 1000.0
  y = scale * 1.3333333333333333
  if val(str$(y)) <> y then bad = bad + 1
next
assert_eq(bad, 0, "a value must read back whatever its exponent")

test_case("number-text/str$ of the largest Double is text val can read")
rem  Without the fix this raises err 1 -- val refusing text the
rem  engine itself produced, because 1.79769313486232E308 is past
rem  MaxDouble.  The assertion is that the refusal is gone.
caught% = 0
biggest = 1.7976931348623157E308
on error goto maxbad
back = val(str$(biggest))
goto after_max
maxbad:
caught% = 1
resume next
after_max:
on error goto 0
assert_eq(caught%, 0, "val must not refuse the text str$ gave it")
assert_eq(err(), 0, "and no error is left standing")
assert_true(back = biggest, "the largest Double survives the trip through text")

test_case("number-text/the digits that were missing are there now")
rem  0.30000000000000004 is not read off a run.  The Double that
rem  0.1 + 0.2 produces is exactly
rem  0.3000000000000000444089209850062616169452667236328125, so its
rem  17-significant-digit form is 0.30000000000000004 -- which is
rem  also the shortest text that reads back as it, and what every
rem  IEEE-754 language prints for that sum.  0.3 is a DIFFERENT
rem  Double, which is the whole defect.
sum = 0.1 + 0.2
assert_eq(str$(sum), "0.30000000000000004", "the sum is not 0.3")
assert_true(sum <> 0.3, "and the engine agrees the two differ")
assert_eq("" + sum, "0.30000000000000004", "print says the same as str$")
assert_true(val(str$(sum)) = sum, "and it reads back")

test_case("number-text/which rung was taken, pinned as text")
rem  One third is exactly
rem  0.333333333333333314829616256247390992939472198486328125, so
rem  its 17-digit form is 0.33333333333333331 -- one digit longer
rem  than the shortest text that reads back, 0.3333333333333333.
rem  That extra digit is the measured price of not offering a
rem  16-digit rung: FPC's Str is not correctly rounded at 16
rem  significant digits, and the reader that would check such a rung
rem  cannot see when it is wrong (71 values in a 474393-value sweep
rem  were spelled as their NEIGHBOUR).  So this is not cosmetic and
rem  not incidental -- it is the shape of the fix, and it is pinned
rem  so that reintroducing the rung, or Windows and Linux choosing
rem  differently, is a byte difference the suite reports.
rem
rem  Written as a division of two Double literals on purpose: atan or
rem  any other ValReal function is Extended on Linux and Double on
rem  Win64, which would make the two platforms disagree here for a
rem  reason that has nothing to do with text.
third = 1.0 / 3.0
assert_eq(str$(third), "0.33333333333333331", "the fallback rung, spelled out")
assert_true(val(str$(third)) = third, "and it still reads back")
assert_true(third <> 0.333333333333333, "15 digits really is a different number")

test_case("number-text/the readable spellings are untouched")
rem  Every one of these is what the engine printed before the
rem  change; several are pinned in 06_strings.bas and
rem  61_utf8_character_ops.bas too.  If a value already described
rem  itself in 15 digits, its text must not move by a byte.
assert_eq(str$(1.5), "1.5", "a short fraction")
assert_eq(str$(0.1), "0.1", "a value that is not exact but is short")
assert_eq(str$(3.5), "3.5", "another")
assert_eq(str$(-7.5), "-7.5", "a negative")
assert_eq(str$(1e15), "1E15", "the exponent threshold upwards")
assert_eq(str$(1e200), "1E200", "a large exponent")
assert_eq(str$(1e-6), "1E-6", "the exponent threshold downwards")
assert_eq(str$(0.00001), "0.00001", "one step inside it, still plain")

test_case("number-text/an int% still keeps its digits")
rem  str$ has an exact ':%' slot so an int% never goes through a
rem  Double (PhosphorStrLib f_striInt).  The Double path changing
rem  must not disturb it.
id% = 1000000000000001
assert_eq(str$(id%), "1000000000000001", "sixteen digits, no exponent")

test_case("number-text/the sign of a zero is information too")
rem  FloatToStr writes -0.0 as "0", which reads back as +0.0.  The
rem  round trip is decided on the BYTES of the two Doubles, so that
rem  is not a successful trip and the engine answers "-0" instead.
rem
rem  The second assertion goes back out through str$ deliberately.
rem  `val(str$(negzero)) = negzero` was the obvious spelling and it
rem  is VACUOUS: `=` calls -0.0 and +0.0 equal, which is the very
rem  reason the ladder compares bytes, so it passed with the sign
rem  lost.  Asking str$ again is the only way a .bas file can see a
rem  sign that arithmetic cannot.
negzero = 0.0 * -1.0
assert_eq(str$(negzero), "-0", "the sign survives the spelling")
assert_eq(str$(val(str$(negzero))), "-0", "and survives being read back")
end
