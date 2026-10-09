rem ---------------------------------------------------------------
rem A COLOUR IS AN UNSIGNED 32-BIT NUMBER, AND AN EMPTY NAME NAMES NO
rem VARIABLE (2026-10-09, round 2 of the adversarial loop).
rem
rem docs/libraries/sys.md: color() reads a "$rrggbb" or decimal literal,
rem alphacolor() is that with an opaque alpha byte -- alphacolor("Red") is
rem 4278190335, so a colour with its alpha byte is a number up to 2^32 - 1
rem -- and colortostr$ writes "a $ and the number in hex". Three of those
rem were false past 2^31 - 1:
rem   * color("4294967295") answered -1, and color("2147483648")
rem     -2147483648: the literal was parsed into a 32-bit SIGNED Integer;
rem   * alphacolor("$80FF0000") answered -65536 -- the signed value, OR-ed
rem     with the alpha byte, sign-extended;
rem   * colortostr$(4294967295) answered "$7FFFFFFF": the number was
rem     narrowed with a CLAMP to 2^31 - 1 before it was formatted.
rem A literal outside 0..4294967295 now answers 0, as a name the table does
rem not know does, and colortostr$ formats the whole unsigned value.
rem
rem And environ$("") answered "C:=C:\..." on Windows: the empty name
rem matched the first entry of the environment block, which is one of the
rem hidden per-drive "=C:" entries. A name that is empty, or holds "=" or
rem NUL, is no variable a program can have set, and answers "".
rem
rem The expected numbers are hex written out in decimal beside them.
rem ---------------------------------------------------------------

test_case("sys-r2/a colour literal is read as the unsigned 32-bit number it spells")
rem 2^32 - 1 = 4294967295; $FF0000FF = 4278190080 + 255 = 4278190335.
assert_eq(color("4294967295"), 4294967295, "the largest colour, in decimal")
assert_eq(color("$FFFFFFFF"), 4294967295, "and in hex")
assert_eq(color("2147483648"), 2147483648, "2^31 is a colour, not -2^31")
assert_eq(color("$FF0000FF"), 4278190335, "red with an opaque alpha byte")
assert_eq(color("$00FF00"), 65280, "the six-digit form the page shows still reads")
assert_eq(color("65280"), 65280, "and so does its decimal")
rem Outside 0..2^32 - 1 there is no such colour: 0, as for an unknown name.
assert_eq(color("4294967296"), 0, "2^32 is no colour")
assert_eq(color("$100000000"), 0, "nor is nine hex digits' worth")
assert_eq(color("-1"), 0, "nor a negative number")
assert_eq(color("$FFFFFFFFFFFFFFFF"), 0, "nor sixteen hex digits, which an Int64 reads as -1")
assert_eq(color("99999999999999999999"), 0, "nor a number no Int64 holds")

test_case("sys-r2/alphacolor sets the alpha byte of the whole unsigned value")
rem $80FF0000 or $FF000000 = $FFFF0000 = 4294901760.
assert_eq(alphacolor("$80FF0000"), 4294901760, "an alpha byte already there is made opaque, not sign-extended")
assert_eq(alphacolor("Red"), 4278190335, "the page's own example still holds")
assert_eq(alphacolor("4294967296"), 4278190080, "a literal that is no colour is unknown: opaque black")

test_case("sys-r2/colortostr$ writes the whole unsigned value")
rem 2^31 = $80000000, 2^32 - 1 = $FFFFFFFF.
assert_eq(colortostr$(4294967295), "$FFFFFFFF", "2^32 - 1, not a clamped $7FFFFFFF")
assert_eq(colortostr$(2147483648), "$80000000", "2^31")
assert_eq(colortostr$(4278190335), "$FF0000FF", "red with alpha is not Red: the table holds exact values")
assert_eq(colortostr$(-1), "$FFFFFFFF", "a negative number is its 32-bit pattern, as the page says")
assert_eq(colortostr$(12345), "$003039", "a small one keeps its six-digit padding")
assert_eq(colortostr$(255), "Red", "and a table value its name")
rem Outside -2^31 .. 2^32 - 1 no 32-bit pattern spells the number.
assert_eq(colortostr$(4294967296), "", "2^32 is no colour")
assert_eq(colortostr$(-2147483649), "", "nor is -2^31 - 1")
rem And the two directions are inverses over the whole unsigned range.
bad = 0
v = 0
for i = 1 to 64
  if color(colortostr$(v)) <> v then bad = bad + 1
  v = v * 2 + 1
  if v > 4294967295 then v = 4294967295 - i
next
assert_eq(bad, 0, "color(colortostr$(v)) is v for 2^k - 1 up to 2^32 - 1 and below it")

test_case("sys-r2/an empty name is no environment variable")
assert_eq(environ$(""), "", "the empty name answers empty, not a hidden =C: entry")
assert_eq(environ$("=C:"), "", "a name holding = names no variable a program can set")
assert_eq(environ$("PATH=x"), "", "nor does one with = in the middle")
assert_eq(environ$(chr$(0)), "", "a NUL is the empty name to the OS, and answers empty")
assert_eq(environ$("PATH" + chr$(0) + "X"), "", "and the OS would read PATH out of this name; the program did not ask for PATH")
assert_true(environ$("PATH") <> "", "an ordinary name still answers")
