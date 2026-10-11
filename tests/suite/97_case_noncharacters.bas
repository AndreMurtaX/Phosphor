rem ---------------------------------------------------------------
rem  UNICODE CASE OVER EVERY BYTE: noncharacters and malformed input
rem  (Utf8CaseU in engine/libs/PhosphorStrLib.pas, behind aucase$,
rem  alcase$ and the whole "ignoring case" family).
rem
rem  THE DEFECT. aucase$/alcase$ decoded through the RTL's UTF8Decode,
rem  which writes UNICODE_INVALID -- a '?', byte 3F -- for U+FFFE,
rem  U+FFFF and for every malformed byte. A sweep of all 1112064
rem  encodable codepoints against Python found exactly four wrong
rem  answers, aucase$ and alcase$ of chr$(65534) and chr$(65535).
rem  Through the fold, chr$(65535) "contained" a question mark, the two
rem  noncharacters compared equal under strcmpi, and replacetext$ lost
rem  its place in a string with a stray continuation byte.
rem
rem  EXPECTED VALUES, from Python 3 (unicodedata 15.0), not from a
rem  run: each input's bytes were decoded with
rem  bytes.decode("utf-8", "surrogateescape") -- a malformed byte
rem  becomes a lone surrogate, which has no case mapping -- cased with
rem  str.upper()/str.lower() and encoded back the same way. That is the
rem  Unicode mapping on every character and the identity on every byte
rem  that is not one. U+FFFE, U+FFFF, U+FDD0 and U+10FFFF are general
rem  category Cn (noncharacters): no mapping, so they answer themselves.
rem  The fold-family answers come from the same decode, folded by
rem  str.upper() and searched with str.find/startswith/endswith.
rem
rem  Results are compared as hex digits of their BYTES (hx$), so a '?'
rem  and the character it replaced cannot look alike in a message.
rem  Bytes above 127 are built with bytestr$: chr$ ENCODES a code point.
rem ---------------------------------------------------------------

function hx$(s$) local r$, i%
  r$ = ""
  for i% = 1 to bytelen(s$)
    r$ = r$ + right$("0" + hex$(byteat(s$, i%)), 2)
  next
  return r$
end function

function b2$(a, b)
  return bytestr$(a) + bytestr$(b)
end function

function b3$(a, b, c)
  return bytestr$(a) + bytestr$(b) + bytestr$(c)
end function

test_case("noncharacters/U+FFFE and U+FFFF answer themselves")
assert_eq(hx$(aucase$(chr$(65534))), "EFBFBE", "aucase$ of U+FFFE")
assert_eq(hx$(alcase$(chr$(65534))), "EFBFBE", "alcase$ of U+FFFE")
assert_eq(hx$(aucase$(chr$(65535))), "EFBFBF", "aucase$ of U+FFFF")
assert_eq(hx$(alcase$(chr$(65535))), "EFBFBF", "alcase$ of U+FFFF")
assert_eq(hx$(aucase$("a" + chr$(65535) + "b")), "41EFBFBF42", "the letters around it still map")
assert_eq(hx$(alcase$("A" + chr$(65535) + "B")), "61EFBFBF62", "and the other way")
assert_eq(len(aucase$(chr$(65534) + chr$(65535))), 2, "two characters in, two out")

test_case("noncharacters/the neighbours the RTL already accepted")
assert_eq(hx$(aucase$(chr$(65533))), "EFBFBD", "U+FFFD, the replacement character")
assert_eq(hx$(alcase$(chr$(64976))), "EFB790", "U+FDD0, a noncharacter inside the BMP")
assert_eq(hx$(aucase$(chr$(1114111))), "F48FBFBF", "U+10FFFF, the last noncharacter")
assert_eq(hx$(aucase$(chr$(233))), "C389", "e-acute still maps up")
assert_eq(hx$(alcase$(chr$(201))), "C3A9", "E-acute still maps down")

test_case("malformed/a byte that is not a character is copied, never replaced")
assert_eq(hx$(aucase$(bytestr$(128))), "80", "a lone continuation byte")
assert_eq(hx$(alcase$(bytestr$(255))), "FF", "FF begins nothing")
assert_eq(hx$(aucase$(b2$(192, 175))), "C0AF", "an overlong slash")
assert_eq(hx$(alcase$(b3$(237, 160, 128))), "EDA080", "an encoded surrogate, U+D800")
assert_eq(hx$(aucase$(bytestr$(244) + b3$(144, 128, 128))), "F4908080", "past U+10FFFF")
assert_eq(hx$(aucase$(b2$(227, 129) + "x")), "E38158", "a truncated sequence, then a letter that maps")
assert_eq(hx$(aucase$(chr$(233) + bytestr$(169))), "C389A9", "a stray byte after a character: the character maps, the byte stays")
assert_eq(hx$(alcase$("A" + bytestr$(128))), "6180", "a letter carrying an orphan still maps")
assert_eq(len(alcase$("A" + bytestr$(128))), 1, "and it is still one character to len()")

test_case("fold family/what the noncharacters fold to")
assert_true(containstext("x" + chr$(65535), chr$(65535)) = 1, "U+FFFF is found where it is")
assert_true(containstext("why?", chr$(65534)) = 0, "and U+FFFE is not a question mark")
assert_true(containstext("?", chr$(65535)) = 0, "nor is U+FFFF")
assert_true(strcmpi(chr$(65534), chr$(65535)) <> 0, "the two noncharacters are not equal ignoring case")
assert_true(startstext(chr$(65535) + "z", chr$(65535)) = 1, "a prefix")
assert_true(endstext("?", chr$(65534)) = 0, "not a suffix of a question mark")
assert_eq(hx$(replacetext$("a" + chr$(65535) + "?", chr$(65535), "Z")), "615A3F", "replacetext$ replaces the noncharacter and keeps the question mark")

test_case("fold family/replacetext$ keeps its place on malformed text")
assert_eq(hx$(replacetext$("A" + bytestr$(128) + "b", "a" + bytestr$(128), "Z")), "5A62", "a letter with an orphan byte, matched and replaced, and the b survives")
assert_eq(hx$(replacetext$(chr$(169), bytestr$(169), "X")), "C2A9", "a lone byte is not found inside a character")
assert_eq(hx$(replacetext$("a" + chr$(169), "a" + bytestr$(194), "X")), "61C2A9", "nor does a match END inside one")
end
