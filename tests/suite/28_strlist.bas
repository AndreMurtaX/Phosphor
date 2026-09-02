rem ---------------------------------------------------------------
rem StrListLib, the PROPERTY surface. 21_strlist covers the list
rem operations themselves; this covers everything that is a property
rem rather than a list operation -- the delimiters, the name/value
rem pairs, the encodings, the change-handler names, the batched
rem updates and the stream and file round trips.
rem
rem Adapted from the reference's 0-based TStringList to Phosphor's
rem base-1 world (decisions.md): every index below is 1-based, and
rem strings_find answers 0 (not -1) for an item that is absent, like
rem strings_indexof already does. instr is 1-based too, so a "does it
rem contain" reads as instr(...) with no +1 offset.
rem ---------------------------------------------------------------

test_case("strlist/text")
sl@ = strings@()
assert_true(pnttonum(sl@), "strings@ answers a handle")

strings_text(sl@, "one" + chr$(10) + "two")
assert_eq(strings_count(sl@), 2, "strings_text splits on the line break")
assert_eq(strings_strings$(sl@, 1), "one", "keeping the first line")
assert_true(len(strings_text$(sl@)), "and strings_text$ renders it back")

test_case("strlist/append")
strings_append(sl@, "three")
assert_eq(strings_count(sl@), 3, "strings_append adds a line")
assert_eq(strings_strings$(sl@, 3), "three", "at the end")

test_case("strlist/capacity")
rem Capacity is a hint about allocation, not a limit on the count, so
rem what is asserted is that it answers and that it holds what was set.
was = strings_capacity(sl@)
if was >= 0 then cap_ok = 1
assert_true(cap_ok, "strings_capacity answers a number")
strings_capacity(sl@, 64)
assert_eq(strings_capacity(sl@), 64, "and takes one")

test_case("strlist/delimiters")
rem The comma text and the delimited text are the same machinery with
rem a different separator, which is why setting the delimiter changes
rem what the second one produces and the first one never moves.
d@ = strings@()
strings_commatext(d@, "a,b,c")
assert_eq(strings_count(d@), 3, "strings_commatext splits on commas")
assert_true(len(strings_commatext$(d@)), "and renders back")

strings_delimiter(d@, ";")
assert_eq(strings_delimiter$(d@), ";", "strings_delimiter takes a character")
assert_true(instr(strings_delimitedtext$(d@), ";"), "which strings_delimitedtext$ then uses")

strings_delimitedtext(d@, "x;y")
assert_eq(strings_count(d@), 2, "and strings_delimitedtext reads it back")

strings_quotechar(d@, "'")
assert_eq(strings_quotechar$(d@), "'", "strings_quotechar takes one too")

strings_strictdelimiter(d@, 1)
assert_true(strings_strictdelimiter(d@), "strings_strictdelimiter holds a flag")
strings_strictdelimiter(d@, 0)
assert_false(strings_strictdelimiter(d@), "and clears it")

test_case("strlist/name-value")
nv@ = strings@()
strings_namevalueseparator(nv@, "=")
assert_eq(strings_namevalueseparator$(nv@), "=", "the separator is what was set")

strings_add(nv@, "colour=blue")
strings_add(nv@, "size=large")
assert_eq(strings_names$(nv@, 1), "colour", "strings_names$ reads the left half")
assert_eq(strings_values$(nv@, "colour"), "blue", "strings_values$ reads the right by name")
assert_eq(strings_valuefromindex$(nv@, 2), "large", "strings_valuefromindex$ reads it by position")

strings_values(nv@, "colour", "green")
assert_eq(strings_values$(nv@, "colour"), "green", "and writing by name changes it")
strings_valuefromindex(nv@, 2, "small")
assert_eq(strings_valuefromindex$(nv@, 2), "small", "as does writing by position")

assert_true(len(strings_keynames$(nv@, 1)), "strings_keynames$ answers a name")

test_case("strlist/strings-accessor")
rem strings_strings is get and set of one line, which is what the
rem indexer would be if this language had one.
assert_eq(strings_strings$(nv@, 1), "colour=green", "strings_strings$ reads a whole line")
strings_strings(nv@, 1, "colour=red")
assert_eq(strings_strings$(nv@, 1), "colour=red", "and strings_strings writes one")

test_case("strlist/case-and-duplicates")
c@ = strings@()
strings_casesensitive(c@, 1)
assert_true(strings_casesensitive(c@), "strings_casesensitive holds a flag")
strings_casesensitive(c@, 0)
assert_false(strings_casesensitive(c@), "and clears it")

rem Three modes, all named rather than numbered.
strings_duplicates(c@, "ignore")
assert_eq(strings_duplicates$(c@), "ignore", "duplicates: ignore")
strings_duplicates(c@, "accept")
assert_eq(strings_duplicates$(c@), "accept", "duplicates: accept")
strings_duplicates(c@, "error")
assert_eq(strings_duplicates$(c@), "error", "duplicates: error")

test_case("strlist/find-and-order")
f@ = strings@()
strings_add(f@, "banana")
strings_add(f@, "apple")
strings_add(f@, "cherry")

strings_exchange(f@, 1, 2)
assert_eq(strings_strings$(f@, 1), "apple", "strings_exchange swaps two lines")
assert_eq(strings_strings$(f@, 2), "banana", "both ways")

strings_move(f@, 3, 1)
assert_eq(strings_strings$(f@, 1), "cherry", "strings_move takes one to a new position")

rem strings_find is the sorted-list search, so the list has to be sorted
rem for its answer to mean anything.
strings_sort(f@)
assert_eq(strings_find(f@, "banana"), 2, "strings_find locates a line in a sorted list")
assert_eq(strings_find(f@, "durian"), 0, "and answers 0 for one that is absent")

test_case("strlist/equals")
e1@ = strings@()
e2@ = strings@()
strings_add(e1@, "same")
strings_add(e2@, "same")
assert_true(strings_equals(e1@, e2@), "two lists with the same lines are equal")
strings_add(e2@, "extra")
assert_false(strings_equals(e1@, e2@), "and stop being equal when one changes")

test_case("strlist/batched-updates")
rem beginupdate and endupdate bracket a run of changes so the change
rem event fires once rather than once per line. Nothing observable
rem changes for a list with no handler, which is what this asserts:
rem the pair is reachable and the list is intact afterwards.
u@ = strings@()
strings_beginupdate(u@)
strings_add(u@, "a")
strings_add(u@, "b")
strings_endupdate(u@)
assert_eq(strings_count(u@), 2, "the lines added inside the bracket are there")

test_case("strlist/change-handlers")
rem The handler is stored by name, and an empty name unwires it. The
rem firing itself belongs to a host with an engine, so what is pinned
rem here is that the name goes in and comes back.
h@ = strings@()
strings_onchange(h@, "on_list_changed")
assert_eq(strings_onchange$(h@), "on_list_changed", "strings_onchange stores a name")
strings_onchanging(h@, "on_list_changing")
assert_eq(strings_onchanging$(h@), "on_list_changing", "and so does strings_onchanging")

strings_onchange(h@, "")
assert_eq(strings_onchange$(h@), "", "an empty name unwires it")
strings_onchanging(h@, "")
assert_eq(strings_onchanging$(h@), "", "for both of them")

test_case("strlist/line-breaks-and-bom")
lb@ = strings@()
strings_add(lb@, "line")
strings_linebreak(lb@, chr$(10))
assert_eq(strings_linebreak$(lb@), chr$(10), "strings_linebreak takes a break sequence")

strings_trailinglinebreak(lb@, 0)
assert_false(strings_trailinglinebreak(lb@), "strings_trailinglinebreak clears")
assert_eq(strings_text$(lb@), "line", "and the rendered text has no trailing break")
strings_trailinglinebreak(lb@, 1)
assert_true(strings_trailinglinebreak(lb@), "and sets again")

strings_writebom(lb@, 1)
assert_true(strings_writebom(lb@), "strings_writebom holds a flag")
strings_writebom(lb@, 0)
assert_false(strings_writebom(lb@), "and clears it")

test_case("strlist/encodings")
rem A fresh list has no established encoding yet, but it still answers
rem the one a save would use -- reading a name off it must never be an
rem access violation, which is every list a program has just made.
en@ = strings@()
assert_true(len(strings_encoding$(en@)), "a fresh list still answers an encoding")
assert_eq(strings_encoding$(en@), strings_defaultencoding$(en@), "and what it answers is the one a save would use")

strings_defaultencoding(en@, "utf-8")
assert_eq(strings_defaultencoding$(en@), "utf-8", "strings_defaultencoding$ answers what was set")
assert_eq(strings_encoding$(en@), "utf-8", "which the current encoding follows while none is established")

test_case("strlist/files")
p$ = "bin/p9b_strlist.txt"
file_delete(p$)

w@ = strings@()
strings_add(w@, "first")
strings_add(w@, "second")
rem These forms answer the LINE COUNT, not a success flag -- the
rem reference pages say so in a column of their own. Reading a 2 as a
rem failure is the obvious mistake, and it is the one to avoid.
assert_eq(strings_savetofile(w@, p$, "utf-8"), 2, "strings_savetofile answers how many lines it wrote")
assert_true(file_exists(p$), "and the file is there")

r@ = strings@()
assert_eq(strings_loadfromfile(r@, p$, "utf-8"), 2, "strings_loadfromfile answers how many it read")
assert_eq(strings_count(r@), 2, "getting both lines back")
assert_eq(strings_strings$(r@, 1), "first", "in order")

rem The two-argument forms take the default encoding.
file_delete(p$)
assert_eq(strings_save(w@, p$), 2, "strings_save is the short form of the same thing")
r2@ = strings@()
assert_eq(strings_load(r2@, p$), 2, "and strings_load reads it")
assert_eq(strings_count(r2@), 2, "with both lines")

file_delete(p$)

test_case("strlist/streams")
rem The stream pair moves a list through the same byte-buffer handle
rem IoLib hands out for a file's bytes.
sp$ = "bin/p9b_strlist_stream.txt"
file_delete(sp$)
strings_savetofile(w@, sp$, "utf-8")

st@ = file_readallbytes@(sp$)
sr@ = strings@()
assert_eq(strings_loadfromstream(sr@, st@, "utf-8"), 2, "strings_loadfromstream reads a stream")
assert_eq(strings_count(sr@), 2, "getting the lines")

dst@ = file_readallbytes@(sp$)
assert_eq(strings_savetostream(w@, dst@, "utf-8"), 2, "strings_savetostream writes to one")

file_delete(sp$)
