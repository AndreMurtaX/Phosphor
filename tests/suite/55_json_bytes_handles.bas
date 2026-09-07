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
assert_eq(bytelen(t$), 13, "and the TEXT is no longer two bytes longer than it should be")
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

test_case("json/the rendered shape, now genuinely compact")
s@ = json_object@()
json_sets@(s@, "s", "txt")
json_setn@(s@, "n", 42)
rem COMPACT, which is the word the reference has always used. Objects used to
rem emit "{ ", " : " and " }" while the array branch of the same renderer was
rem already compact, so objects were the inconsistency rather than the format --
rem and json_pretty$ is what exists for the readable rendering.
assert_eq(json_stringify$(s@), "{\"s\":\"txt\",\"n\":42}", "no padding: this is the wire form")
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

test_case("json/every byte 0..255 survives a value round trip through TEXT")
rem THE SWEEP, not a list of values somebody picked. fpjson's scanner decodes a
rem u-escape itself, and it was wrong four ways at once -- all one mechanism,
rem jsonscanner.pp holding a pending escape in u1 and using ZERO for "nothing
rem pending", inside a four-byte ShortString, through an ambient code page:
rem
rem   * a u0000 escape was DROPPED. A NUL the library had itself just written
rem     as text could not be read back, and nothing said a word.
rem   * a lone surrogate escape was dropped too.
rem   * two ADJACENT escapes were decoded into that one four-byte ShortString,
rem     so two three-byte characters came back as four bytes -- not merely
rem     short, not valid UTF-8 either.
rem   * and which of the scanner's two branches ran was decided by
rem     DefaultSystemCodePage, a process-wide global no script can see. The two
rem     hosts in this repository disagreed about the same document, because
rem     phosphor.exe links the LCL (which sets that global to UTF-8) and
rem     phosphortest.exe does not.
rem
rem The escapes are decoded on the Phosphor side now, for the mirror image of
rem the reason the serializer above was hand-written. Four positions are swept
rem because the NUL used to survive in exactly one of them: only when another
rem escape stood immediately in front of it.
lost = 0
firstbad$ = ""
for p = 1 to 4
  for b = 0 to 255
    if p = 1 then v$ = bytestr$(b)
    if p = 2 then v$ = bytestr$(b) + "z"
    if p = 3 then v$ = "a" + bytestr$(b)
    if p = 4 then v$ = "a" + bytestr$(b) + "z"
    o@ = json_object@()
    json_sets@(o@, "k", v$)
    if json_gets$(json_parse@(json_stringify$(o@)), "k") <> v$ then
      lost = lost + 1
      if firstbad$ = "" then firstbad$ = " -- first at byte " + str$(b) + " in position " + str$(p)
    endif
  next
next
assert_eq(lost, 0, "1024 value round trips" + firstbad$)

test_case("json/a byte doubled, and every byte beside a NUL")
rem What stood NEXT to the NUL decided whether it survived, because the NUL was
rem carried in the scanner's pending-escape slot: "byte then NUL" came back for
rem the 26 bytes our writer spells as a u-escape and was lost for the other 230,
rem while "NUL then byte" was lost for all 256. Both directions, every byte.
lost = 0
for b = 0 to 255
  o@ = json_object@()
  json_sets@(o@, "d", bytestr$(b) + bytestr$(b))
  json_sets@(o@, "bn", bytestr$(b) + bytestr$(0))
  json_sets@(o@, "nb", bytestr$(0) + bytestr$(b))
  q@ = json_parse@(json_stringify$(o@))
  if json_gets$(q@, "d") <> bytestr$(b) + bytestr$(b) then lost = lost + 1
  if json_gets$(q@, "bn") <> bytestr$(b) + bytestr$(0) then lost = lost + 1
  if json_gets$(q@, "nb") <> bytestr$(0) + bytestr$(b) then lost = lost + 1
next
assert_eq(lost, 0, "768 adjacency round trips")

test_case("json/every ASCII key byte survives a round trip through TEXT")
rem 0..127, and the ceiling is deliberate: the case above already records the
rem pre-existing fcl-json limit for a key byte of 128 or more -- member names
rem live in a hash whose key type goes through the system code page, so such a
rem key is exact where that code page is UTF-8 and lossy where it is not.
rem Measured on this build: bytes 128..255 lose the key under phosphortest.exe
rem and keep it under phosphor.exe. That is fcl-json's hash, not the escape
rem decoding this file's sweep is about, and pinning it either way would pin a
rem platform. A NUL in a key IS in the range pinned here, and it used to be
rem lost like every other u0000.
lost = 0
for b = 0 to 127
  k$ = "a" + bytestr$(b) + "z"
  o@ = json_object@()
  json_sets@(o@, k$, "v")
  if json_gets$(json_parse@(json_stringify$(o@)), k$) <> "v" then lost = lost + 1
next
assert_eq(lost, 0, "128 key round trips")

test_case("json/every escape the standard defines, arriving as foreign text")
rem json_parse@ is the one function in this library whose input is written by
rem somebody else, so the escapes are swept as TEXT here rather than through
rem our own writer.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "b" + post$), "k"), chr$(8), "b is a backspace")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "t" + post$), "k"), chr$(9), "t is a tab")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "n" + post$), "k"), chr$(10), "n is a newline")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "f" + post$), "k"), chr$(12), "f is a form feed")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "r" + post$), "k"), chr$(13), "r is a return")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "/" + post$), "k"), "/", "a slash may be escaped")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + qt$ + post$), "k"), qt$, "and a quote must be")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + bs$ + post$), "k"), bs$, "and a backslash")

test_case("json/a u0000 escape in foreign text, in every position")
rem The finding this whole sweep grew out of: our own writer emits this escape
rem and the reader threw it away.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
z$ = bs$ + "u0000"
a$ = bs$ + "u0041"
assert_eq(json_gets$(json_parse@(pre$ + z$ + post$), "k"), bytestr$(0), "alone")
assert_eq(json_gets$(json_parse@(pre$ + z$ + "ab" + post$), "k"), bytestr$(0) + "ab", "at the start")
assert_eq(json_gets$(json_parse@(pre$ + "a" + z$ + "b" + post$), "k"), "a" + bytestr$(0) + "b", "in the middle")
assert_eq(json_gets$(json_parse@(pre$ + "ab" + z$ + post$), "k"), "ab" + bytestr$(0), "at the end")
assert_eq(json_gets$(json_parse@(pre$ + z$ + z$ + post$), "k"), bytestr$(0) + bytestr$(0), "twice over")
assert_eq(json_gets$(json_parse@(pre$ + a$ + z$ + post$), "k"), "A" + bytestr$(0), "after another escape")
assert_eq(json_gets$(json_parse@(pre$ + z$ + a$ + post$), "k"), bytestr$(0) + "A", "before another escape")

test_case("json/two adjacent escapes are not truncated to four bytes")
rem A PAIR of escapes was decoded into `S : String[4]`, so anything needing
rem more than four bytes between them lost the tail: two U+0800 came back as
rem E0 A0 80 E0, and U+0800 followed by an emoji came back as three bytes with
rem the emoji gone entirely.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
e8$ = bs$ + "u0800"
e9$ = bs$ + "u00e9"
ff$ = bs$ + "uffff"
hi$ = bs$ + "ud83d"
lo$ = bs$ + "ude00"
u800$ = bytestr$(224) + bytestr$(160) + bytestr$(128)
uffff$ = bytestr$(239) + bytestr$(191) + bytestr$(191)
uemoji$ = bytestr$(240) + bytestr$(159) + bytestr$(152) + bytestr$(128)
ue9$ = bytestr$(195) + bytestr$(169)
assert_eq(json_gets$(json_parse@(pre$ + e8$ + post$), "k"), u800$, "one U+0800 is three bytes")
assert_eq(json_gets$(json_parse@(pre$ + e8$ + e8$ + post$), "k"), u800$ + u800$, "two of them are six")
assert_eq(json_gets$(json_parse@(pre$ + e8$ + e8$ + e8$ + post$), "k"), u800$ + u800$ + u800$, "three are nine")
assert_eq(json_gets$(json_parse@(pre$ + ff$ + ff$ + post$), "k"), uffff$ + uffff$, "two U+FFFF as well")
assert_eq(json_gets$(json_parse@(pre$ + e9$ + e8$ + post$), "k"), ue9$ + u800$, "a two-byte then a three-byte")
assert_eq(json_gets$(json_parse@(pre$ + e8$ + e9$ + post$), "k"), u800$ + ue9$, "and the other way round")

test_case("json/surrogates: a pair is one character, a lone one is replaced")
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
e8$ = bs$ + "u0800"
hi$ = bs$ + "ud83d"
lo$ = bs$ + "ude00"
u800$ = bytestr$(224) + bytestr$(160) + bytestr$(128)
uemoji$ = bytestr$(240) + bytestr$(159) + bytestr$(152) + bytestr$(128)
urepl$ = bytestr$(239) + bytestr$(191) + bytestr$(189)
assert_eq(json_gets$(json_parse@(pre$ + hi$ + lo$ + post$), "k"), uemoji$, "a pair is four UTF-8 bytes")
assert_eq(json_gets$(json_parse@(pre$ + e8$ + hi$ + lo$ + post$), "k"), u800$ + uemoji$, "and survives what stands before it")
assert_eq(json_gets$(json_parse@(pre$ + hi$ + lo$ + e8$ + post$), "k"), uemoji$ + u800$, "and what stands after it")
rem A surrogate with no partner denotes no character and has no UTF-8 spelling.
rem U+FFFD is what the standard's guidance puts there; it used to vanish, which
rem is the same silent loss as the NUL and is what this pins against.
assert_eq(json_gets$(json_parse@(pre$ + hi$ + post$), "k"), urepl$, "a lone high surrogate is replaced")
assert_eq(json_gets$(json_parse@(pre$ + lo$ + post$), "k"), urepl$, "a lone low surrogate too")
assert_eq(json_gets$(json_parse@(pre$ + hi$ + "x" + post$), "k"), urepl$ + "x", "and what follows it is kept")

test_case("json/the two hosts read the same document the same way")
rem This is the assertion that fails on ONE binary and passes on the other when
rem the decoding is fpjson's: under phosphortest.exe, which does not link the
rem LCL, a u00e9 escape used to read back as the single byte E9 and a u0800
rem escape as a question mark, while phosphor.exe read both correctly. Same
rem engine, same document, different answer.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "u00e9" + post$), "k"), bytestr$(195) + bytestr$(169), "u00e9 is C3 A9 on any host")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "u0800" + post$), "k"), bytestr$(224) + bytestr$(160) + bytestr$(128), "u0800 is E0 A0 80 on any host")

test_case("json/a raw 01 or 02 byte is not mistaken for the NUL marker")
rem The NUL has no spelling fpjson can read back -- a u0000 escape is dropped
rem and a raw NUL ends its scan -- so it travels as a two-escape marker, with
rem byte 01 given a second marker so the code stays a prefix code. A document
rem carrying BOTH a u-escape and raw 01/02 bytes is where a sloppy marker would
rem show, so it is pinned here rather than reasoned about.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
mix$ = bs$ + "u0001" + bs$ + "u0002" + bs$ + "u0000" + bs$ + "u0001" + bs$ + "u0001"
want$ = bytestr$(1) + bytestr$(2) + bytestr$(0) + bytestr$(1) + bytestr$(1)
assert_eq(json_gets$(json_parse@(pre$ + mix$ + post$), "k"), want$, "01 02 00 01 01 all come back")
rem And the same five bytes through the writer rather than typed as escapes.
o@ = json_object@()
json_sets@(o@, "k", want$)
assert_eq(json_gets$(json_parse@(json_stringify$(o@)), "k"), want$, "and round trip through our own text")
rem A key made of them, too: keys are re-spelled by the same rewrite and are
rem the half of a tree fpjson gives no way to rename.
p@ = json_object@()
json_sets@(p@, want$, "v")
assert_eq(json_gets$(json_parse@(json_stringify$(p@)), want$), "v", "a key of marker bytes as well")

test_case("json/a document that needs no rewrite is still parsed as it was")
rem The rewrite engages only for a document that actually carries a u-escape,
rem so everything else reaches fpjson byte for byte as before -- including a
rem raw 01 byte, which must NOT be read as a marker when no rewrite happened.
qt$ = chr$(34)
raw$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + bytestr$(1) + bytestr$(1) + qt$ + "}"
assert_eq(json_gets$(json_parse@(raw$), "k"), bytestr$(1) + bytestr$(1), "two raw 01 bytes stay two raw 01 bytes")

test_case("json/a malformed escape is still fpjson's error to report")
rem A document this cannot re-spell faithfully is handed over untouched, so the
rem wording of the refusal is the parser's own and this change cannot invent
rem one. Both doors: an escape the standard does not define, and a short one.
bs$ = chr$(92)
qt$ = chr$(34)
pre$ = "{" + qt$ + "k" + qt$ + ":" + qt$
post$ = qt$ + "}"
badesc = 0
on error goto beg1
w@ = json_parse@(pre$ + bs$ + "x" + post$)
goto beg2
beg1:
badesc = 1
resume next
beg2:
on error goto 0
assert_eq(badesc, 1, "an undefined escape is refused")
shortu = 0
on error goto beg3
y@ = json_parse@(pre$ + bs$ + "u12" + post$)
goto beg4
beg3:
shortu = 1
resume next
beg4:
on error goto 0
assert_eq(shortu, 1, "and a u-escape with too few digits")

test_case("json/a restored NUL reaches every shape it can sit in")
rem The rewrite is undone by a walk over the parsed tree, so the walk is pinned
rem against every shape rather than against the object-with-one-member that the
rem finding happened to use. The member NAME is the one that needs real work:
rem fpjson keeps names in a hash and offers no rename, so an object carrying a
rem marked name is emptied with Extract and refilled -- and the refill must not
rem disturb the order, which is what the last assertion here reads.
bs$ = chr$(92)
qt$ = chr$(34)
z$ = bs$ + "u0000"
nul$ = bytestr$(0)
assert_eq(json_value$(json_parse@(qt$ + "a" + z$ + "b" + qt$)), "a" + nul$ + "b", "a bare string is the whole document")
arr@ = json_parse@("[" + qt$ + z$ + qt$ + "," + qt$ + "x" + z$ + qt$ + "]")
assert_eq(json_items$(arr@, 1), nul$, "an array element")
assert_eq(json_items$(arr@, 2), "x" + nul$, "and the one after it")
deep$ = "{" + qt$ + "a" + qt$ + ":{" + qt$ + "b" + qt$ + ":[{" + qt$ + "c" + qt$ + ":" + qt$ + "n" + z$ + qt$ + "}]}}"
deep@ = json_parse@(deep$)
assert_eq(json_gets$(json_item@(json_path@(deep@, "a.b"), 1), "c"), "n" + nul$, "a value three levels down")
key@ = json_parse@("{" + qt$ + "k" + z$ + "1" + qt$ + ":7," + qt$ + "plain" + qt$ + ":8}")
assert_eq(json_count(key@), 2, "an object with a marked key still has both members")
assert_eq(json_getn(key@, "k" + nul$ + "1", -1), 7, "and the marked key reads back")
assert_eq(json_getn(key@, "plain", -1), 8, "and so does the one beside it")
assert_eq(json_items$(json_keys@(key@), 1), "k" + nul$ + "1", "json_keys@ hands the name back whole")
assert_eq(json_items$(json_keys@(key@), 2), "plain", "in the order the document had it")

test_case("json/a single-quoted literal is rewritten too, or the markers lie")
rem THE DOCUMENT THAT TURNS THE FIX ABOVE INTO THE DEFECT IT WAS FIXING.
rem fpjson opens a string on a DOUBLE quote OR on a SINGLE one -- the single
rem quote is its own extension (jsonscanner.pp:314), refused only under
rem joStrict, which json_parse@ does not set. The rewrite knew about double
rem quotes alone, so a single-quoted literal reached the parsed tree WITHOUT
rem having been re-spelled, while the walk that undoes the markers still went
rem over it. Byte 01 is what the marker scheme reserves and it is a byte real
rem data can hold, so a sentinel scanned for after the fact cannot tell what
rem the rewrite wrote from what was already there: an all-printable-ASCII
rem document carrying no NUL at all had one PUT INTO IT. Same silent
rem corruption as the defect above, arrow reversed. Pinned as bytes.
bs$ = chr$(92)
qt$ = chr$(34)
sq$ = chr$(39)
trig$ = qt$ + "t" + qt$ + ":" + qt$ + bs$ + "u0041" + qt$ + ","
one$ = bs$ + "u0001"
two$ = bs$ + "u0002"
d1$ = "{" + trig$ + sq$ + "k" + sq$ + ":" + sq$ + one$ + one$ + sq$ + "}"
assert_eq(json_gets$(json_parse@(d1$), "k"), bytestr$(1) + bytestr$(1), "01 01 in a single-quoted value stays 01 01")
d2$ = "{" + trig$ + sq$ + "k" + sq$ + ":" + sq$ + one$ + two$ + sq$ + "}"
assert_eq(json_gets$(json_parse@(d2$), "k"), bytestr$(1) + bytestr$(2), "and 01 02 stays 01 02, with no byte deleted")
d3$ = "{" + trig$ + sq$ + "k" + sq$ + ":" + sq$ + bytestr$(1) + bytestr$(1) + sq$ + "}"
assert_eq(json_gets$(json_parse@(d3$), "k"), bytestr$(1) + bytestr$(1), "raw 01 bytes as well as escaped ones")
rem The KEY: it is renamed through Extract and refilled, so a manufactured NUL
rem would travel out through json_keys@ and back into json_stringify$.
d4$ = "{" + trig$ + sq$ + "k" + one$ + one$ + "z" + sq$ + ":7}"
k4@ = json_keys@(json_parse@(d4$))
assert_eq(json_items$(k4@, 2), "k" + bytestr$(1) + bytestr$(1) + "z", "a single-quoted KEY is not silently renamed")
rem And the shape a deployment meets it in: an ordinary document with a file
rem name in it. Every byte of the text is printable ASCII; the answer must not
rem contain a NUL, which is the byte that truncates a path in every C API.
doc$ = "{" + qt$ + "note" + qt$ + ":" + qt$ + "caf" + bs$ + "u00e9" + qt$ + "," + sq$ + "name" + sq$ + ":" + sq$ + "report" + one$ + one$ + "txt" + sq$ + "}"
n$ = json_gets$(json_parse@(doc$), "name")
assert_eq(n$, "report" + bytestr$(1) + bytestr$(1) + "txt", "the name arrives as it was written")
assert_eq(instr(n$, bytestr$(0)), 0, "and carries no NUL that nobody wrote")

test_case("json/the four escape defects are fixed inside single quotes too")
rem The same hole was a COMPLETENESS gap in the other direction: a document
rem whose only u-escape sat inside a single-quoted literal engaged no rewrite
rem at all, so it kept every one of fpjson's four defects. One fix, both
rem halves, both pinned.
bs$ = chr$(92)
qt$ = chr$(34)
sq$ = chr$(39)
pre$ = "{" + sq$ + "k" + sq$ + ":" + sq$
post$ = sq$ + "}"
z$ = bs$ + "u0000"
e8$ = bs$ + "u0800"
u800$ = bytestr$(224) + bytestr$(160) + bytestr$(128)
ue9$ = bytestr$(195) + bytestr$(169)
assert_eq(json_gets$(json_parse@(pre$ + "a" + z$ + "b" + post$), "k"), "a" + bytestr$(0) + "b", "a NUL escape survives a single-quoted literal")
assert_eq(json_gets$(json_parse@(pre$ + e8$ + e8$ + post$), "k"), u800$ + u800$, "and two adjacent escapes are not truncated to four bytes")
assert_eq(json_gets$(json_parse@(pre$ + bs$ + "u00e9" + e8$ + post$), "k"), ue9$ + u800$, "and the answer does not depend on the host code page")
rem A literal is always RE-EMITTED with a double quote, so byte 22 has to become
rem an escape on the way out and byte 27 has to pass through raw. Both ways.
assert_eq(json_gets$(json_parse@(pre$ + "a" + qt$ + z$ + "b" + post$), "k"), "a" + qt$ + bytestr$(0) + "b", "a raw double quote inside single quotes")
dq$ = "{" + qt$ + "k" + qt$ + ":" + qt$
assert_eq(json_gets$(json_parse@(dq$ + "a" + sq$ + z$ + "b" + qt$ + "}"), "k"), "a" + sq$ + bytestr$(0) + "b", "and a raw single quote inside double quotes")

test_case("json/a rewrite is not allowed to move what the parser accepts")
rem Swept rather than chosen: every raw byte 0..31 inside a literal, in both
rem delimiters, with and without an unrelated u-escape elsewhere in the
rem document. fpjson refuses exactly ONE of them -- a raw NUL, "string exceeds
rem end of line" -- and takes the other thirty-one verbatim. Spelling the raw
rem NUL as a marker would have made such a document ACCEPTED when an escape
rem happened to stand elsewhere in it and refused when none did, so whether a
rem malformed document was accepted would have turned on something unrelated to
rem what is wrong with it. A raw NUL abandons the rewrite instead.
bs$ = chr$(92)
qt$ = chr$(34)
trig$ = qt$ + "t" + qt$ + ":" + qt$ + bs$ + "u0041" + qt$ + ","
rawnul = 0
on error goto rn1
rn@ = json_parse@("{" + trig$ + qt$ + "k" + qt$ + ":" + qt$ + "a" + bytestr$(0) + "b" + qt$ + "}")
goto rn2
rn1:
rawnul = 1
resume next
rn2:
on error goto 0
assert_eq(rawnul, 1, "a raw NUL in a literal is refused whether an escape stands beside it or not")
lost = 0
for b = 1 to 31
  d$ = "{" + trig$ + qt$ + "k" + qt$ + ":" + qt$ + "a" + bytestr$(b) + "z" + qt$ + "}"
  if json_gets$(json_parse@(d$), "k") <> "a" + bytestr$(b) + "z" then lost = lost + 1
next
assert_eq(lost, 0, "31 raw control bytes accepted and returned unchanged")

test_case("json/an error position counts the caller's characters, not the rewrite's")
rem fpjson reports "Pos n" against the text it was HANDED, and once a document
rem is re-spelled that is not the text the caller wrote: a u-escape is six
rem characters where the byte it denotes is one, so the drift GROWS with the
rem number of escapes standing before the fault. That is why this walks a BAND
rem -- 0 to 8 escapes, one case each -- instead of pinning one document. A
rem single pin is exactly how the first version shipped a wrong Pos with two
rem on-error cases passing: both were documents where the rewrite is ABANDONED,
rem which put both of them outside the band that was broken. Measured on the
rem pristine build, the same 35-character document reports Pos 34 and the
rem rewrite reported Pos 14.
rem
rem Unrolled rather than looped on purpose: `resume next` on the last statement
rem of a body ends that body (see 49_on_error.bas), so a handler shared by a
rem loop would run exactly once and the other eight cases would never be tried.
bs$ = chr$(92)
qt$ = chr$(34)
e$ = bs$ + "u0041"
posbad = 0
poscount = 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 0) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe0
p@ = json_parse@(d$)
goto pa0
pe0:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa0:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 1) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe1
p@ = json_parse@(d$)
goto pa1
pe1:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa1:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 2) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe2
p@ = json_parse@(d$)
goto pa2
pe2:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa2:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 3) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe3
p@ = json_parse@(d$)
goto pa3
pe3:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa3:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 4) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe4
p@ = json_parse@(d$)
goto pa4
pe4:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa4:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 5) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe5
p@ = json_parse@(d$)
goto pa5
pe5:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa5:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 6) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe6
p@ = json_parse@(d$)
goto pa6
pe6:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa6:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 7) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe7
p@ = json_parse@(d$)
goto pa7
pe7:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa7:
on error goto 0
d$ = "{" + qt$ + "k" + qt$ + ":" + qt$ + mulstring$(e$, 8) + qt$ + " zz}"
want$ = "Pos " + str$(len(d$) - 1) + ":"
on error goto pe8
p@ = json_parse@(d$)
goto pa8
pe8:
poscount = poscount + 1
if instr(errmsg$(), want$) = 0 then posbad = posbad + 1
resume next
pa8:
on error goto 0
assert_eq(poscount, 9, "all nine malformed documents were refused")
assert_eq(posbad, 0, "and every one names the position of the character the CALLER wrote")
