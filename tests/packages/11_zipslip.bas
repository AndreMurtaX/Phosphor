rem ---------------------------------------------------------------
rem Zip slip, the half no suite could see: THE NAME AN ENTRY IS
rem EXTRACTED UNDER IS NOT THE NAME IT ADVERTISES.
rem
rem SafeEntryName was asked about Entries[i].ArchiveFileName, which
rem TUnZipper.Examine fills from the CENTRAL DIRECTORY. Extraction
rem re-reads the LOCAL FILE HEADER and overwrites both names, then
rem builds the output path from that one. So an archive can advertise
rem "harmless.txt" in its directory and carry "../../../x" in its
rem local header: every extractor answered 1 with zip_error() = 0 and
rem the byte landed outside the destination AND outside the sandbox
rem root. Reproduced with the shipped binary before the fix.
rem
rem A NAME IS NOT THE ONLY THING AN ENTRY CAN BE. The same escape has a
rem second spelling: an entry whose ATTRIBUTES mark it a UNIX symbolic
rem link is extracted as a link whose TARGET is the entry's content, and
rem a target is not a name, so no name check can reach it. That one lands
rem only on Linux, and it is asserted here as a refusal of the ARCHIVE so
rem the assertion means the same thing on both systems.
rem
rem Every zip test in this tree builds its archives with zip_create@,
rem which writes the same name into both headers -- which is exactly
rem why no suite could reach this. So the malicious archive here is
rem BUILT BY THIS FILE, byte by byte, the way an attacker builds one:
rem a STORED (method 0) entry, which paszlib reads without a CRC
rem check, so no checksum has to be computed in BASIC.
rem
rem THE ESCAPE IS AIMED INTO THIS TEST'S OWN DIRECTORY. The destination
rem is bin/p9b_zipslip/dest/a/b and the entry climbs three levels to
rem bin/p9b_zipslip -- outside the destination, which is the whole
rem property, and still inside the tree this test owns, so a failure
rem leaves a stray file next to the others rather than anywhere else.
rem Everything is under bin\, which git ignores.
rem ---------------------------------------------------------------

rem bytelen, never len: len counts CHARACTERS through the code page, and
rem a zip header counts BYTES. Sizing a header with len would write a
rem short length for any name or payload holding a byte >= 128.
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

rem One STORED entry, with the central-directory name and the local-header
rem name given SEPARATELY -- that separation is the whole defect, and no
rem zip writer in this tree can express it. Signatures: 67324752 =
rem 0x04034B50 (local file header), 33639248 = 0x02014B50 (central
rem directory), 101010256 = 0x06054B50 (end of central directory).
rem
rem madeby is the central directory's "version made by": its HIGH byte is the
rem OS that wrote the archive (3 = UNIX), and extattr is the external
rem attributes field, whose high 16 bits carry the UNIX mode when the OS is 3.
rem Those two together are the only way to say "this entry is a symbolic
rem link", and zip_create@ can say neither.
function storedattr$(cname$, lname$, data$, madeby, extattr) local lfh$, cd$, eocd$, n
  n = bytelen(data$)
  lfh$ = le32$(67324752) + le16$(20) + le16$(0) + le16$(0) + le16$(0) + le16$(0)
  lfh$ = lfh$ + le32$(0) + le32$(n) + le32$(n)
  lfh$ = lfh$ + le16$(bytelen(lname$)) + le16$(0) + lname$ + data$
  cd$ = le32$(33639248) + le16$(madeby) + le16$(20) + le16$(0) + le16$(0) + le16$(0) + le16$(0)
  cd$ = cd$ + le32$(0) + le32$(n) + le32$(n)
  cd$ = cd$ + le16$(bytelen(cname$)) + le16$(0) + le16$(0) + le16$(0) + le16$(0)
  cd$ = cd$ + le32$(extattr) + le32$(0) + cname$
  eocd$ = le32$(101010256) + le16$(0) + le16$(0) + le16$(1) + le16$(1)
  eocd$ = eocd$ + le32$(bytelen(cd$)) + le32$(bytelen(lfh$)) + le16$(0)
  return lfh$ + cd$ + eocd$
endfunction

rem The ordinary shape: made by an unremarkable OS, no attributes at all.
function storedzip$(cname$, lname$, data$)
  return storedattr$(cname$, lname$, data$, 20, 0)
endfunction

dir_create("bin/p9b_zipslip")
dir_create("bin/p9b_zipslip/dest")
dir_create("bin/p9b_zipslip/dest/a")
dir_create("bin/p9b_zipslip/dest/a/b")

dest$ = "bin/p9b_zipslip/dest/a/b"
esc$ = "bin/p9b_zipslip/escaped_here.txt"
mal$ = "bin/p9b_zipslip/mal.zip"

test_case("zip/the builder writes an archive paszlib reads as ordinary")
rem Asserted first, and on purpose: if this archive were malformed the
rem refusals below would happen for the wrong reason, and a test that
rem fails for the wrong reason is not a confirmation. paszlib must read
rem it, count it, and report the innocent name it ADVERTISES.
ok% = file_writealltext(mal$, storedzip$("harmless.txt", "../../../escaped_here.txt", "zip slip payload"))
assert_eq(ok%, 1, "the malicious archive is written")
assert_eq(unzip_count(mal$), 1, "paszlib reads it as a one-entry archive")
assert_eq(zip_error(), 0, "so it is not merely corrupt")
assert_eq(unzip_entry$(mal$, 1), "harmless.txt", "and the name it advertises is harmless")

test_case("zip/an entry that climbs out in its LOCAL header is refused")
rem CLEARED FIRST, every time. bin/p9b_zipslip outlives a single run, so an
rem absence asserted without clearing proves nothing about THIS run -- and it
rem proved nothing loudly: with the fix taken out to watch this file fail, the
rem escape landed and stayed, and the next run with the fix back in reported the
rem stale file as a fresh escape.
gone% = file_delete(esc$)
gone% = file_delete(dest$ + "/harmless.txt")
gone% = file_delete(dest$ + "/other.txt")
gone% = file_delete(dest$ + "/keep.txt")
assert_false(file_exists(esc$), "the escape target does not exist before the run")
assert_false(file_exists(dest$ + "/harmless.txt"), "and neither does the destination entry")
caught% = 0
on error goto slipped
n% = unzip_extract(mal$, dest$)
goto after_slipped
slipped:
caught% = 1
resume next
after_slipped:
on error goto 0
assert_eq(caught%, 1, "unzip_extract refuses the archive rather than extracting it")
assert_eq(zip_error(), 1, "and records the refusal")
assert_false(file_exists(esc$), "and NO byte landed outside the destination")
assert_false(file_exists(dest$ + "/harmless.txt"), "nor inside it under the advertised name")

test_case("zip/the two handle-based extractors are guarded the same way")
r@ = zip_open@(mal$)
assert_eq(zip_count(r@), 1, "the reader opens it")
caught% = 0
on error goto slipped2
n% = zip_extractall(r@, dest$)
goto after_slipped2
slipped2:
caught% = 1
resume next
after_slipped2:
on error goto 0
assert_eq(caught%, 1, "zip_extractall refuses it too")
assert_false(file_exists(esc$), "and still nothing landed outside the destination")

rem zip_extract picks the entry by its CENTRAL name and writes it under the
rem LOCAL one, so this call is exposed twice over: the string that selects the
rem entry and the string that decides the path are different strings.
caught% = 0
on error goto slipped3
n% = zip_extract(r@, "harmless.txt", dest$)
goto after_slipped3
slipped3:
caught% = 1
resume next
after_slipped3:
on error goto 0
assert_eq(caught%, 1, "zip_extract refuses it, asked for the advertised name")
assert_false(file_exists(esc$), "and nothing landed then either")
c% = zip_close(r@)

test_case("zip/two names that merely DISAGREE are refused, both being harmless")
rem Not redundant with the case above. An archive whose headers disagree is
rem lying about itself even when neither name escapes anything: every reader
rem here (unzip_entry$, zip_list$, zip_exists, zip_entrysize) answers from the
rem central directory while the extractor writes under the local one, so a
rem caller told "keep.txt" gets a file called something else and no channel
rem says so. The disagreement is refused in its own right.
lie$ = "bin/p9b_zipslip/lie.zip"
ok% = file_writealltext(lie$, storedzip$("keep.txt", "other.txt", "content"))
assert_eq(unzip_entry$(lie$, 1), "keep.txt", "the archive advertises keep.txt")
assert_false(file_exists(dest$ + "/other.txt"), "and the destination is clear before the run")
caught% = 0
on error goto lied
n% = unzip_extract(lie$, dest$)
goto after_lied
lied:
caught% = 1
resume next
after_lied:
on error goto 0
assert_eq(caught%, 1, "and is refused for saying one thing and doing another")
assert_eq(zip_error(), 1, "with the refusal recorded")
assert_false(file_exists(dest$ + "/other.txt"), "nothing was written under the name it carries")
assert_false(file_exists(dest$ + "/keep.txt"), "nor under the name it advertises")

test_case("zip/an entry that is a SYMBOLIC LINK is refused, on both operating systems")
rem A SECOND SPELLING OF THE SAME ESCAPE, and the one a Windows-only suite
rem cannot see. paszlib extracts an entry whose attributes say "link" by
rem calling fpSymlink with the entry's decompressed CONTENT as the target --
rem a string no name check ever looks at. An archive can therefore carry a
rem link `d` aimed at `../../../..` and then an entry `d/x`, both names
rem impeccable, and the second one's byte lands wherever the first pointed.
rem Reproduced on the Linux VM against the binary that already had the
rem local-header guard: unzip_extract answered 1, zip_error() was 0, and the
rem byte landed outside the sandbox root. Windows never reaches it -- paszlib
rem forces IsLink := False off UNIX -- so the refusal is asserted here as a
rem judgement about the ARCHIVE, which is the same on both systems.
rem
rem 788 = (3 << 8) | 20: made by OS 3, UNIX. 2717581312 = 0xA1FF0000: mode
rem 0120777 in the high 16 bits, and 0120000 is S_IFLNK.
rem
rem THE LINK TARGET HERE GOES NOWHERE ON PURPOSE. With the guard removed to
rem watch this case fail, the worst that can happen is a dangling link inside
rem this test's own directory; nothing this file writes can be aimed at
rem anything it does not own.
sym$ = "bin/p9b_zipslip/symlink.zip"
ok% = file_writealltext(sym$, storedattr$("link", "link", "no_such_target", 788, 2717581312))
assert_eq(ok%, 1, "the link-bearing archive is written")
assert_eq(unzip_count(sym$), 1, "paszlib reads it as an ordinary one-entry archive")
assert_eq(unzip_entry$(sym$, 1), "link", "advertising a name that escapes nothing")
gone% = file_delete(dest$ + "/link")
caught% = 0
on error goto linked
n% = unzip_extract(sym$, dest$)
goto after_linked
linked:
caught% = 1
resume next
after_linked:
on error goto 0
assert_eq(caught%, 1, "unzip_extract refuses it rather than creating the link")
assert_eq(zip_error(), 1, "and records the refusal")
assert_false(file_exists(dest$ + "/link"), "and nothing was created under its name")

test_case("zip/an archive that VANISHES is ANSWERED, not accused")
rem The guard re-opens the archive to read its local file headers, so an
rem archive deleted, renamed or locked between zip_open@ and the extraction
rem cannot be re-read. That is a FAILURE, not an accusation, and this unit
rem answers failures with 0 and zip_error() = 1 -- raising only when it
rem refuses an archive outright. A raise here would break that contract AND
rem misdiagnose it, telling a caller its archive escaped the destination when
rem the file merely went away. It raised for one round; this is the pin.
vz$ = "bin/p9b_zipslip/vanishing.zip"
ok% = file_writealltext(vz$, storedzip$("keep.txt", "keep.txt", "content"))
v@ = zip_open@(vz$)
assert_eq(zip_count(v@), 1, "the reader opens it")
gone% = file_delete(vz$)
assert_eq(gone%, 1, "and the archive is deleted underneath it")
rem A sentinel that is neither the answer nor the refusal: `resume next` skips
rem the assignment, so a raise would otherwise leave n% holding an older value.
n% = 7
caught% = 0
on error goto vanished
n% = zip_extractall(v@, dest$)
goto after_vanished
vanished:
caught% = 1
resume next
after_vanished:
on error goto 0
assert_eq(caught%, 0, "zip_extractall does not raise on an archive that is merely gone")
assert_eq(n%, 0, "it answers 0")
assert_eq(zip_error(), 1, "and records the failure where zip_error() can be read")
c% = zip_close(v@)

test_case("zip/an HONEST hand-built archive still extracts, byte for byte")
rem The same builder with the two names EQUAL. A guard that refused every
rem archive it did not itself write would pass the cases above and be
rem useless, so this proves the local header is READ correctly, on the
rem STORED path, through a nested directory, with a NUL and bytes >= 128
rem in the payload.
hb$ = "bin/p9b_zipslip/honest_hand.zip"
pay$ = "alpha" + bytestr$(0) + bytestr$(128) + bytestr$(255) + "omega"
ok% = file_writealltext(hb$, storedzip$("doc/deep/note.bin", "doc/deep/note.bin", pay$))
assert_eq(ok%, 1, "the honest hand-built archive is written")
rem Cleared for the same reason as the escape target above: a content assertion
rem that reads last run's file is not a test of this run's extraction.
gone% = file_delete("bin/p9b_zipslip/out1/doc/deep/note.bin")
assert_eq(unzip_extract(hb$, "bin/p9b_zipslip/out1"), 1, "and it extracts")
assert_eq(zip_error(), 0, "with nothing recorded against it")
assert_eq(file_readalltext$("bin/p9b_zipslip/out1/doc/deep/note.bin"), pay$, "byte for byte, NUL and >= 128 included")

test_case("zip/a name carrying a byte >= 128 is not mistaken for a lie")
rem The comparison is made over BYTES. Comparing the two names as STRINGS
rem would convert one of them through a code page whenever the archive sets
rem the EFS language-encoding flag, and an honest archive with an accented
rem name would be refused for a difference the conversion invented. Measured
rem against FPC 3.2.2 before this was written: ArchiveFileName holds the
rem filename field's bytes unchanged, EFS flag set or clear.
acc$ = "caf" + bytestr$(195) + bytestr$(169) + ".txt"
az$ = "bin/p9b_zipslip/accent.zip"
ok% = file_writealltext(az$, storedzip$(acc$, acc$, "accented"))
assert_eq(unzip_extract(az$, "bin/p9b_zipslip/out5"), 1, "an accented entry name extracts")
assert_eq(zip_error(), 0, "and records nothing")

test_case("zip/and every legitimate archive this library writes still works")
rem The over-refusal half, on the DEFLATE path this package actually produces:
rem nested directories, an empty file, and a payload with a NUL and a byte
rem >= 128 in it. All three extractors, plus the in-memory read, which the
rem guard must leave alone -- reading an entry into a string decides no path
rem on disk.
hz$ = "bin/p9b_zipslip/honest.zip"
blob$ = "hi" + bytestr$(200) + bytestr$(0) + "lo"
h@ = zip_create@(hz$)
assert_eq(zip_addstr(h@, "top", "top.txt"), 1, "a top-level entry")
assert_eq(zip_addstr(h@, "nested payload", "dir/sub/deep.txt"), 1, "a nested one")
assert_eq(zip_addstr(h@, "", "empty.txt"), 1, "an EMPTY file")
assert_eq(zip_addstr(h@, blob$, "raw/blob.dat"), 1, "and one with a NUL and a byte >= 128")
assert_eq(zip_close(h@), 1, "the archive closes")

gone% = file_delete("bin/p9b_zipslip/out2/top.txt")
gone% = file_delete("bin/p9b_zipslip/out2/dir/sub/deep.txt")
gone% = file_delete("bin/p9b_zipslip/out2/empty.txt")
gone% = file_delete("bin/p9b_zipslip/out2/raw/blob.dat")
gone% = file_delete("bin/p9b_zipslip/out3/raw/blob.dat")
gone% = file_delete("bin/p9b_zipslip/out4/dir/sub/deep.txt")
assert_eq(unzip_extract(hz$, "bin/p9b_zipslip/out2"), 1, "unzip_extract still extracts it")
assert_eq(zip_error(), 0, "with nothing recorded")
assert_eq(file_readalltext$("bin/p9b_zipslip/out2/top.txt"), "top", "the top-level entry arrives")
assert_eq(file_readalltext$("bin/p9b_zipslip/out2/dir/sub/deep.txt"), "nested payload", "the nested one lands under its directories")
assert_true(file_exists("bin/p9b_zipslip/out2/empty.txt"), "the empty file is created")
assert_eq(file_readalltext$("bin/p9b_zipslip/out2/empty.txt"), "", "and is empty")
assert_eq(file_readalltext$("bin/p9b_zipslip/out2/raw/blob.dat"), blob$, "and the binary payload is intact")

g@ = zip_open@(hz$)
assert_eq(zip_extractall(g@, "bin/p9b_zipslip/out3"), 1, "zip_extractall still extracts it")
assert_eq(file_readalltext$("bin/p9b_zipslip/out3/raw/blob.dat"), blob$, "with the same bytes")
assert_eq(zip_extract(g@, "dir/sub/deep.txt", "bin/p9b_zipslip/out4"), 1, "zip_extract still extracts one entry")
assert_eq(file_readalltext$("bin/p9b_zipslip/out4/dir/sub/deep.txt"), "nested payload", "where it was sent")
assert_eq(zip_read$(g@, "raw/blob.dat"), blob$, "and the in-memory read is untouched by the guard")
assert_eq(zip_error(), 0, "none of the legitimate work above recorded an error")
c% = zip_close(g@)
