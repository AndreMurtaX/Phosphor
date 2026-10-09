rem ---------------------------------------------------------------
rem  JSON, ROUND 4 (2026-10-09): two places where the text a number
rem  was WRITTEN in still did not decide what json_parse@ said about it.
rem
rem  1. AN ERROR ON A LONG NUMBER NAMED A PLACEHOLDER. A number token
rem     longer than 255 bytes is carried past fpjson as a short stand-in
rem     (0e<k>) padded to the token's own length, so every position
rem     AFTER it stays the caller's -- 89_json_number_text.bas pins that.
rem     But when the error was raised ON the stand-in itself -- a number
rem     where a colon, a comma or a member name belongs -- the message
rem     quoted "0e0", a token the caller never wrote, at the column
rem     where the stand-in ended, before its padding: Pos 8 for an
rem     error at Pos 306.
rem
rem  2. -0 READ AS +0. The engine's one reader of number text says -0
rem     is a Double negative zero (language-reference.md, number text),
rem     and so does IEEE 754 and ECMAScript's JSON.parse. fpjson read
rem     the INTEGER token -0 through TryStrToInt64 as the integer 0, so
rem     json_getn answered +0 and json_stringify$ wrote 0 -- while
rem     "-0" as a string, -0.0, val("-0") and the same zero spelled with
rem     280 more zeros all read -0. The same sign was lost on the way IN:
rem     json_setn@ of a -0 stored the integer 0.
rem     And the long spelling of an INTEGER token (fpjson is lenient and
rem     takes leading zeros) came back a Double where the short one is
rem     an exact integer: 9007199254740993 lost its last digit.
rem
rem  EXPECTED VALUES, independent of the engine:
rem   - The messages are fpjson's own format strings, read in
rem     packages/fcl-json/src/jsonreader.pp: SErrorAt is
rem     'Error at line %d, Pos %d: ', and the column is where the
rem     offending token ENDS, 1-based -- the short controls below are
rem     asserted against the same template first, so the template is
rem     checked before it is used. Each long position is that rule
rem     applied by arithmetic: z$ is 301 bytes ("1" and 300 zeros).
rem   - -0 is the Double whose only set bit is the sign: as a signed
rem     64-bit integer, -2^63, written below as -9223372036854775807 - 1.
rem ---------------------------------------------------------------

b@ = buffer_new@(8)
function bits%(x) local z
  z = buffer_setdbl(b@, 1, x)
  return buffer_getint(b@, 1, 8)
endfunction

q$ = chr$(34)
bs$ = chr$(92)
lf$ = chr$(10)
z$ = "1" + mulstring$("0", 300)
nz% = -9223372036854775807 - 1
pre$ = "invalid json: Error at line "
colon$ = "Expected colon (:), got token "
comma$ = "Expected comma (,) or square bracket (]), got token "
name$ = "Expected element name, got token "

test_case("the short controls fix the template")
pt$ = "{" + q$ + "a" + q$ + " 1}"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 6: " + colon$ + q$ + "1" + q$ + ".", "a number where the colon belongs")
pt$ = "[1, 2 1]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 7: " + comma$ + q$ + "1" + q$ + ".", "a number where a comma belongs")
rem The colon is spaced off: fpjson's scanner refuses a number glued to
rem anything but whitespace, a comma or a closing bracket, as its own
rem error at that byte, before the parser could say anything.
pt$ = "{1 : 2}"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 2: " + name$ + q$ + "1" + q$, "a number where a name belongs")
pt$ = "[1 .5]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 5: " + comma$ + q$ + "0.5" + q$ + ".", ".5 is quoted as the scanner reads it, 0.5")
pt$ = "[1," + lf$ + "2 1]"
gosub tryparse
assert_eq(pm$, pre$ + "2, Pos 3: " + comma$ + q$ + "1" + q$ + ".", "a column counts from its own line")

test_case("an error AT a long number names it, where it ends")
pt$ = "{" + q$ + "a" + q$ + " " + z$ + "}"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 306: " + colon$ + q$ + z$ + q$ + ".", "where the colon belongs: 5 + 301")
pt$ = "[1, 2 " + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 307: " + comma$ + q$ + z$ + q$ + ".", "where a comma belongs: 6 + 301")
pt$ = "[" + z$ + " " + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 604: " + comma$ + q$ + z$ + q$ + ".", "the second of two: 1 + 301 + 1 + 301")
pt$ = "[0e0 " + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 306: " + comma$ + q$ + z$ + q$ + ".", "after a real 0e0, and not a stand-in 0e1")
pt$ = "{" + z$ + " : 1}"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 302: " + name$ + q$ + z$ + q$, "where a member name belongs: 1 + 301")
pt$ = "[1 -" + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 305: " + comma$ + q$ + "-" + z$ + q$ + ".", "a negative one: 3 + 302")
f$ = mulstring$("5", 300)
pt$ = "[1 ." + f$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 304: " + comma$ + q$ + "0." + f$ + q$ + ".", "a leading dot, quoted as 0. as the short one is: 3 + 301")
pt$ = "[1," + lf$ + "2 " + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "2, Pos 303: " + comma$ + q$ + z$ + q$ + ".", "on line 2: 2 + 301")
pt$ = "[" + q$ + bs$ + "u00e9" + q$ + " " + z$ + "]"
gosub tryparse
assert_eq(pm$, pre$ + "1, Pos 311: " + comma$ + q$ + z$ + q$ + ".", "in a document carrying a \\u escape: 10 + 301")
pt$ = "[" + z$ + ", 2 x]"
gosub tryparse
assert_eq(instr(pm$, "Pos 307"), len(pre$) + 4, "an error AFTER a long number is still where it was")

test_case("-0 in a document is a negative zero")
j@ = json_parse@("{" + q$ + "n" + q$ + ": -0, " + q$ + "s" + q$ + ": " + q$ + "-0" + q$ + ", " + q$ + "f" + q$ + ": -0.0}")
assert_int(bits%(json_getn(j@, "n")), nz%, "json_getn of the number -0")
assert_int(bits%(json_pathn(j@, "n")), nz%, "json_pathn")
assert_int(bits%(json_value(json_get@(j@, "n"))), nz%, "json_value")
assert_int(bits%(json_getn(j@, "s")), nz%, "the string -0 agrees")
assert_int(bits%(json_getn(j@, "f")), nz%, "and -0.0 agrees")
assert_int(bits%(val("-0")), nz%, "and val agrees")
assert_int(bits%(json_itemn(json_parse@("[-0]"), 1)), nz%, "an array element")
assert_int(bits%(json_value(json_parse@("-0"))), nz%, "a whole document")
assert_int(bits%(json_itemn(json_parse@("[-00]"), 1)), nz%, "spelled -00, which fpjson takes")
assert_int(bits%(json_itemn(json_parse@("[-" + mulstring$("0", 280) + "0]"), 1)), nz%, "spelled long")
assert_int(bits%(json_itemn(json_parse@("[0, -0e0, 0.0]"), 1)), 0, "while 0 is +0")
assert_int(bits%(json_itemn(json_parse@("[0, -0e0, 0.0]"), 2)), nz%, "-0e0 is -0")
assert_int(bits%(json_itemn(json_parse@("[0, -0e0, 0.0]"), 3)), 0, "0.0 is +0")

test_case("-0 survives the round trip through text")
s$ = json_stringify$(json_parse@("[-0]"))
assert_eq(left$(s$, 2), "[-", "it is written with its sign")
assert_int(bits%(json_itemn(json_parse@(s$), 1)), nz%, "and reads back -0")
assert_eq(json_stringify$(json_parse@("[0, -5, 7]")), "[0, -5, 7]", "integers are still written as integers")

test_case("-0 put into a tree keeps its sign")
nzd = val("-0")
o@ = json_object@()
o@ = json_setn@(o@, "a", nzd)
o@ = json_setval@(o@, "b", nzd)
o@ = json_setn@(o@, "c", 0)
assert_int(bits%(json_getn(o@, "a")), nz%, "json_setn@")
assert_int(bits%(json_getn(o@, "b")), nz%, "json_setval@")
assert_int(bits%(json_getn(o@, "c")), 0, "and 0 stays +0")
a@ = json_array@()
a@ = json_pushn@(a@, nzd)
a@ = json_pushval@(a@, nzd)
assert_int(bits%(json_itemn(a@, 1)), nz%, "json_pushn@")
assert_int(bits%(json_itemn(a@, 2)), nz%, "json_pushval@")
assert_int(bits%(json_value(json_number@(nzd))), nz%, "json_number@")
k@ = json_parse@(json_stringify$(o@))
assert_int(bits%(json_getn(k@, "a")), nz%, "through text, json_setn@'s")
assert_int(bits%(json_getn(k@, "c")), 0, "through text, the +0")
assert_eq(json_stringify$(json_number@(0)), "0", "a +0 is still the integer 0")

test_case("an integer spelled long is the integer spelled short")
rem fpjson takes leading zeros. The short spelling is read exactly, as
rem an integer; past 255 bytes it went through the Double reader and
rem 9007199254740993 (2^53 + 1) lost its last digit.
j@ = json_parse@("[09007199254740993, " + mulstring$("0", 280) + "9007199254740993]")
assert_eq(json_stringify$(j@), "[9007199254740993, 9007199254740993]", "both keep every digit")
j@ = json_parse@("[-" + mulstring$("0", 280) + "5, " + mulstring$("0", 280) + "18446744073709551615]")
assert_eq(json_stringify$(j@), "[-5, 18446744073709551615]", "a negative one, and one past Int64")
assert_eq(json_typename$(json_item@(j@, 1)), "number", "still a number")

end

rem pt$ in, pm$ out: the refusal's message, or "" when it parsed. The
rem trap covers the parse alone and is off before anything is asserted.
tryparse:
pm$ = ""
on error goto tryfail
pj@ = json_parse@(pt$)
on error goto 0
return

tryfail:
pm$ = errmsg$()
resume next
