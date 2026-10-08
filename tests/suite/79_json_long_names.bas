rem ---------------------------------------------------------------
rem A JSON MEMBER NAME IS AT MOST 255 BYTES, AND A LONGER ONE IS REFUSED,
rem NEVER TRUNCATED (2026-10-08, a third adversarial pass; the defect
rem predates every change that day).
rem
rem fpjson keeps an object's names in a hash list whose keys are Pascal
rem ShortStrings -- its own source says "Names limited to 255 chars". Past
rem that a name was cut to its first 255 bytes in silence, so two distinct
rem 261-byte keys that share those bytes were ONE member: the second
rem write replaced the first, both reads answered the second, and a
rem parsed document holding both was refused as a "Duplicate object
rem member" it did not contain. A name the tree cannot hold faithfully is
rem now refused at every door that writes one and every parse, and a
rem lookup by such a name finds nothing -- a truncated lookup would have
rem found the member named by its first 255 bytes.
rem
rem The limit is in BYTES OF THE DECODED NAME, which is what is stored: a
rem é escape is six characters of text and two bytes of name, so a
rem name whose text is long can still be short enough.
rem ---------------------------------------------------------------

q$ = chr$(34)
a255$ = string$(255, 97)
a256$ = string$(256, 97)
raised = 0
msg$ = ""

test_case("names/255 bytes is a name, and 256 is refused at the setter")
o@ = json_object@()
o@ = json_sets@(o@, a255$, "fits")
assert_eq(json_gets$(o@, a255$), "fits", "a 255-byte name is stored and found")
on error goto trapped
o@ = json_sets@(o@, a256$, "too long")
on error goto 0
assert_eq(raised, 1, "a 256-byte name is refused")
assert_eq(msg$, "a json member name is at most 255 bytes, and this one is 256", "and the error says the sizes")
assert_eq(json_count(o@), 1, "and nothing was stored")

test_case("names/a lookup by a longer name finds nothing, not its first 255 bytes")
assert_eq(json_has(o@, a256$), 0, "json_has does not answer for the 255-byte member")
assert_eq(json_gets$(o@, a256$, "absent"), "absent", "nor does json_gets$")
o@ = json_remove@(o@, a256$)
assert_eq(json_count(o@), 1, "and json_remove@ does not remove it")
assert_eq(json_paths$(o@, a256$, "absent"), "absent", "and a path does not reach it")

test_case("names/the parser refuses a name it could not keep")
raised = 0
on error goto trapped
p@ = json_parse@("{" + q$ + a256$ + q$ + ":1}")
on error goto 0
assert_eq(raised, 1, "a 256-byte name in a document is refused")
assert_eq(left$(msg$, 50), "invalid json: a member name is longer than 255 byt", "as a member name too long")
rem 300 characters of text, each a escape six characters of text and
rem one byte of name: 50 escapes are 300 characters and 50 bytes.
esc$ = ""
for i = 1 to 50
  esc$ = esc$ + "\\u0061"
next
p@ = json_parse@("{" + q$ + esc$ + q$ + ":1}")
assert_eq(json_count(p@), 1, "a name whose TEXT is long and whose bytes are few is accepted")
assert_eq(json_getn(p@, string$(50, 97)), 1, "and found by the name it decodes to")
rem A long STRING VALUE is not a name and has no such limit.
v@ = json_parse@("{" + q$ + "k" + q$ + ":" + q$ + a256$ + q$ + "}")
assert_eq(len(json_gets$(v@, "k")), 256, "a long value is kept whole")
end

trapped:
raised = 1
msg$ = errmsg$()
resume next
