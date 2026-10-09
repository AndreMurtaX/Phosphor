rem ---------------------------------------------------------------
rem  JSON IS A NUMBER-TEXT DOOR, AND READS THROUGH THE ONE READER
rem  (2026-10-09, round 3).
rem
rem  Round 2 put every door that turns decimal text into a number on
rem  PhosphorValue.ReadNumberText -- correctly rounded, any length, a
rem  NUL makes text not a number (84_number_text.bas) -- and missed
rem  JSON, which reads numbers in two places:
rem
rem   - a NUMBER in a parsed document was read by fpjson, through FPC's
rem     Val: about 7 random literals in 20000 came back one ulp off
rem     (1e126, 6.4e127), and a token longer than 255 characters was
rem     refused outright ("Number is not an integer or real number"),
rem     taking the whole document with it, although RFC 8259 calls it
rem     a number;
rem   - a numeric STRING read by json_getn / json_itemn / json_pathn /
rem     json_value went through TryStrToFloat: the same rounding, 0 for
rem     anything past 255 bytes, "5" NUL "x" read as 5, and "nan",
rem     "inf", "-inf" and "1e999" became a non-finite Double that the
rem     registry's gate turned into a FATAL error -- from json_value,
rem     which json.md promises never raises.
rem
rem  Now both read through ReadNumberText. A string reads as its number
rem  exactly when isnumeric() approves it, otherwise 0; a number too
rem  large for a Double refuses the document, as 1e400 always did.
rem
rem  EVERY EXPECTED VALUE is independent of the engine: Double bits
rem  from Python's float() (correctly rounded), written as the signed
rem  64-bit integer of the bits, read back here through buffer_setdbl
rem  exactly as 84_number_text.bas does. Error positions are derived
rem  by arithmetic from fpjson's message for the same document with
rem  the long number written short (Pos 7 for "[1, 2 x]", plus the 300
rem  extra digits).
rem ---------------------------------------------------------------

b@ = buffer_new@(8)
function bits%(x) local z
  z = buffer_setdbl(b@, 1, x)
  return buffer_getint(b@, 1, 8)
endfunction

q$ = chr$(34)
bs$ = chr$(92)
z300$ = mulstring$("0", 300)

test_case("a parsed number is the correctly rounded Double")
j@ = json_parse@("[1e126, 6.4e127, 6.53713e-309, 1.156736850094319e-308, 2e126, 1.61512527e-184, 3.4735142818e-85]")
assert_int(bits%(json_itemn(j@, 1)), 6491836525663526975, "1e126")
assert_int(bits%(json_itemn(j@, 2)), 6518858123427749951, "6.4e127")
assert_int(bits%(json_itemn(j@, 3)), 1323129842162819, "6.53713e-309, a subnormal")
assert_int(bits%(json_itemn(j@, 4)), 2341261449426909, "1.156736850094319e-308")
assert_int(bits%(json_itemn(j@, 5)), 6496340125290897471, "2e126")
assert_int(bits%(json_itemn(j@, 6)), 1857160939216323805, "1.61512527e-184")
assert_int(bits%(json_itemn(j@, 7)), 3343245281185866491, "3.4735142818e-85")
assert_int(bits%(json_value(json_item@(j@, 1))), 6491836525663526975, "json_value of the node agrees")

test_case("integers past an Int64 are read the same way")
j@ = json_parse@("[18446744073709551615, 9223372036854775808, -9223372036854775809, 123456789012345678901234567890]")
assert_int(bits%(json_itemn(j@, 1)), 4895412794951729152, "2^64 - 1 is 2^64")
assert_int(bits%(json_itemn(j@, 2)), 4890909195324358656, "2^63")
assert_int(bits%(json_itemn(j@, 3)), -4332462841530417152, "-(2^63 + 1) is -2^63")
assert_int(bits%(json_itemn(j@, 4)), 5042042089369253694, "a 30-digit integer")
rem Between 2^63 and 2^64 fpjson keeps the integer exact, as a QWord, and
rem FPC's QWord-to-Double conversion is not correctly rounded: the
rem generated sweep found these (3 in 20000).
j@ = json_parse@("[9848624006817426123, 9265492289235224056, 9916176236238859093]")
assert_int(bits%(json_itemn(j@, 1)), 4891214494137816981, "9848624006817426123")
assert_int(bits%(json_itemn(j@, 2)), 4890929761853841297, "9265492289235224056")
assert_int(bits%(json_value(json_item@(j@, 3))), 4891247478624839165, "9916176236238859093")
assert_eq(json_stringify$(j@), "[9848624006817426123, 9265492289235224056, 9916176236238859093]", "and the text keeps every digit")

test_case("the same text as a STRING member reads the same Double")
j@ = json_parse@("{" + q$ + "n" + q$ + ": 1e126, " + q$ + "s" + q$ + ": " + q$ + "1e126" + q$ + ", " + q$ + "t" + q$ + ": " + q$ + "6.4e127" + q$ + "}")
assert_int(bits%(json_getn(j@, "n")), 6491836525663526975, "the number 1e126")
assert_int(bits%(json_getn(j@, "s")), 6491836525663526975, "the string 1e126")
assert_int(bits%(json_getn(j@, "t")), 6518858123427749951, "the string 6.4e127")
assert_int(bits%(json_pathn(j@, "t")), 6518858123427749951, "json_pathn agrees")
assert_int(bits%(json_value(json_string@("6.4e127"))), 6518858123427749951, "json_value agrees")

test_case("a number longer than 255 characters parses")
j@ = json_parse@("[1" + z300$ + "]")
assert_int(bits%(json_itemn(j@, 1)), 9094988921128908188, "1 and 300 zeros is 1e300")
j@ = json_parse@("[1" + z300$ + ".5]")
assert_int(bits%(json_itemn(j@, 1)), 9094988921128908188, "and with .5 after it")
j@ = json_parse@("[0." + mulstring$("0", 400) + "1]")
assert_int(bits%(json_itemn(j@, 1)), 0, "0. then 400 zeros then 1 underflows to +0")
j@ = json_parse@("[1" + z300$ + "e-300]")
assert_eq(json_itemn(j@, 1), 1, "10^300 written out, times 10^-300")
t$ = "1.00000000000000011102230246251565404236316680908203125" + mulstring$("0", 250)
j@ = json_parse@("{" + q$ + "tie" + q$ + ": " + t$ + ", " + q$ + "up" + q$ + ": " + t$ + "1}")
assert_int(bits%(json_getn(j@, "tie")), 4607182418800017408, "the exact midpoint 1 + 2^-53 rounds to the even one, 1")
assert_int(bits%(json_pathn(j@, "up")), 4607182418800017409, "a 1 250 places past it rounds up")

test_case("what the parser takes short it takes long, and nothing more")
rem fpjson is lenient outside strict mode: it reads 007 and .5. The same
rem spellings past 255 characters are read too -- and a bare number is a
rem whole document -- while a long run it would not take whole is still
rem refused by its own rule.
j@ = json_parse@("[007, .5, 0" + z300$ + "7, ." + mulstring$("5", 300) + "]")
assert_eq(json_itemn(j@, 1), 7, "007 short")
assert_eq(json_itemn(j@, 2), 0.5, ".5 short")
assert_eq(json_itemn(j@, 3), 7, "0, 300 zeros, 7")
assert_int(bits%(json_itemn(j@, 4)), 4603179219131243634, ". and 300 fives is 0.5555555555555556")
assert_int(bits%(json_value(json_parse@("1" + z300$))), 9094988921128908188, "a bare long number is a document")
caught = 0
m$ = ""
on error goto glued
bad@ = json_parse@("[1" + z300$ + "x]")
goto after_glued
glued:
caught = 1
m$ = errmsg$()
resume next
after_glued:
on error goto 0
assert_eq(caught, 1, "a long number glued to an x is still malformed")
assert_true(instr(m$, "pos 302"), "at the x, character 302")

test_case("a long number among short ones keeps every value in its place")
rem 0e0 and 0e1 are ordinary numbers; a long one between them must not
rem be confused with them however it is carried through the parser.
j@ = json_parse@("[0e0, 1" + z300$ + ", 0e1, 7, 1" + z300$ + ".5, 0e2]")
assert_eq(json_len(j@), 6, "six elements")
assert_int(bits%(json_itemn(j@, 1)), 0, "0e0")
assert_int(bits%(json_itemn(j@, 2)), 9094988921128908188, "the first long one")
assert_int(bits%(json_itemn(j@, 3)), 0, "0e1")
assert_eq(json_itemn(j@, 4), 7, "7")
assert_int(bits%(json_itemn(j@, 5)), 9094988921128908188, "the second long one")
assert_int(bits%(json_itemn(j@, 6)), 0, "0e2")

test_case("a long number in a document that carries a \\u escape")
j@ = json_parse@("[" + q$ + bs$ + "u00e9" + q$ + ", 1" + z300$ + "]")
assert_eq(json_items$(j@, 1), chr$(233), "the escape is decoded")
assert_int(bits%(json_itemn(j@, 2)), 9094988921128908188, "and the long number is 1e300")

test_case("a long number survives the round trip through text")
j@ = json_parse@("[1" + z300$ + ".5, 6.4e127]")
k@ = json_parse@(json_stringify$(j@))
assert_int(bits%(json_itemn(k@, 1)), 9094988921128908188, "1e300 again")
assert_int(bits%(json_itemn(k@, 2)), 6518858123427749951, "6.4e127 again")

test_case("a long number too large for a Double refuses the document")
caught = 0
m$ = ""
on error goto big
bad@ = json_parse@("{" + q$ + "huge" + q$ + ": 1" + mulstring$("0", 400) + "}")
goto after_big
big:
caught = 1
m$ = errmsg$()
resume next
after_big:
on error goto 0
assert_eq(caught, 1, "1 and 400 zeros has no Double")
assert_true(instr(m$, "out of range"), "and is said to be out of range")
assert_true(instr(m$, "huge"), "naming where it is")
assert_eq(instr(m$, "Number is not"), 0, "not called a non-number")

test_case("an error after a long number names the caller's position")
caught = 0
m$ = ""
on error goto later
bad@ = json_parse@("[1" + z300$ + ", 2 x]")
goto after_later
later:
caught = 1
m$ = errmsg$()
resume next
after_later:
on error goto 0
assert_eq(caught, 1, "the stray x is still an error")
assert_true(instr(m$, "Pos 307"), "at Pos 307, as [1, 2 x] says Pos 7")
assert_true(instr(m$, "got token"), "and for the x, not the number")

test_case("a numeric string longer than 255 bytes reads as its number")
j@ = json_parse@("[" + q$ + mulstring$("1", 300) + q$ + "]")
assert_int(bits%(json_itemn(j@, 1)), 9080730914125102560, "300 ones is 1.1111111111111112e299")
assert_int(bits%(json_value(json_string@(mulstring$("1", 300)))), 9080730914125102560, "json_value agrees")

test_case("a NUL makes a string not a number")
j@ = json_parse@("[" + q$ + "5" + bs$ + "u0000x" + q$ + ", " + q$ + "5" + bs$ + "u0000" + q$ + "]")
assert_eq(len(json_items$(j@, 1)), 3, "the string holds its NUL")
assert_eq(json_itemn(j@, 1), 0, "5 NUL x reads 0")
assert_eq(json_itemn(j@, 2), 0, "5 NUL reads 0: a NUL is not whitespace")
assert_eq(json_value(json_string@("12" + chr$(0) + "34")), 0, "json_value agrees")

test_case("the language's trim and grammar decide a string")
assert_eq(json_value(json_string@(" " + chr$(9) + "7 " + chr$(13) + chr$(10))), 7, "whitespace at both ends is trimmed")
assert_eq(json_value(json_string@("0x10")), 0, "0x10 is not number text")
assert_eq(json_value(json_string@("$10")), 0, "nor $10")
assert_eq(json_value(json_string@("1,5")), 0, "nor 1,5")
assert_eq(json_value(json_string@("5.")), 5, "5. is")
assert_eq(json_value(json_string@(".5")), 0.5, ".5 is")
assert_eq(json_value(json_string@("1E+02")), 100, "1E+02 is")

test_case("nan, inf and an overflowing string read 0, and nothing raises")
rem Each call runs under a trap only so that the unfixed fault is
rem counted rather than ending the run; the trap is off before every
rem assertion.
j@ = json_parse@("{" + q$ + "a" + q$ + ": " + q$ + "nan" + q$ + ", " + q$ + "b" + q$ + ": " + q$ + "inf" + q$ + ", " + q$ + "c" + q$ + ": " + q$ + "-inf" + q$ + ", " + q$ + "d" + q$ + ": " + q$ + "1e999" + q$ + ", " + q$ + "e" + q$ + ": " + q$ + "-1e999" + q$ + ", " + q$ + "f" + q$ + ": " + q$ + "Infinity" + q$ + ", " + q$ + "g" + q$ + ": " + q$ + "NaN" + q$ + "}")
rem The members are named "a" to "g", in the order the array holds them.
arr@ = json_parse@("[" + q$ + "nan" + q$ + ", " + q$ + "inf" + q$ + ", " + q$ + "-inf" + q$ + ", " + q$ + "1e999" + q$ + ", " + q$ + "-1e999" + q$ + ", " + q$ + "Infinity" + q$ + ", " + q$ + "NaN" + q$ + "]")
for i = 1 to 7
  k$ = chr$(96 + i)
  faults = 0
  x1 = -1
  x2 = -1
  x3 = -1
  x4 = -1
  x5 = -1
  on error goto fault
  x1 = json_getn(j@, k$)
  x2 = json_getn(j@, k$, 7)
  x3 = json_pathn(j@, k$)
  x4 = json_value(json_get@(j@, k$))
  x5 = json_itemn(arr@, i)
  on error goto 0
  assert_eq(faults, 0, "no reader raised on " + k$ + " = " + json_gets$(j@, k$))
  assert_eq(x1, 0, "json_getn reads 0")
  assert_eq(x2, 0, "json_getn with a default reads 0, not the default")
  assert_eq(x3, 0, "json_pathn reads 0")
  assert_eq(x4, 0, "json_value reads 0")
  assert_eq(x5, 0, "json_itemn reads 0")
  assert_eq(isnumeric(json_gets$(j@, k$)), 0, "and isnumeric agrees it is not a number val can answer")
next

end

fault:
faults = faults + 1
resume next
