rem ---------------------------------------------------------------
rem ZIP INTEGRITY: what a STORED entry (method 0) could get away with.
rem
rem paszlib extracts a stored entry with one CopyFrom of the size its
rem LOCAL header gives, and does nothing else: no CRC check (zipper.pp
rem carries a "TODO: Implement CRC Check" on exactly that branch) and
rem no progress report, so the meter this package puts on the inflate
rem never saw a stored byte. Three things followed:
rem
rem  * A stored entry whose CRC-32 did not match its bytes was handed
rem    back as clean data, while the same corruption in a DEFLATED entry
rem    was refused. PKWARE APPNOTE 4.4.7 makes the CRC part of the
rem    entry; a reader that skips it returns bytes nobody vouched for.
rem
rem  * One stored entry at offset 0 and many central-directory records
rem    pointing at it, each declaring size 0, extracted the same bytes
rem    once per record: the up-front check summed the declared sizes
rem    (zero), and the copies were never charged. 300 records of 1 MiB
rem    copied 300 MiB under a budget that refuses string$(300000000).
rem
rem  * zip_read$ and zip_extract chose their entry through paszlib's
rem    name filter, a sorted TStringList -- which compares CASE-
rem    INSENSITIVELY. So zip_read$(r@, "a.txt") read "A.TXT" too (and
rem    kept the last one, leaking the first), and answered content for a
rem    name zip_exists says is not there.
rem
rem Every hostile archive here is BUILT BY THIS FILE, byte by byte,
rem because zip_create@ cannot write one. The CRC each honest entry
rem needs is NOT computed by the code under test: it is read out of
rem an archive zip_create@ writes for the same bytes (TZipper computes
rem it while compressing, a separate path through paszlib), and that
rem source is first pinned against the published CRC-32 check value,
rem 0xCBF43926 for the nine ASCII bytes "123456789" (the CRC-32/ISO-
rem HDLC catalogue entry that zip, gzip and PNG share).
rem
rem THE BUDGET CASE IS LAST, ON PURPOSE. Draining the run's budget to
rem a few kilobytes is the only way a .bas can make a small stored copy
rem cost more than what is left, and a spent budget refuses every
rem library call after it. Everything lives under bin/, which git
rem ignores.
rem ---------------------------------------------------------------

rem bytelen, never len: a header counts BYTES.
function le16$(v) local a, b
  a = v mod 256
  b = int(v / 256) mod 256
  return bytestr$(a) + bytestr$(b)
endfunction

function le32$(v) local a, b, c, d
  a = v mod 256
  b = int(v / 256) mod 256
  c = int(v / 65536) mod 256
  d = int(v / 16777216) mod 256
  return bytestr$(a) + bytestr$(b) + bytestr$(c) + bytestr$(d)
endfunction

rem The little-endian 32-bit number at 1-based byte i of s$.
function rd32(s$, i)
  return byteat(s$, i) + 256 * byteat(s$, i + 1) + 65536 * byteat(s$, i + 2) + 16777216 * byteat(s$, i + 3)
endfunction

rem The CRC-32 of s$, as the four bytes a header stores, taken from the
rem LOCAL header zip_create@ writes for it (offset 14, so bytes 15..18).
rem crctmp$ is a global: an undeclared name in a function is one.
function crc4$(s$) local h@, ok%, z$
  h@ = zip_create@(crctmp$)
  ok% = zip_addstr(h@, s$, "c")
  ok% = zip_close(h@)
  z$ = file_readalltext$(crctmp$)
  return bytemid$(z$, 15, 4)
endfunction

rem A STORED local file header plus its data. Signature 67324752 =
rem 0x04034B50. crc$ is four bytes; usize is the uncompressed size it
rem declares (the compressed size is always the data's real length).
function local$(name$, data$, crc$, usize)
  return le32$(67324752) + le16$(20) + le16$(0) + le16$(0) + le16$(0) + le16$(0) + crc$ + le32$(bytelen(data$)) + le32$(usize) + le16$(bytelen(name$)) + le16$(0) + name$ + data$
endfunction

rem One central-directory record (0x02014B50 = 33639248) for a stored
rem entry whose local header sits at 0-based byte `offset`.
function central$(name$, crc$, csize, usize, offset)
  return le32$(33639248) + le16$(20) + le16$(20) + le16$(0) + le16$(0) + le16$(0) + le16$(0) + crc$ + le32$(csize) + le32$(usize) + le16$(bytelen(name$)) + le16$(0) + le16$(0) + le16$(0) + le16$(0) + le32$(0) + le32$(offset) + name$
endfunction

rem End of central directory (0x06054B50 = 101010256), no comment.
function eocd$(n, cdsize, cdoff)
  return le32$(101010256) + le16$(0) + le16$(0) + le16$(n) + le16$(n) + le32$(cdsize) + le32$(cdoff) + le16$(0)
endfunction

rem Two honest stored entries, one after the other.
function two$(n1$, d1$, n2$, d2$) local c1$, c2$, l1$, l2$, cd$
  c1$ = crc4$(d1$)
  c2$ = crc4$(d2$)
  l1$ = local$(n1$, d1$, c1$, bytelen(d1$))
  l2$ = local$(n2$, d2$, c2$, bytelen(d2$))
  cd$ = central$(n1$, c1$, bytelen(d1$), bytelen(d1$), 0)
  cd$ = cd$ + central$(n2$, c2$, bytelen(d2$), bytelen(d2$), bytelen(l1$))
  return l1$ + l2$ + cd$ + eocd$(2, bytelen(cd$), bytelen(l1$) + bytelen(l2$))
endfunction

rem The overlap bomb: ONE stored entry at offset 0, and n central
rem records that all point at it under the same name, each declaring
rem an uncompressed size of 0.
function bomb$(data$, n) local c$, l$, cd$, i
  c$ = crc4$(data$)
  l$ = local$("bomb.txt", data$, c$, bytelen(data$))
  cd$ = ""
  for i = 1 to n
    cd$ = cd$ + central$("bomb.txt", c$, bytelen(data$), 0, 0)
  next
  return l$ + cd$ + eocd$(n, bytelen(cd$), bytelen(l$))
endfunction

dir_create("bin/p9b_zipint")
crctmp$ = "bin/p9b_zipint/crc.zip"
d$ = "bin/p9b_zipint/out"

test_case("zip-int/the CRC source agrees with the published check value")
rem If this failed, every "honest" archive below would be refused for
rem the wrong reason, and every refusal would prove nothing.
assert_eq(crc4$("123456789"), le32$(3421780262), "CRC-32 of 123456789 is 0xCBF43926")
assert_eq(crc4$(""), le32$(0), "and of no bytes at all, 0")

test_case("zip-int/an honest hand-built STORED archive still reads and extracts")
rem The over-refusal half: two stored entries, back to back with no gap
rem between them, one of them EMPTY (CRC 0), the other with a NUL and
rem bytes >= 128. Every door must take it.
pay$ = "alpha" + bytestr$(0) + bytestr$(128) + bytestr$(255) + "omega"
ok$ = "bin/p9b_zipint/honest.zip"
ok% = file_writealltext(ok$, two$("data.bin", pay$, "empty.txt", ""))
gone% = file_delete(d$ + "1/data.bin")
gone% = file_delete(d$ + "1/empty.txt")
gone% = file_delete(d$ + "2/data.bin")
gone% = file_delete(d$ + "3/data.bin")
assert_eq(unzip_extract(ok$, d$ + "1"), 1, "unzip_extract takes it")
assert_eq(zip_error(), 0, "with nothing recorded")
assert_eq(file_readalltext$(d$ + "1/data.bin"), pay$, "byte for byte")
assert_true(file_exists(d$ + "1/empty.txt"), "and the empty entry is created")
r@ = zip_open@(ok$)
assert_eq(zip_read$(r@, "data.bin"), pay$, "zip_read$ answers the stored bytes")
assert_eq(zip_error(), 0, "and records nothing")
assert_eq(zip_read$(r@, "empty.txt"), "", "an empty stored entry reads as empty")
assert_eq(zip_error(), 0, "which is not a failure")
assert_eq(zip_extractall(r@, d$ + "2"), 1, "zip_extractall takes it")
assert_eq(file_readalltext$(d$ + "2/data.bin"), pay$, "with the same bytes")
assert_eq(zip_extract(r@, "data.bin", d$ + "3"), 1, "zip_extract takes it")
assert_eq(file_readalltext$(d$ + "3/data.bin"), pay$, "with the same bytes")
c% = zip_close(r@)

test_case("zip-int/a STORED entry whose CRC-32 does not match is refused at every door")
rem The CRC of different bytes, so the header is well formed and only
rem the checksum is wrong. Answered like the deflated mismatch below:
rem 0 or "", zip_error() = 1, no raise -- and no file left behind
rem holding bytes that failed their check.
bad$ = "bin/p9b_zipint/badcrc.zip"
c1$ = crc4$("some other bytes")
l$ = local$("bad.txt", "stored payload", c1$, 14)
cd$ = central$("bad.txt", c1$, 14, 14, 0)
ok% = file_writealltext(bad$, l$ + cd$ + eocd$(1, bytelen(cd$), bytelen(l$)))
assert_eq(unzip_count(bad$), 1, "paszlib reads the directory as ordinary")
gone% = file_delete(d$ + "4/bad.txt")
gone% = file_delete(d$ + "5/bad.txt")
gone% = file_delete(d$ + "6/bad.txt")
caught% = 0
on error goto crc_raised
r@ = zip_open@(bad$)
s$ = "sentinel"
s$ = zip_read$(r@, "bad.txt")
e1 = zip_error()
n1% = unzip_extract(bad$, d$ + "4")
e2 = zip_error()
n2% = zip_extractall(r@, d$ + "5")
e3 = zip_error()
n3% = zip_extract(r@, "bad.txt", d$ + "6")
e4 = zip_error()
goto after_crc
crc_raised:
caught% = caught% + 1
resume next
after_crc:
on error goto 0
c% = zip_close(r@)
assert_eq(caught%, 0, "a checksum failure is answered, not raised")
assert_eq(s$, "", "zip_read$ answers nothing")
assert_eq(e1, 1, "and records the failure")
assert_eq(n1%, 0, "unzip_extract answers 0")
assert_eq(e2, 1, "and records it")
assert_false(file_exists(d$ + "4/bad.txt"), "and leaves no file holding the bad bytes")
assert_eq(n2%, 0, "zip_extractall answers 0")
assert_eq(e3, 1, "and records it")
assert_false(file_exists(d$ + "5/bad.txt"), "and leaves no file")
assert_eq(n3%, 0, "zip_extract answers 0")
assert_eq(e4, 1, "and records it")
assert_false(file_exists(d$ + "6/bad.txt"), "and leaves no file")

test_case("zip-int/a STORED entry with a data descriptor fails rather than reading empty")
rem General-purpose bit 3: the local header carries CRC and sizes of 0
rem and a descriptor after the data says the real ones (APPNOTE 4.3.9).
rem paszlib copies the LOCAL compressed size -- zero bytes -- so this
rem entry came back as "" with zip_error() 0: an answer, and a wrong one.
rem Now the zero bytes it copied are checked against the central CRC.
ddz$ = "bin/p9b_zipint/descriptor.zip"
dd$ = "described later"
cdd$ = crc4$(dd$)
l$ = le32$(67324752) + le16$(20) + le16$(8) + le16$(0) + le16$(0) + le16$(0) + le32$(0) + le32$(0) + le32$(0) + le16$(6) + le16$(0) + "dd.txt" + dd$
l$ = l$ + le32$(134695760) + cdd$ + le32$(bytelen(dd$)) + le32$(bytelen(dd$))
cd$ = le32$(33639248) + le16$(20) + le16$(20) + le16$(8) + le16$(0) + le16$(0) + le16$(0) + cdd$ + le32$(bytelen(dd$)) + le32$(bytelen(dd$)) + le16$(6) + le16$(0) + le16$(0) + le16$(0) + le16$(0) + le32$(0) + le32$(0) + "dd.txt"
ok% = file_writealltext(ddz$, l$ + cd$ + eocd$(1, bytelen(cd$), bytelen(l$)))
r@ = zip_open@(ddz$)
assert_eq(zip_entrysize(r@, "dd.txt"), bytelen(dd$), "the directory states the real size")
assert_eq(zip_read$(r@, "dd.txt"), "", "the read answers nothing")
assert_eq(zip_error(), 1, "and says it failed, instead of passing off empty as the content")
c% = zip_close(r@)

test_case("zip-int/the DEFLATED mismatch is answered the same way")
rem The reference behaviour the stored path is held to: a real archive
rem from zip_create@ with the CRC rewritten in BOTH headers. paszlib
rem raises SErrInvalidCRC after the inflate; the file it was writing
rem must not survive that either.
dz$ = "bin/p9b_zipint/deflated.zip"
h@ = zip_create@(dz$)
ok% = zip_addstr(h@, "deflate me, deflate me, deflate me, deflate me, deflate me", "def.txt")
ok% = zip_close(h@)
z$ = file_readalltext$(dz$)
assert_eq(byteat(z$, 9), 8, "the entry really is deflated (method 8)")
eo = bytelen(z$) - 21
assert_eq(rd32(z$, eo), 101010256, "and the end record is where it is looked for")
cdoff = rd32(z$, eo + 16)
assert_eq(rd32(z$, cdoff + 1), 33639248, "and so is the central record")
w$ = crc4$("not these bytes")
z$ = bytemid$(z$, 1, 14) + w$ + bytemid$(z$, 19, bytelen(z$))
z$ = bytemid$(z$, 1, cdoff + 16) + w$ + bytemid$(z$, cdoff + 21, bytelen(z$))
ok% = file_writealltext(dz$, z$)
gone% = file_delete(d$ + "7/def.txt")
caught% = 0
on error goto def_raised
r@ = zip_open@(dz$)
s$ = "sentinel"
s$ = zip_read$(r@, "def.txt")
e1 = zip_error()
n1% = unzip_extract(dz$, d$ + "7")
e2 = zip_error()
goto after_def
def_raised:
caught% = caught% + 1
resume next
after_def:
on error goto 0
c% = zip_close(r@)
assert_eq(caught%, 0, "answered, not raised")
assert_eq(s$, "", "zip_read$ answers nothing")
assert_eq(e1, 1, "and records it")
assert_eq(n1%, 0, "unzip_extract answers 0")
assert_eq(e2, 1, "and records it")
assert_false(file_exists(d$ + "7/def.txt"), "and leaves no file")

test_case("zip-int/the overlap bomb: records sharing one local header are refused")
rem First the premise, in this run: the budget refuses 300 MB up front.
caught% = 0
on error goto big_refused
s$ = string$(300000000, 65)
goto after_big
big_refused:
caught% = 1
resume next
after_big:
on error goto 0
assert_eq(caught%, 1, "the run's budget refuses string$(300000000)")
s$ = ""
rem Then 300 records x 1 MiB = 314572800 bytes, from a 1 MiB archive.
bz$ = "bin/p9b_zipint/bomb.zip"
ok% = file_writealltext(bz$, bomb$(string$(1048576, 66), 300))
assert_eq(unzip_count(bz$), 300, "paszlib reads 300 entries")
assert_eq(zip_error(), 0, "so the archive is not merely corrupt")
gone% = file_delete(d$ + "8/bomb.txt")
caught% = 0
m$ = ""
on error goto bomb_refused
n% = 7
n% = unzip_extract(bz$, d$ + "8")
goto after_bomb
bomb_refused:
caught% = 1
m$ = errmsg$()
resume next
after_bomb:
on error goto 0
assert_eq(caught%, 1, "unzip_extract refuses the archive outright")
assert_true(instr(m$, "the same local file header") > 0, "and says why: two records, one entry")
assert_eq(n%, 7, "it did not answer")
assert_false(file_exists(d$ + "8/bomb.txt"), "and wrote nothing")

test_case("zip-int/and every other door refuses the same shape")
rem Three records are enough for the shape; the doors are what is asked.
sz$ = "bin/p9b_zipint/bomb3.zip"
ok% = file_writealltext(sz$, bomb$("tiny", 3))
r@ = zip_open@(sz$)
assert_eq(zip_count(r@), 3, "the reader opens it")
caught% = 0
on error goto doors_refused
s$ = zip_read$(r@, "bomb.txt")
n% = zip_extractall(r@, d$ + "9")
n% = zip_extract(r@, "bomb.txt", d$ + "9")
goto after_doors
doors_refused:
caught% = caught% + 1
resume next
after_doors:
on error goto 0
c% = zip_close(r@)
assert_eq(caught%, 3, "zip_read$, zip_extractall and zip_extract each refuse it")

test_case("zip-int/an entry whose header lies INSIDE another entry's data is refused")
rem The other spelling of an overlap, with every offset distinct: the
rem outer entry's stored data IS a complete inner entry, and the
rem directory lists both. Each CRC is right; only the layout lies.
inner$ = local$("inner.txt", "inner bytes", crc4$("inner bytes"), 11)
co$ = crc4$(inner$)
outer$ = local$("outer.txt", inner$, co$, bytelen(inner$))
cd$ = central$("outer.txt", co$, bytelen(inner$), bytelen(inner$), 0)
cd$ = cd$ + central$("inner.txt", crc4$("inner bytes"), 11, 11, 30 + 9)
nz$ = "bin/p9b_zipint/nested.zip"
ok% = file_writealltext(nz$, outer$ + cd$ + eocd$(2, bytelen(cd$), bytelen(outer$)))
gone% = file_delete(d$ + "10/outer.txt")
gone% = file_delete(d$ + "10/inner.txt")
caught% = 0
m$ = ""
on error goto nest_refused
n% = unzip_extract(nz$, d$ + "10")
goto after_nest
nest_refused:
caught% = 1
m$ = errmsg$()
resume next
after_nest:
on error goto 0
assert_eq(caught%, 1, "the nested archive is refused")
assert_true(instr(m$, "overlaps") > 0, "for overlapping, and says so")
assert_false(file_exists(d$ + "10/outer.txt"), "and nothing was written")

test_case("zip-int/two entries with the SAME NAME are refused")
rem Distinct offsets, distinct contents, both CRCs right. Every reader
rem here answers a name from the central directory, so an archive that
rem holds two of one name cannot say which one a caller gets: zip_read$
rem took the first, zip_extractall left the second on disk.
dn$ = "bin/p9b_zipint/dup.zip"
ok% = file_writealltext(dn$, two$("dup.txt", "first", "dup.txt", "second"))
gone% = file_delete(d$ + "11/dup.txt")
caught% = 0
m$ = ""
on error goto dup_refused
n% = unzip_extract(dn$, d$ + "11")
goto after_dup
dup_refused:
caught% = 1
m$ = errmsg$()
resume next
after_dup:
on error goto 0
assert_eq(caught%, 1, "the archive is refused")
assert_true(instr(m$, "same name") > 0, "for carrying one name twice")
assert_false(file_exists(d$ + "11/dup.txt"), "and nothing was written")

test_case("zip-int/an entry is chosen by its exact bytes, not case-insensitively")
rem Distinct names that differ only in case: legal, and two files on
rem Linux. zip_exists already compared bytes; the read did not.
cz$ = "bin/p9b_zipint/case.zip"
ok% = file_writealltext(cz$, two$("a.txt", "lower", "A.TXT", "UPPER"))
r@ = zip_open@(cz$)
assert_eq(zip_read$(r@, "a.txt"), "lower", "a.txt reads as a.txt")
assert_eq(zip_read$(r@, "A.TXT"), "UPPER", "A.TXT reads as A.TXT")
assert_eq(zip_exists(r@, "A.txt"), 0, "A.txt is not in the archive")
assert_eq(zip_read$(r@, "A.txt"), "", "so it reads as nothing")
assert_eq(zip_error(), 1, "and that is recorded as a failure")
gone% = file_delete(d$ + "12/a.txt")
assert_eq(zip_extract(r@, "a.txt", d$ + "12"), 1, "zip_extract takes a.txt")
assert_eq(file_readalltext$(d$ + "12/a.txt"), "lower", "and writes a.txt, not A.TXT over it")
c% = zip_close(r@)

test_case("zip-int/the archive judged is the archive extracted")
rem Every extraction RE-READS the central directory (paszlib's
rem UnZipAllFiles), so an archive rewritten between zip_open@ and the
rem extraction was judged as it was and extracted as it is. Here the
rem rewrite keeps the old entry where it was -- so a check that reads the
rem OLD records against the NEW file still finds nothing wrong -- and adds
rem an entry whose name climbs out of the destination. The climb is aimed
rem at this file's own tree: bin/p9b_zipint/t/a -> bin/p9b_zipint/t.
tz$ = "bin/p9b_zipint/swap.zip"
esc$ = "bin/p9b_zipint/t/escaped.txt"
dir_create("bin/p9b_zipint/t")
dir_create("bin/p9b_zipint/t/a")
gone% = file_delete(esc$)
gone% = file_delete("bin/p9b_zipint/t/a/keep.txt")
ck$ = crc4$("kept")
l1$ = local$("keep.txt", "kept", ck$, 4)
cd$ = central$("keep.txt", ck$, 4, 4, 0)
ok% = file_writealltext(tz$, l1$ + cd$ + eocd$(1, bytelen(cd$), bytelen(l1$)))
r@ = zip_open@(tz$)
assert_eq(zip_count(r@), 1, "the reader opens the one-entry archive")
ce$ = crc4$("out")
l2$ = local$("../escaped.txt", "out", ce$, 3)
cd$ = central$("keep.txt", ck$, 4, 4, 0) + central$("../escaped.txt", ce$, 3, 3, bytelen(l1$))
ok% = file_writealltext(tz$, l1$ + l2$ + cd$ + eocd$(2, bytelen(cd$), bytelen(l1$) + bytelen(l2$)))
assert_false(file_exists(esc$), "the escape target does not exist before the run")
caught% = 0
on error goto swap_refused
n% = 7
n% = zip_extractall(r@, "bin/p9b_zipint/t/a")
goto after_swap
swap_refused:
caught% = 1
resume next
after_swap:
on error goto 0
c% = zip_close(r@)
assert_eq(caught%, 1, "the extraction refuses the archive it actually read")
assert_eq(n%, 7, "it did not answer")
assert_false(file_exists(esc$), "and nothing landed outside the destination")
assert_false(file_exists("bin/p9b_zipint/t/a/keep.txt"), "nor inside it: the judgement precedes every entry")

test_case("zip-int/a STORED copy is charged by the bytes it copies")
rem LAST: this spends the run's budget. A single, non-overlapping stored
rem entry whose central record declares size 0 and whose local header
rem carries 200000 bytes. Its CRC is right, so only the budget can
rem refuse it. The budget is drained in 64 KiB steps until string$
rem says no, which leaves less than one 128 KiB copy chunk.
mz$ = "bin/p9b_zipint/meter.zip"
big$ = string$(200000, 67)
cm$ = crc4$(big$)
l$ = local$("meter.txt", big$, cm$, 200000)
cd$ = central$("meter.txt", cm$, 200000, 0, 0)
ok% = file_writealltext(mz$, l$ + cd$ + eocd$(1, bytelen(cd$), bytelen(l$)))
big$ = ""
l$ = ""
gone% = file_delete(d$ + "13/meter.txt")
drained% = 0
on error goto drained_h
while drained% = 0
  s$ = string$(65536, 65)
wend
goto after_drain
drained_h:
drained% = 1
resume next
after_drain:
on error goto 0
s$ = ""
caught% = 0
m$ = ""
on error goto meter_refused
n% = 7
n% = unzip_extract(mz$, d$ + "13")
goto after_meter
meter_refused:
caught% = 1
m$ = errmsg$()
resume next
after_meter:
on error goto 0
assert_eq(caught%, 1, "the stored copy is refused by the budget")
rem Compared whole, not searched: instr is a library call and the budget
rem is spent now. The text is BudgetRefusal's (engine/PhosphorBudget.pas):
rem the door's name, then the step ceiling the package runner installs.
assert_eq(m$, "unzip_extract: the run has spent its step budget of 1000000 inside library calls", "by the meter, not by any other check")
assert_eq(n%, 7, "it did not answer")
assert_eq(zip_error(), 1, "the refusal is recorded")
assert_false(file_exists(d$ + "13/meter.txt"), "and the file it had begun is removed")
