rem ---------------------------------------------------------------
rem JSON must carry bytes, and a borrowed handle must not outlive
rem what it borrowed.
rem
rem fpjson's own serializer is not byte-exact: StringToJSONString --
rem the escaper every AsJSON/FormatJSON path goes through -- returned
rem SEVEN bytes for a five-byte string, re-encoding the UTF-8 pair
rem C3 A9 as C3 83 C2 A9. The tree HELD the right bytes, so a
rem json_gets$ round trip looked perfect while the text written to a
rem file was mojibake. Phosphor renders its own JSON now.
rem
rem Separately, TJSONArray.Add(String) -- and only that overload, of
rem the several measured -- corrupted on the way IN.
rem ---------------------------------------------------------------

test_case("json/a non-ASCII value survives the round trip through TEXT")
v$ = "caf" + chr$(233)
assert_eq(bytelen(v$), 5, "four characters, five bytes")
o@ = json_object@()
json_sets@(o@, "k", v$)
assert_eq(json_gets$(o@, "k"), v$, "the tree always held the right bytes")
t$ = json_stringify$(o@)
assert_eq(bytelen(t$), 17, "and the TEXT is no longer two bytes longer than it should be")
back@ = json_parse@(t$)
assert_eq(json_gets$(back@, "k"), v$, "so what is written parses back identical")

test_case("json/an array element survives the store as well as the render")
a@ = json_array@()
json_pushs@(a@, v$)
assert_eq(json_items$(a@, 1), v$, "TJSONArray.Add(String) used to store 7 bytes for 5")
assert_eq(bytelen(json_items$(a@, 1)), 5, "byte for byte")

test_case("json/a non-ASCII KEY can be written and read back")
rem A LIMIT, stated rather than hidden: fpjson keeps member names in a hash whose
rem key type goes through the system code page, so Names[] hands back a name that
rem has been converted -- losslessly where the code page is UTF-8, lossily where it
rem is not. Setting and getting by the same key is symmetric and works everywhere,
rem which is what this pins. Writing such a key OUT to text and reading it back does
rem NOT round trip on a non-UTF-8 system code page; that belongs to fcl-json, not to
rem Phosphor, and pretending otherwise with a platform-dependent golden would be
rem worse than saying so. Non-ASCII VALUES round trip exactly -- see the cases above.
k@ = json_object@()
json_sets@(k@, v$, "x")
assert_eq(json_gets$(k@, v$), "x", "a non-ASCII key reads back through the same call")
json_sets@(k@, v$, "y")
assert_eq(json_gets$(k@, v$), "y", "and updates the same member rather than adding one")
assert_eq(json_count(k@), 1, "one member, not two")

test_case("json/the rendered shape is unchanged for ASCII")
s@ = json_object@()
json_sets@(s@, "s", "txt")
json_setn@(s@, "n", 42)
assert_eq(json_stringify$(s@), "{ \"s\" : \"txt\", \"n\" : 42 }", "same text as before")
assert_eq(json_stringify$(json_object@()), "{}", "an empty object")
assert_eq(json_stringify$(json_array@()), "[]", "and an empty array")

test_case("json/escapes are still escapes")
e@ = json_object@()
json_sets@(e@, "q", "a\"b\\c")
assert_eq(json_gets$(json_parse@(json_stringify$(e@)), "q"), "a\"b\\c", "quote and backslash round trip")
json_sets@(e@, "q", "line" + chr$(10) + "break" + chr$(9) + "tab")
assert_eq(json_gets$(json_parse@(json_stringify$(e@)), "q"), "line" + chr$(10) + "break" + chr$(9) + "tab", "control characters too")

test_case("json/a borrowed handle is told when what it borrowed is gone")
rem It used to point into freed memory: reading it was an access violation.
p@ = json_object@()
json_sets@(p@, "a", "first")
c@ = json_get@(p@, "a")
assert_eq(json_value$(c@), "first", "the borrow works while it is valid")
json_sets@(p@, "a", "second")
stale% = 0
on error goto hs
x$ = json_value$(c@)
goto afters
hs:
stale% = 1
resume next
afters:
on error goto 0
assert_eq(stale%, 1, "reading the replaced value is a clean error")
assert_eq(json_gets$(p@, "a"), "second", "and the parent is untouched")

test_case("json/a handle borrowed from DEEP inside a replaced subtree too")
d@ = json_parse@("{\"a\":{\"b\":1}}")
g@ = json_get@(d@, "a")
n@ = json_get@(g@, "b")
json_sets@(d@, "a", "x")
stale2% = 0
on error goto hs2
z = json_value(n@)
goto afters2
hs2:
stale2% = 1
resume next
afters2:
on error goto 0
assert_eq(stale2%, 1, "the grandchild is invalidated with its parent")

test_case("json/json_value reads any node without raising")
rem It called AsFloat on whatever it was given, so a string node aborted the
rem program with the RTL's own 'Invalid float value : hello'.
assert_eq(json_value(json_string@("hello")), 0, "a non-numeric string reads as 0")
assert_eq(json_value(json_string@("42")), 42, "a numeric string reads as its number")
assert_eq(json_value(json_object@()), 0, "an object reads as 0")
assert_eq(json_value(json_array@()), 0, "and an array too")
assert_eq(json_value(json_number@(7)), 7, "while a number is itself")
