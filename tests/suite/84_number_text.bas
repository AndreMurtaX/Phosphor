rem ---------------------------------------------------------------
rem  NUMBER TEXT IS READ CORRECTLY ROUNDED, AT ANY LENGTH, AT EVERY DOOR
rem  (2026-10-09).
rem
rem  Every door that turns text into a number -- a literal, val(),
rem  isnumeric() and an input # field -- used FPC 3.2.2's Val. It is
rem  not correctly rounded: it scales the digits by an inexact cached
rem  power of ten with no correction step, so 1e126 read as the Double
rem  5A17A2ECC414A040 where the nearest is ...03F; 57311.8821011 and
rem  6.20035e28 were one ulp off too. And it reads through a 255-byte
rem  ShortString: a longer literal was "out of range" whatever its
rem  value, val() and isnumeric() answered 0, and an input # field
rem  was "not a number". TryStrToFloat also stopped at a NUL, so
rem  val("12" + NUL + "34") was 12. One reader now serves every door:
rem  docs/language-reference.md#number-text.
rem
rem  EVERY EXPECTED VALUE HERE is independent of the engine: the Double
rem  bits come from Python's float() (correctly rounded, IEEE 754
rem  round-half-even) and are written as the signed 64-bit integer of
rem  the bits, which bits%() reads back through buffer_setdbl. The
rem  long ties are built from arithmetic: 1 + 2^-53 is exactly the
rem  midpoint between 1 and the next Double, so it rounds to the even
rem  one, 1, and anything above it -- even one digit 300 places out --
rem  rounds up to 1 + 2^-52. The stop positions come from the grammar
rem  (the first byte that does not fit; one past the end when the text
rem  ends too soon). tests/number_text_sweep.py is the generated half.
rem ---------------------------------------------------------------

b@ = buffer_new@(8)
function bits%(x) local z
  z = buffer_setdbl(b@, 1, x)
  return buffer_getint(b@, 1, 8)
endfunction

test_case("the literals the finding named")
assert_int(bits%(1e126), 6491836525663526975, "1e126 is 5A17A2ECC414A03F")
assert_int(bits%(57311.8821011), 4678109698680690185, "57311.8821011 is 40EBFBFC3A2C1609")
assert_int(bits%(6.20035e28), 5037569765615516251, "6.20035e28 is 45E90B02FAC2BA5B")

test_case("the same three through val()")
assert_int(bits%(val("1e126")), 6491836525663526975, "val 1e126")
assert_int(bits%(val("57311.8821011")), 4678109698680690185, "val 57311.8821011")
assert_int(bits%(val("6.20035e28")), 5037569765615516251, "val 6.20035e28")

test_case("literals past 255 characters")
x = 00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001.5
assert_eq(x, 1.5, "280 leading zeros, then 1.5")
x = 1.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001
assert_int(bits%(x), 4607182418800017408, "1 + 1e-301 is 1")
x = 1.000000000000000111022302462515654042363166809082031250000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
assert_int(bits%(x), 4607182418800017408, "the exact midpoint 1 + 2^-53 rounds to the even one")
x = 1.0000000000000001110223024625156540423631668090820312500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001
assert_int(bits%(x), 4607182418800017409, "a 1 three hundred places past the midpoint rounds up")
n% = 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000042
assert_int(n%, 42, "a long plain integer literal is still an int%")

test_case("val() and isnumeric() past 255 bytes")
t$ = "1.00000000000000011102230246251565404236316680908203125"
assert_eq(len(t$ + mulstring$("0", 250)), 305, "the tie text is 305 bytes")
assert_int(bits%(val(t$ + mulstring$("0", 250))), 4607182418800017408, "val of the tie is 1")
assert_int(bits%(val(t$ + mulstring$("0", 250) + "1")), 4607182418800017409, "val above it is 1 + 2^-52")
assert_eq(valcode(), 0, "and it parsed whole")
assert_eq(val(mulstring$("0", 300) + "7"), 7, "300 leading zeros")
assert_eq(isnumeric(mulstring$("0", 300) + "7"), 1, "isnumeric agrees")
assert_eq(val("1" + mulstring$("0", 300) + "e-300"), 1, "10^300 written out, times 10^-300")

test_case("a NUL makes text not a number")
assert_eq(val("12" + chr$(0) + "34"), 0, "a NUL inside")
assert_eq(valcode(), 3, "stops at the NUL")
assert_eq(isnumeric("12" + chr$(0) + "34"), 0, "isnumeric agrees")
assert_eq(val("5" + chr$(0)), 0, "a NUL at the end is not trimmed")
assert_eq(valcode(), 2, "stops at it")
assert_eq(val(chr$(0) + "5"), 0, "nor at the start")
assert_eq(valcode(), 1, "stops at it")
assert_eq(val(" \t 7 \t "), 7, "blanks and tabs at both ends are trimmed")
assert_eq(valcode(), 0, "and parse clean")

test_case("where a refused text stops")
assert_eq(val("12abc"), 0, "12abc")
assert_eq(valcode(), 3, "stops at a")
assert_eq(val("."), 0, "a lone point")
assert_eq(valcode(), 2, "ends too soon")
assert_eq(val("e5"), 0, "no mantissa")
assert_eq(valcode(), 1, "stops at e")
assert_eq(val("1e"), 0, "no exponent digits")
assert_eq(valcode(), 3, "ends too soon")
assert_eq(val(""), 0, "empty")
assert_eq(valcode(), 1, "ends at once")
assert_eq(val("inf"), 0, "inf is not number text")
assert_eq(valcode(), 1, "stops at i")
assert_eq(isnumeric("nan"), 0, "nor nan")
assert_eq(val("5."), 5, "5. is a number")
assert_eq(val(".5"), 0.5, ".5 is a number")
assert_eq(val("+5"), 5, "so is +5")
assert_eq(valcode(), 0, "and parses clean")

test_case("the edges of the range")
assert_int(bits%(val("2.4703282292062328e-324")), 1, "just over half the least subnormal is the least subnormal")
assert_int(bits%(val("2.4703282292062327e-324")), 0, "just under it is zero")
assert_int(bits%(val("1.7976931348623158e308")), 9218868437227405311, "DBL_MAX")
assert_eq(isnumeric("1.7976931348623159e308"), 0, "past the midpoint above DBL_MAX: no Double")
assert_eq(isnumeric("1e-99999999999999999999"), 1, "a vanishing exponent is a number")
assert_int(bits%(val("1e-99999999999999999999")), 0, "and it is zero")
assert_eq(val("0e99999999999"), 0, "zero times anything")
assert_eq(str$(val("-0")), "-0", "-0 keeps its sign")
over$ = ""
on error goto big
v = val("1e999")
on error goto 0
assert_eq(over$, "refused", "val of a number past every Double faults, as before")

test_case("input # fields")
f$ = path_combine$(temppath$(), "phosphor_number_text.txt")
open f$ for output as #1
println #1, "1e126"
println #1, mulstring$("0", 300) + "1.5"
println #1, "9007199254740993"
println #1, "$FF"
println #1, "-&17"
println #1, "0x1F"
println #1, "1" + chr$(0) + "2"
println #1, "-0"
close #1
open f$ for input as #2
input #2, a
assert_int(bits%(a), 6491836525663526975, "an input # field 1e126")
input #2, a
assert_eq(a, 1.5, "a 303-byte field")
input #2, n%
assert_int(n%, 9007199254740993, "2^53 + 1 stays exact in an int%")
input #2, n%
assert_int(n%, 255, "a hexadecimal field still reads")
input #2, n%
assert_int(n%, -15, "so does a signed octal one")
input #2, n%
assert_int(n%, 31, "and 0x")
msg$ = ""
on error goto bad
input #2, a
on error goto 0
assert_true(instr(msg$, "is not a number") > 0, "a field holding a NUL is not a number")
input #2, a
assert_eq(str$(a), "-0", "-0 comes back signed")
close #2
assert_eq(file_delete(f$), 1, "cleaned up")
end

big:
  over$ = "refused"
  resume next
bad:
  msg$ = errmsg$()
  resume next
