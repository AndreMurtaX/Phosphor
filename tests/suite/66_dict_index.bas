rem ---------------------------------------------------------------
rem Dict: the lookup index, and the two things it can get wrong.
rem
rem TPhosphorDict.IndexOf used to be `for i := 0 to Count - 1 do if
rem Keys[i] = AKey then Exit(i)`. Ten registered functions go through it
rem and eight of them are READS, so a dictionary of n keys cost n^2/2
rem string comparisons to fill and another n^2/2 to walk. There is now a
rem hash table beside the two arrays.
rem
rem The arrays are still the truth and still the documented insertion
rem order. So the danger is no longer slowness, it is DISAGREEMENT: a
rem table that has drifted from the arrays does not fail, it answers --
rem with the wrong value, for a key that is really there. Everything
rem before the last case is about keeping them equal through every
rem mutation; the last case is the cost itself.
rem ---------------------------------------------------------------

rem Large enough that a remove shifts a great many entries and that the
rem table has had to grow several times on the way up (it starts at eight
rem slots and doubles whenever the entries would fill more than half).
N = 200

test_case("dict/index agrees with the arrays after inserts")
d@ = dict@()
for i = 1 to N
  dict_set@(d@, "k" + str$(i), i * 10)
next
assert_eq(dict_count(d@), N, "N distinct keys, N entries")

bad = 0
for i = 1 to N
  if dict_get(d@, "k" + str$(i)) <> i * 10 then bad = bad + 1
next
assert_eq(bad, 0, "every key reads back the value it was given")

bad = 0
for i = 1 to N
  if dict_key$(d@, i) <> "k" + str$(i) then bad = bad + 1
next
assert_eq(bad, 0, "and insertion order is exactly what it was")

test_case("dict/remove renumbers every entry above it")

rem Removing the FIRST key shifts the other N-1 entries down one position
rem each. An index that deleted only the removed key's own slot would then
rem point one past the truth for all of them -- every surviving key would
rem hand back its NEIGHBOUR's value, and nothing would raise.
assert_eq(dict_remove(d@, "k1"), 1, "the key was there")
assert_eq(dict_count(d@), N - 1, "and exactly one entry went")

bad = 0
for i = 2 to N
  if dict_get(d@, "k" + str$(i)) <> i * 10 then bad = bad + 1
next
assert_eq(bad, 0, "every surviving key still reads its OWN value")

bad = 0
for i = 2 to N
  if dict_key$(d@, i - 1) <> "k" + str$(i) then bad = bad + 1
next
assert_eq(bad, 0, "and sits one place earlier in insertion order")

ok = 1
if dict_haskey(d@, "k1") <> 0 then ok = 0
assert_eq(ok, 1, "the removed key is gone from the index too, not just the arrays")

test_case("dict/remove from the middle and from the end")
assert_eq(dict_remove(d@, "k100"), 1, "a key in the middle")
assert_eq(dict_remove(d@, "k200"), 1, "and the last one")
assert_eq(dict_count(d@), N - 3, "three gone")

rem Read every remaining key by name, and read every position in order.
rem Positions 1..98 hold k2..k99; positions 99..197 hold k101..k199.
bad = 0
for i = 2 to N - 1
  if i <> 100 then
    if dict_get(d@, "k" + str$(i)) <> i * 10 then bad = bad + 1
  end if
next
assert_eq(bad, 0, "the survivors of three removals all read their own values")

bad = 0
for i = 2 to 99
  if dict_key$(d@, i - 1) <> "k" + str$(i) then bad = bad + 1
next
for i = 101 to N - 1
  if dict_key$(d@, i - 2) <> "k" + str$(i) then bad = bad + 1
next
assert_eq(bad, 0, "and the gap closed in insertion order, once per removal")

gone = 0
if dict_haskey(d@, "k100") <> 0 then gone = gone + 1
if dict_haskey(d@, "k200") <> 0 then gone = gone + 1
if dict_haskey(d@, "k1") <> 0 then gone = gone + 1
assert_eq(gone, 0, "and none of the three answers any more")

test_case("dict/a removed key comes back at the end")

rem A re-inserted key is a fresh entry at the end -- documented, and the
rem index must agree with that and not with where the key used to be.
dict_set@(d@, "k1", 999)
assert_eq(dict_count(d@), N - 2, "one more entry")
assert_eq(dict_key$(d@, N - 2), "k1", "appended, not restored to position 1")
assert_eq(dict_get(d@, "k1"), 999, "and reads its new value")
assert_eq(dict_get(d@, "k2"), 20, "while the key that took position 1 is untouched")

test_case("dict/overwrite keeps the position it already had")
dict_set@(d@, "k2", -1)
assert_eq(dict_count(d@), N - 2, "no new entry")
assert_eq(dict_get(d@, "k2"), -1, "the value replaced")
assert_eq(dict_key$(d@, 1), "k2", "in the place it already held")

test_case("dict/clear empties the index, not just the count")

rem Clear sets the count to zero and leaves the arrays' old contents lying
rem past it -- it always has, and that was invisible while the lookup was
rem bounded by the count. With a table beside the arrays it is not: the
rem stale slots still point at the stale strings. So the table is emptied
rem too, and IndexOf deliberately carries no "count is zero" shortcut that
rem would answer on the table's behalf -- which means the question can be
rem asked the instant the clear returns, and that is where a Clear that
rem shortened the count without emptying the table is caught.
dict_clear@(d@)
assert_eq(dict_count(d@), 0, "cleared")

hits = 0
for i = 1 to N
  if dict_haskey(d@, "k" + str$(i)) <> 0 then hits = hits + 1
next
assert_eq(hits, 0, "not one old key is found the instant the clear returns")

vals = 0
for i = 1 to N
  if dict_get(d@, "k" + str$(i)) <> 0 then vals = vals + 1
next
assert_eq(vals, 0, "and not one of them hands back its old value")

rem Then again with the count back over the stale slots, because a table
rem that survived the clear has a second chance to answer here.
dict_set@(d@, "novo", 7)
assert_eq(dict_count(d@), 1, "one key after the clear")
assert_eq(dict_get(d@, "novo"), 7, "and it reads")
assert_eq(dict_key$(d@, 1), "novo", "at position 1")

hits = 0
for i = 1 to N
  if dict_haskey(d@, "k" + str$(i)) <> 0 then hits = hits + 1
next
assert_eq(hits, 0, "no key from before the clear is found")

vals = 0
for i = 1 to N
  if dict_get(d@, "k" + str$(i)) <> 0 then vals = vals + 1
next
assert_eq(vals, 0, "and none of them hands back its old value")

test_case("dict/the index hashes the bytes that the comparison compares")

rem The library page promises keys are compared exactly, byte for byte:
rem case matters, whitespace matters, no Unicode normalization happens. A
rem hash that folded any of that would never OFFER the entry the
rem comparison would have accepted, and the miss would be silent.
b@ = dict@()
dict_set@(b@, "Name", 1)
dict_set@(b@, "name", 2)
dict_set@(b@, "name ", 3)
dict_set@(b@, " name", 4)
assert_eq(dict_count(b@), 4, "case and whitespace make four distinct keys")
assert_eq(dict_get(b@, "Name"), 1, "case matters")
assert_eq(dict_get(b@, "name"), 2, "both spellings keep their own value")
assert_eq(dict_get(b@, "name "), 3, "a trailing space matters")
assert_eq(dict_get(b@, " name"), 4, "a leading space matters")

rem A NUL in the middle of a key. A hash that walked the key as a C string
rem would stop at the NUL and hand these two the same hash -- which costs
rem only a probe, because the comparison still settles it. Pinned because
rem the failure of the OTHER kind, a comparison that stopped there, would
rem be one entry where there should be two.
z1$ = "a" + chr$(0) + "b"
z2$ = "a" + chr$(0) + "c"
dict_set@(b@, z1$, 11)
dict_set@(b@, z2$, 22)
assert_eq(dict_count(b@), 6, "two keys sharing a prefix and a NUL are two keys")
assert_eq(dict_get(b@, z1$), 11, "the first finds itself")
assert_eq(dict_get(b@, z2$), 22, "and so does the second")

rem Bytes above 127. The hash walks raw bytes and must not re-encode them.
u1$ = "ma" + chr$(231) + "a"
dict_set@(b@, u1$, 33)
assert_eq(dict_get(b@, u1$), 33, "a key carrying bytes above 127 finds itself")

test_case("dict/a lookup does not get slower as the dictionary grows")

rem THE DEFECT THIS FILE WAS WRITTEN FOR, and the shape of the pin
rem matters as much as the pin. What is timed is the SAME number of
rem lookups, of the SAME absent key, spelled by the SAME BASIC
rem statements, against a dictionary of one key and a dictionary of NB.
rem Everything except the size of the dictionary is held equal, so the
rem interpreter's own cost per iteration appears identically in both
rem measurements and cancels. That is what an earlier version of this
rem assertion got wrong: it timed dictionary work against a dict-free
rem control loop, and the test runner is about fifteen times slower than
rem bin/phosphor.exe at plain string work, so the control term drowned
rem the signal and the assertion passed with the fix removed.
rem
rem An ABSENT key is used deliberately. It is the one question whose cost
rem cannot depend on where a key happens to sit: a scan must compare
rem against every entry before it can answer no, an index answers from
rem one probe. So the expected ratio comes from the algorithm --
rem proportional to NB for a scan, flat for an index -- and not from a
rem run. Six calls to a line so that the per-iteration overhead of the
rem loop is shared out rather than dominating what is being compared.
rem
rem NB IS A POWER OF TWO ON PURPOSE, and it is the second thing this case
rem pins. The table doubles while the entries would fill more than HALF of
rem it; a table allowed to fill completely would be sized to a power of two
rem and hold exactly that many entries at a count of 8192, and an absent
rem key probing a table with no empty slot in it walks every slot and
rem compares every key -- the scan again, in full. A round 16000 sits at
rem 49% either way and cannot see the difference, which is how the
rem half-full rule survived an earlier version of this file untested.
NB = 8192
M  = 1000

one@ = dict@()
dict_set@(one@, "only", 1)

big@ = dict@()
for i = 1 to NB
  dict_set@(big@, "k" + str$(i), i)
next
assert_eq(dict_count(big@), NB, "the big dictionary really holds NB keys")
assert_eq(dict_get(big@, "k" + str$(NB)), NB, "including the last one, the scan's worst case")

t0 = now()
ha = 0
for i = 1 to M
  ha = ha + dict_haskey(one@, "zzzzzz") + dict_haskey(one@, "zzzzzz") + dict_haskey(one@, "zzzzzz") + dict_haskey(one@, "zzzzzz") + dict_haskey(one@, "zzzzzz") + dict_haskey(one@, "zzzzzz")
next
ams = millisecondsbetween(t0, now())

t0 = now()
hb = 0
for i = 1 to M
  hb = hb + dict_haskey(big@, "zzzzzz") + dict_haskey(big@, "zzzzzz") + dict_haskey(big@, "zzzzzz") + dict_haskey(big@, "zzzzzz") + dict_haskey(big@, "zzzzzz") + dict_haskey(big@, "zzzzzz")
next
bms = millisecondsbetween(t0, now())

rem Both loops really asked, and really got "no" every time: six calls,
rem M iterations, and dict_haskey answers 0 for a key that is not there.
assert_eq(ha, 0, "the key is absent from the one-key dictionary")
assert_eq(hb, 0, "and absent from the big one")

rem The multiplier does the judging; the additive term is only there so a
rem millisecond of timer granularity on a very fast machine cannot decide
rem it. Measured under this runner, same loops, three runs each: 1.03x to
rem 1.18x with the index, 5.0x with the lookup restored to a scan, and 5.9x
rem with the half-full rule dropped. 2.5 is the geometric middle of that
rem gap -- about 2.5x of headroom on the passing side and 1.7x of margin on
rem the failing one, which is the most balanced place to put it.
assert_true(bms < ams * 2.5 + 30, "asking a big dictionary costs what asking a small one costs")

test_case("dict/removal does not pay for the LENGTH of the keys")

rem THE PRICE THE INDEX NEARLY CHARGED. dict_remove was O(n) before this
rem change and still is -- it shifts the entries above the removed one down
rem to close the gap -- and it now rebuilds the table on top of that,
rem because every one of those entries just changed number. Rebuilding by
rem re-HASHING each surviving key would make the rebuild cost the
rem dictionary's total key BYTES rather than its entry count, which is a
rem different complexity class from the shift it rides on: measured at
rem 1000 removals from a 4000-entry dictionary, that was 63 ms -> 680 ms
rem for 202-byte keys, and it turned the whole change into a NET LOSS
rem against the linear scan for that shape. Each entry's hash is therefore
rem stored beside its key and travels with it, and the rebuild re-PLACES
rem entries without reading a key at all.
rem
rem So the thing to pin is that removal costs the same for long keys as for
rem short ones. Two dictionaries of the same COUNT whose keys differ only in
rem LENGTH, the same number of removals from the same end, spelled by the
rem same statements: everything except the key length cancels, and the
rem expected ratio comes from the algorithm -- proportional to key length
rem without the stored hashes, independent of it with them.
RN = 4000
RM = 1000

pad$ = ""
for i = 1 to 200
  pad$ = pad$ + "x"
next
assert_eq(len(pad$), 200, "the long keys really are a hundred times the short ones")

short@ = dict@()
for i = 1 to RN
  dict_set@(short@, "k" + str$(i), i)
next
long@ = dict@()
for i = 1 to RN
  dict_set@(long@, pad$ + "k" + str$(i), i)
next

rem Removing the FIRST key every time is the worst case for the shift and
rem for the rebuild alike, and it is the same worst case on both sides.
t0 = now()
gs = 0
for i = 1 to RM
  gs = gs + dict_remove(short@, "k" + str$(i))
next
sms = millisecondsbetween(t0, now())

t0 = now()
gl = 0
for i = 1 to RM
  gl = gl + dict_remove(long@, pad$ + "k" + str$(i))
next
lms = millisecondsbetween(t0, now())

assert_eq(gs, RM, "every short-key removal removed something")
assert_eq(gl, RM, "and so did every long-key one")

rem A timing claim over work that answered wrongly would be worth nothing,
rem so the survivors are read back by name on both sides. Key i holds i by
rem construction, for i from RM+1 to RN.
wrong = 0
for i = RM + 1 to RN
  if dict_get(short@, "k" + str$(i)) <> i then wrong = wrong + 1
next
for i = RM + 1 to RN
  if dict_get(long@, pad$ + "k" + str$(i)) <> i then wrong = wrong + 1
next
assert_eq(wrong, 0, "and all 6000 survivors still read their own values")

rem Measured under this runner, three runs each: 0.77x to 1.02x with the
rem stored hashes and 5.4x without them (708 ms against 130 ms). The bound
rem is the same 2.5 as the case above and for the same reason -- it is the
rem geometric middle of the gap it has to judge.
assert_true(lms < sms * 2.5 + 30, "removing a long key costs what removing a short one costs")
