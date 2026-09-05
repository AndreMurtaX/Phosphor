rem ---------------------------------------------------------------
rem The byte buffer: the founding brief's `buf@ = buffer_new(1024)`,
rem finally built -- as buffer_new@, because a built-in's return type
rem comes from the suffix on its OWN name (dim@, strings@, json_parse@).
rem
rem It is the mutable half of byte work. 06_strings reads bytes OUT of
rem a string with bytelen/byteat/bytemid$, which is enough to inspect
rem one. Writing is where a string fails: strings are immutable, so
rem changing one byte of an n-byte payload rebuilds all n and a loop
rem over it is quadratic -- the exact trap that cost hex_encode$ 37
rem seconds for 64 MB before it was made to index into a preallocated
rem result. A buffer is mutable in place, so the same loop is linear.
rem
rem It deliberately introduces NO new type: it operates on the same
rem TPhosphorBytes that file_readallbytes@ already hands out, which is
rem what makes the two compose without a conversion step.
rem
rem Every line below pins a documented behaviour. The error cases pin
rem the contract that matters most here: an out-of-range position,
rem count or value is a CATCHABLE ERROR, never a silent clamp and
rem never a crash -- reading past the end of a buffer is a bug in the
rem program, and quietly answering 0 would hide it.
rem ---------------------------------------------------------------

test_case("buffer/a new buffer is n zero bytes, not n bytes of garbage")
b@ = buffer_new@(4)
assert_eq(buffer_len(b@), 4, "the size it was asked for")
assert_eq(buffer_get(b@, 1), 0, "first byte zero")
assert_eq(buffer_get(b@, 4), 0, "last byte zero")
assert_eq(buffer_len(buffer_new@(0)), 0, "an empty buffer is legal")

test_case("buffer/a mutator returns information, not a success flag")
rem Failure is already a returned error, so 'did it work' would always say the
rem same thing. buffer_set gives back the byte written, as arr_set gives back
rem the value stored and strings_add gives back the index it took.
assert_eq(buffer_set(b@, 1, 65), 65, "the byte written")
assert_eq(buffer_set(b@, 4, 255), 255, "including one that fills the range")
x% = buffer_set(b@, 3, 128)
assert_eq(buffer_get(b@, 1), 65, "byte 1")
assert_eq(buffer_get(b@, 2), 0, "byte 2 untouched")
assert_eq(buffer_get(b@, 3), 128, "byte 3")
assert_eq(buffer_get(b@, 4), 255, "byte 4")

test_case("buffer/bytes >= 128 survive the trip out to a string and back")
rem The codepage class, in the one place it would do most damage: this unit is
rem compiled under {$codepage UTF8}, where building a string by concatenation
rem re-encodes any byte >= 128 into two. Every operation here goes through
rem SetLength, an indexed write, Copy or Move -- never a '+'.
s$ = buffer_tostr$(b@)
assert_eq(bytelen(s$), 4, "four bytes out, not six")
assert_eq(byteat(s$, 3), 128, "the high byte is itself")
assert_eq(byteat(s$, 4), 255, "and so is 255")
c@ = buffer_fromstr@(s$)
assert_eq(buffer_len(c@), 4, "and back in without growing")
assert_eq(buffer_equal(b@, c@), 1, "byte for byte")

test_case("buffer/a clone is independent, not another name for the same bytes")
d@ = buffer_clone@(b@)
assert_eq(buffer_equal(b@, d@), 1, "equal to start with")
x% = buffer_set(d@, 1, 66)
assert_eq(buffer_equal(b@, d@), 0, "and no longer equal after one is written")
assert_eq(buffer_get(b@, 1), 65, "the original is untouched")
assert_eq(buffer_get(d@, 1), 66, "the copy holds the change")

test_case("buffer/resize grows zero-filled and truncates, returning the new length")
assert_eq(buffer_resize(b@, 6), 6, "returns the new length")
assert_eq(buffer_get(b@, 4), 255, "what was there is kept")
assert_eq(buffer_get(b@, 5), 0, "growth is zero, not garbage")
assert_eq(buffer_get(b@, 6), 0, "all of it")
assert_eq(buffer_resize(b@, 4), 4, "shrinking truncates")
assert_eq(buffer_len(b@), 4, "to exactly the size asked for")

test_case("buffer/fill and fillrange report the byte count")
assert_eq(buffer_fill(b@, 7), 4, "bytes filled")
assert_eq(buffer_get(b@, 1), 7, "start")
assert_eq(buffer_get(b@, 4), 7, "end")
assert_eq(buffer_fillrange(b@, 2, 2, 9), 2, "bytes filled in the range")
assert_eq(buffer_get(b@, 1), 7, "before the range is untouched")
assert_eq(buffer_get(b@, 2), 9, "range start")
assert_eq(buffer_get(b@, 3), 9, "range end")
assert_eq(buffer_get(b@, 4), 7, "after the range is untouched")
assert_eq(buffer_fillrange(b@, 1, 0, 1), 0, "an empty range is a legal no-op")
assert_eq(buffer_get(b@, 1), 7, "and changes nothing")

test_case("buffer/slice and write cross to and from strings by bytes")
assert_eq(bytelen(buffer_slice$(b@, 2, 2)), 2, "two bytes out")
assert_eq(byteat(buffer_slice$(b@, 2, 2), 1), 9, "and they are the right two")
assert_eq(buffer_slice$(b@, 1, 0), "", "an empty slice is legal")
assert_eq(buffer_slice$(b@, 5, 0), "", "including one at Length+1")
assert_eq(buffer_write(b@, 1, "AB"), 2, "returns the byte count")
assert_eq(buffer_get(b@, 1), 65, "A")
assert_eq(buffer_get(b@, 2), 66, "B")
assert_eq(buffer_write(b@, 3, bytestr$(200)), 1, "a raw high byte goes in as one byte")
assert_eq(buffer_get(b@, 3), 200, "and comes back as itself")
assert_eq(buffer_write(b@, 1, ""), 0, "an empty write is a legal no-op")

test_case("buffer/copy is defined for overlapping regions")
rem It is a Move, not a hand-written loop, so a buffer can shift onto itself in
rem either direction without eating its own tail.
e@ = buffer_fromstr@("abcdef")
assert_eq(buffer_copy(e@, 1, e@, 3, 4), 4, "returns the byte count")
assert_eq(buffer_tostr$(e@), "cdefef", "shifted left over itself")
f2@ = buffer_fromstr@("abcdef")
x% = buffer_copy(f2@, 3, f2@, 1, 4)
assert_eq(buffer_tostr$(f2@), "ababcd", "and right over itself")
g@ = buffer_new@(3)
assert_eq(buffer_copy(g@, 1, e@, 1, 3), 3, "between two buffers")
assert_eq(buffer_tostr$(g@), "cde", "the bytes that were asked for")

test_case("buffer/indexof finds a byte pattern, from the start or from a position")
assert_eq(buffer_indexof(e@, "ef"), 3, "first match")
assert_eq(buffer_indexof(e@, "ef", 4), 5, "the second, searching from 4")
assert_eq(buffer_indexof(e@, "zz"), 0, "absent is 0")
assert_eq(buffer_indexof(e@, ""), 0, "an empty pattern matches nothing, not everything")
assert_eq(buffer_indexof(e@, "cdefef"), 1, "a pattern the whole length of the buffer")
assert_eq(buffer_indexof(e@, "cdefefx"), 0, "one byte longer cannot fit")

test_case("buffer/equal compares length and bytes, and an empty pair is equal")
assert_eq(buffer_equal(buffer_new@(0), buffer_new@(0)), 1, "two empties")
assert_eq(buffer_equal(buffer_new@(2), buffer_new@(3)), 0, "different lengths never match")
assert_eq(buffer_equal(buffer_fromstr@("cde"), buffer_fromstr@("cde")), 1, "same bytes match")

test_case("buffer/fixed-width integers, in the byte order the program states")
rem The assembly is arithmetic (shifts), never a Move of a machine word, so a
rem file written on one machine reads back identically on another whatever the
rem CPU's own endianness.
n@ = buffer_new@(8)
assert_eq(buffer_setint(n@, 1, 4, 305419896), 305419896, "returns the value written")
assert_eq(buffer_get(n@, 1), 120, "little-endian: 0x78 first")
assert_eq(buffer_get(n@, 4), 18, "and 0x12 last")
assert_eq(buffer_getint(n@, 1, 4), 305419896, "reads back")
x% = buffer_setint(n@, 1, 4, 305419896, true)
assert_eq(buffer_get(n@, 1), 18, "big-endian: 0x12 first")
assert_eq(buffer_get(n@, 4), 120, "and 0x78 last")
assert_eq(buffer_getint(n@, 1, 4, true), 305419896, "reads back big-endian")
assert_eq(buffer_getint(n@, 1, 4), 2018915346, "and the same bytes read little-endian are a different number")

test_case("buffer/one byte read two ways: 200 unsigned is -56 signed")
x% = buffer_setint(n@, 1, 1, 200)
assert_eq(buffer_getint(n@, 1, 1), -56, "signed sees the sign bit")
assert_eq(buffer_getuint(n@, 1, 1), 200, "unsigned does not")
assert_eq(buffer_setint(n@, 1, 1, -56), -56, "both readings of the width are accepted")
assert_eq(buffer_get(n@, 1), 200, "and land on the same byte")
x% = buffer_setint(n@, 1, 2, -2, true)
assert_eq(buffer_getuint(n@, 1, 2, true), 65534, "two bytes unsigned, big-endian")
assert_eq(buffer_getint(n@, 1, 2, true), -2, "and signed")

test_case("buffer/eight bytes carry an integer a Double cannot hold")
rem 2^53+1 is exactly the first integer a Double loses. The buffer keeps it,
rem and assert_int compares int64s rather than converting both to Double.
x% = buffer_setint(n@, 1, 8, 9007199254740993)
assert_int(buffer_getint(n@, 1, 8), 9007199254740993)
x% = buffer_setint(n@, 1, 8, -9007199254740993)
assert_int(buffer_getint(n@, 1, 8), -9007199254740993)
rem the extremes of the width, both ends
x% = buffer_setint(n@, 1, 8, 9223372036854775807)
assert_int(buffer_getint(n@, 1, 8), 9223372036854775807)
assert_eq(buffer_get(n@, 8), 127, "the sign bit is clear in the last byte")
x% = buffer_setint(n@, 1, 8, -9223372036854775807 - 1)
assert_int(buffer_getint(n@, 1, 8), -9223372036854775807 - 1)
assert_eq(buffer_get(n@, 8), 128, "and set in the other")

test_case("buffer/IEEE-754 doubles and singles, little-endian on both platforms")
f@ = buffer_new@(12)
assert_eq(buffer_setdbl(f@, 1, 0.5), 0.5, "returns the value written")
assert_eq(buffer_getdbl(f@, 1), 0.5, "reads back exactly")
assert_eq(buffer_get(f@, 8), 63, "0x3F is the high byte of 0.5, and it is LAST")
assert_eq(buffer_get(f@, 1), 0, "the low byte is first")
assert_eq(buffer_setsng(f@, 9, 0.5), 0.5, "a single writes four bytes")
assert_eq(buffer_getsng(f@, 9), 0.5, "and reads back")
assert_eq(buffer_get(f@, 12), 63, "same 0x3F, four bytes along")
x = buffer_setdbl(f@, 1, -2.25)
assert_eq(buffer_getdbl(f@, 1), -2.25, "a negative round trips")
x = buffer_setsng(f@, 9, 0.1)
assert_near(buffer_getsng(f@, 9), 0.1, 0.0000001, "a single is 0.1 to single precision")

test_case("buffer/the buffer IS the handle the file functions already use")
rem No conversion step: file_readallbytes@ hands back the same TPhosphorBytes
rem this package operates on, which is the whole point of not adding a type.
p$ = path_combine$(temppath$(), "phosphor_buffer_test.bin")
w@ = buffer_new@(3)
x% = buffer_set(w@, 1, 0)
x% = buffer_set(w@, 2, 128)
x% = buffer_set(w@, 3, 255)
ok% = file_writeallbytes(p$, w@)
assert_eq(file_getsize(p$), 3, "three bytes on disk, NUL and high bytes included")
r@ = file_readallbytes@(p$)
assert_eq(buffer_len(r@), 3, "three bytes back")
assert_eq(buffer_equal(w@, r@), 1, "identical")
assert_eq(buffer_get(r@, 2), 128, "the high byte survived the file")
x% = buffer_set(r@, 2, 64)
assert_eq(buffer_get(r@, 2), 64, "and what came off disk is editable in place")
ok% = file_delete(p$)

test_case("buffer/a clone is a copy of the bytes, not a second name for them")
rem Pascal strings are reference-counted with copy-on-write, so `dst.Data :=
rem src.Data` shares until something writes. An INDEXED write uniques the string
rem for you; FillChar and Move take the ADDRESS of a byte, and whether that
rem uniques first is a property of the compiler, not an assumption to make. It
rem does -- and this is the check that says so: bypassing it (writing through
rem PAnsiChar(Pointer(Data))) turns these three red and leaves the rest green.
a1@ = buffer_fromstr@("abcdef")
k1@ = buffer_clone@(a1@)
x% = buffer_fill(k1@, 88)
assert_eq(buffer_tostr$(a1@), "abcdef", "filling a clone leaves the original alone")
assert_eq(buffer_tostr$(k1@), "XXXXXX", "and does fill the clone")

a2@ = buffer_fromstr@("abcdef")
k2@ = buffer_clone@(a2@)
x% = buffer_write(k2@, 1, "ZZ")
assert_eq(buffer_tostr$(a2@), "abcdef", "writing into a clone leaves the original alone")
a3@ = buffer_fromstr@("abcdef")
k3@ = buffer_clone@(a3@)
x% = buffer_fillrange(k3@, 1, 2, 88)
assert_eq(buffer_tostr$(a3@), "abcdef", "filling a range of a clone leaves the original alone")
a4@ = buffer_fromstr@("abcdef")
k4@ = buffer_clone@(a4@)
x% = buffer_copy(k4@, 1, buffer_fromstr@("XYZ"), 1, 3)
assert_eq(buffer_tostr$(a4@), "abcdef", "copying into a clone leaves the original alone")

rem the same in both directions across the string boundary
src$ = "abcdef"
h1@ = buffer_fromstr@(src$)
x% = buffer_fill(h1@, 88)
assert_eq(src$, "abcdef", "a buffer never writes back into the string it was built from")
h2@ = buffer_fromstr@("abcdef")
out$ = buffer_tostr$(h2@)
x% = buffer_fill(h2@, 88)
assert_eq(out$, "abcdef", "and a string taken out of one does not change when it does")

test_case("buffer/a position past the end is a catchable error, not a clamp")
caught% = 0
on error goto oob
z% = buffer_get(b@, 99)
goto after_oob
oob:
caught% = 1
resume next
after_oob:
on error goto 0
assert_eq(caught%, 1, "reading past the end stops the program, it does not answer 0")
assert_eq(buffer_get(b@, 4), 7, "and the buffer is unharmed")

caught% = 0
on error goto zerop
z% = buffer_get(b@, 0)
goto after_zerop
zerop:
caught% = 1
resume next
after_zerop:
on error goto 0
assert_eq(caught%, 1, "position 0 is outside base-1")

caught% = 0
on error goto runoff
z$ = buffer_slice$(b@, 3, 5)
goto after_runoff
runoff:
caught% = 1
resume next
after_runoff:
on error goto 0
assert_eq(caught%, 1, "a count that runs past the end is refused, not shortened")

test_case("buffer/a value outside 0..255 is refused")
caught% = 0
on error goto badbyte
z% = buffer_set(b@, 1, 256)
goto after_byte
badbyte:
caught% = 1
resume next
after_byte:
on error goto 0
assert_eq(caught%, 1, "256 is not a byte")
assert_eq(buffer_get(b@, 1), 65, "and nothing was written")

caught% = 0
on error goto negbyte
z% = buffer_set(b@, 1, -1)
goto after_neg
negbyte:
caught% = 1
resume next
after_neg:
on error goto 0
assert_eq(caught%, 1, "-1 is not a byte either")

test_case("buffer/an integer that does not fit its width is an error, not a truncation")
rem decisions.md: integer overflow is a catchable error, never a silent wrap.
caught% = 0
on error goto badfit
z% = buffer_setint(n@, 1, 1, 300)
goto after_fit
badfit:
caught% = 1
resume next
after_fit:
on error goto 0
assert_eq(caught%, 1, "300 does not fit one byte")

caught% = 0
on error goto badwidth
z% = buffer_setint(n@, 1, 3, 1)
goto after_width
badwidth:
caught% = 1
resume next
after_width:
on error goto 0
assert_eq(caught%, 1, "width 3 is not 1, 2, 4 or 8")

caught% = 0
on error goto nounsigned
z% = buffer_getuint(n@, 1, 8)
goto after_unsigned
nounsigned:
caught% = 1
resume next
after_unsigned:
on error goto 0
assert_eq(caught%, 1, "width 8 has no unsigned form -- it would not fit an integer")

test_case("buffer/a size that could not be allocated is refused before it is tried")
caught% = 0
on error goto huge
z@ = buffer_new@(1e12)
goto after_huge
huge:
caught% = 1
resume next
after_huge:
on error goto 0
assert_eq(caught%, 1, "a typo does not try to allocate a terabyte")

caught% = 0
on error goto negsize
z@ = buffer_new@(-1)
goto after_negsize
negsize:
caught% = 1
resume next
after_negsize:
on error goto 0
assert_eq(caught%, 1, "a negative size is refused")

test_case("buffer/a handle of the wrong kind is rejected, never dereferenced")
caught% = 0
on error goto badh
z% = buffer_len(dim@(2))
goto after_h
badh:
caught% = 1
resume next
after_h:
on error goto 0
assert_eq(caught%, 1, "an array handle is not a buffer")

test_case("buffer/free is lenient, because freeing is what a program does defensively")
rem The shape strings_free settled on: everything else in the package is strict,
rem because reading past the end is a bug worth stopping for. Freeing twice is not.
assert_eq(buffer_free(c@), 1, "it freed a buffer")
assert_eq(buffer_free(c@), 0, "and says so the second time rather than raising")
assert_eq(buffer_free(dim@(2)), 0, "a handle of the wrong kind is answered, not raised")
