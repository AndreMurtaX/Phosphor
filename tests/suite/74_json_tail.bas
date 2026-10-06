rem ---------------------------------------------------------------
rem THE PARSER READS ONE VALUE, AND SO DO THE CHECKS AROUND IT.
rem
rem fpjson parses the first JSON value and ignores anything after it
rem (its garbage check runs only under joStrict, which json_parse@ does
rem not set). Three scanners in front of it used to judge the WHOLE
rem text anyway:
rem   * the escape repair re-spelled every literal, so one it could not
rem     handle in the unread tail -- an unmatched quote -- abandoned the
rem     whole repair, and the u0000 escape it exists to keep came back
rem     with the NUL gone (ledger d08);
rem   * the depth guard counted brackets in the tail, so a valid
rem     one-level object followed by 300 open brackets was REFUSED as
rem     nesting too deep (ledger n9).
rem Both now stop where the parser stops. The last cases keep the guard
rem honest: nesting INSIDE the value is still refused.
rem
rem Backslashes are built with chr$(92), never written in a literal --
rem a backslash in a BASIC string literal is an escape (CLAUDE.md).
rem ---------------------------------------------------------------

bs$ = chr$(92)
qt$ = chr$(34)
doc$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + "x" + bs$ + "u0000y" + qt$ + "}"

test_case("json-tail/the escape repair survives an unmatched quote in the tail")
assert_eq(json_gets$(json_parse@(doc$), "k"), "x" + bytestr$(0) + "y", "alone, the NUL is kept")
assert_eq(json_gets$(json_parse@(doc$ + " " + qt$), "k"), "x" + bytestr$(0) + "y", "with a stray quote after the value, the NUL is still kept")
assert_eq(bytelen(json_gets$(json_parse@(doc$ + " " + qt$), "k")), 3, "three bytes, not two")
assert_eq(json_gets$(json_parse@(doc$ + " " + qt$ + bs$ + "q"), "k"), "x" + bytestr$(0) + "y", "and with an undefined escape in the tail")

test_case("json-tail/brackets in the tail are not nesting")
open$ = string$(300, 91)
assert_eq(json_getn(json_parse@("{" + qt$ + "a" + qt$ + ":1}" + open$), "a"), 1, "a valid object followed by 300 open brackets parses")

test_case("json-tail/nesting inside the value is still refused")
caught% = 0
msg$ = ""
on error goto deep
j@ = json_parse@(open$)
goto after_deep
deep:
caught% = 1
msg$ = errmsg$()
resume next
after_deep:
on error goto 0
assert_eq(caught%, 1, "300 levels of the value itself are refused")
assert_true(instr(msg$, "nests more than 256"), "for nesting, and it says so")
