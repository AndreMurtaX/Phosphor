rem ---------------------------------------------------------------
rem  TWO STRING-LIST WRITERS THAT DID NOT DO WHAT THE RTL DOES
rem  (adversarial round 9)
rem
rem  1. strings_values ON A SORTED LIST. A name the list did not hold
rem     was APPENDED: after "m=1" and "z=1", strings_values(l@, "a",
rem     "1") made m=1,z=1,a=1 -- a list still claiming to be sorted,
rem     whose strings_find (a binary search, correct only on a sorted
rem     list) then answered 0 for a line that was there. The rule the
rem     expectations below come from is FPC 3.2.2's: TStrings.SetValue
rem     calls Add when the name is absent (rtl/objpas/classes/
rem     stringl.inc), and TStringList.Add on a sorted list inserts at
rem     the place Find returns. On an UNSORTED list Add appends, so
rem     there nothing changes.
rem
rem  2. A QUOTE CHARACTER OF NUL. strings_delimitedtext$ wrote the NUL
rem     as an opening and a closing quote: "a,b" went out as five
rem     bytes, NUL a , b NUL. The RTL's writer quotes a field only
rem     "if DoQuote and (QuoteChar<>#0)" (GetDelimitedText, the same
rem     file), so with NUL it writes the field as it stands -- and its
rem     lone-empty-field rule (QuoteChar + QuoteChar) is guarded the
rem     same way. This unit's reader already read NUL as no quote.
rem ---------------------------------------------------------------

test_case("strings_values of a new name on a sorted list goes where it sorts")
l@ = strings@()
n = strings_sorted(l@, 1)
n = strings_add(l@, "m=1")
n = strings_add(l@, "z=1")
n = strings_values(l@, "a", "1")
assert_eq(strings_commatext$(l@), "a=1,m=1,z=1", "a=1 is inserted first, not appended")
assert_eq(strings_find(l@, "a=1"), 1, "the binary search finds it")
assert_eq(strings_indexof(l@, "a=1"), 1, "and the linear search agrees")
assert_eq(strings_sorted(l@), 1, "the list is still sorted, and now that is true")
n = strings_add(l@, "b=1")
assert_eq(strings_commatext$(l@), "a=1,b=1,m=1,z=1", "a later add still lands in order")
n = strings_values(l@, "m", "2")
assert_eq(strings_commatext$(l@), "a=1,b=1,m=2,z=1", "a name already there is rewritten where it stands")
assert_eq(strings_count(l@), 4, "and adds no line")

test_case("on an unsorted list strings_values still appends")
u@ = strings@()
n = strings_add(u@, "m=1")
n = strings_add(u@, "z=1")
n = strings_values(u@, "a", "1")
assert_eq(strings_commatext$(u@), "m=1,z=1,a=1", "Add on an unsorted list appends")

test_case("a NUL quote character quotes nothing")
q@ = strings@()
n = strings_quotechar(q@, bytestr$(0))
n = strings_add(q@, "a,b")
t$ = strings_delimitedtext$(q@)
assert_eq(bytelen(t$), 3, "a,b written as it stands: three bytes, no NUL around it")
assert_eq(t$, "a,b", "the field itself")
e@ = strings@()
n = strings_quotechar(e@, bytestr$(0))
n = strings_add(e@, "")
assert_eq(bytelen(strings_delimitedtext$(e@)), 0, "one empty field is no quotes either")
n = strings_add(e@, "x")
assert_eq(strings_delimitedtext$(e@), ",x", "an empty field then x: just the delimiter")

test_case("with an ordinary quote character the same field is quoted")
d@ = strings@()
n = strings_add(d@, "a,b")
assert_eq(strings_delimitedtext$(d@), chr$(34) + "a,b" + chr$(34), "the default quote, around a field holding the delimiter")
