rem ---------------------------------------------------------------
rem Package safety: an archive cannot write outside the destination,
rem and a package's free() cannot destroy something it does not own.
rem
rem Both were found by an adversarial hunt, both reproduced with the
rem shipped binary, and neither was visible to any suite -- the zip
rem tests all use archives this repo builds itself, which naturally
rem contain only well-behaved names.
rem
rem Everything here lives under bin\, which git ignores.
rem ---------------------------------------------------------------

dir_create("bin/p9b_safe")
dir_create("bin/p9b_safe/deep")
dir_create("bin/p9b_safe/deep/dest")

test_case("zip/a benign archive still extracts, '..' inside a NAME included")
good$ = "bin/p9b_safe/good.zip"
w@ = zip_create@(good$)
zip_addstr(w@, "fine", "doc/ok.txt")
zip_addstr(w@, "also fine", "my..notes.txt")
zip_close(w@)
assert_eq(unzip_extract(good$, "bin/p9b_safe/deep/dest"), 1, "an ordinary archive extracts")
assert_true(file_exists("bin/p9b_safe/deep/dest/doc/ok.txt"), "a nested entry lands where it should")
assert_true(file_exists("bin/p9b_safe/deep/dest/my..notes.txt"), "dots INSIDE a file name are not a path escape")
assert_eq(file_readalltext$("bin/p9b_safe/deep/dest/doc/ok.txt"), "fine", "and the content is intact")

test_case("zip/an entry that climbs out of the destination is refused")
rem zip_addstr writes the name it is given, so this archive is built exactly the way
rem an attacker would build one. The refusal is an ERROR, not a quiet 0: a caller
rem that ignores return values must not carry on believing it extracted a tree.
evil$ = "bin/p9b_safe/evil.zip"
e@ = zip_create@(evil$)
zip_addstr(e@, "escaped", "../../PWNED.txt")
zip_addstr(e@, "innocent", "ok.txt")
zip_close(e@)

caught% = 0
on error goto refused
n% = unzip_extract(evil$, "bin/p9b_safe/deep/dest")
goto after_refused
refused:
caught% = 1
resume next
after_refused:
on error goto 0
assert_eq(caught%, 1, "the extraction is refused rather than performed")
assert_eq(file_exists("bin/p9b_safe/PWNED.txt"), 0, "nothing was written outside the destination")
assert_eq(file_exists("bin/p9b_safe/deep/dest/ok.txt"), 0, "and the whole archive is refused, not half of it")

test_case("zip/the reader-based extractor is guarded too")
caught% = 0
on error goto refused2
r@ = zip_open@(evil$)
n% = zip_extractall(r@, "bin/p9b_safe/deep/dest")
goto after_refused2
refused2:
caught% = 1
resume next
after_refused2:
on error goto 0
assert_eq(caught%, 1, "zip_extractall refuses the same archive")

test_case("sqlite/close and finalize free only what they own")
rem sqlite_close used to free ANY handle and report success, so this destroyed the
rem JSON object and left every later read of o@ pointing at freed memory.
o@ = json_object@()
json_sets@(o@, "k", "v")
assert_eq(sqlite_close(o@), 0, "closing a JSON handle as a database does nothing")
assert_eq(json_count(o@), 1, "the object is still there")
assert_eq(json_gets$(o@, "k"), "v", "with its contents")
assert_eq(sqlite_finalize(o@), 0, "and finalize is just as unwilling")
assert_eq(json_gets$(o@, "k"), "v", "still there afterwards")

test_case("base64/a malformed payload is a value, not an exception")
rem base64_decode$("!!!!") let an EStreamError out of the RTL and ended the program,
rem against this unit's own documented contract of "returned, never raised".
assert_eq(base64_decode$("!!!!"), "", "garbage decodes to nothing")
assert_eq(base64_error(), 1, "and the failure is readable where the unit says it is")
assert_eq(base64_decode$(base64_encode$("ok")), "ok", "a real payload still round trips")
assert_eq(base64_error(), 0, "and clears the error")

test_case("zip/adding a file that is not there fails AT THE ADD")
rem AddFileEntry only records a name, so a missing file was reported as a successful
rem add and blew up later inside zip_close -- taking the whole archive with it and
rem leaking the writer handle, long after the caller had been told it worked.
z2$ = "bin/p9b_safe/late.zip"
w2@ = zip_create@(z2$)
zip_addstr(w2@, "good", "keep.txt")
assert_eq(zip_addfile(w2@, "bin/p9b_safe/definitely_not_here.bin", "b.bin"), 0, "the add reports failure")
assert_eq(zip_error(), 1, "and records it")
zip_close(w2@)
assert_true(file_exists(z2$), "the archive still closes")
r2@ = zip_open@(z2$)
assert_eq(zip_count(r2@), 1, "with the entry that was real")

test_case("zip/a call that did no work does not answer 1")
rem Three names answered 1 -- "I did it" -- for work they had not done, and the
rem harm is that a program ACTS on that: a backup reported as taken, a file
rem believed written. Nothing crashed and nothing was refused, which is why every
rem suite here stayed green through it.
rem
rem zip_compress: FindFirst on a directory that is not there simply matches
rem nothing, so the entry list came out empty and ZipAllFiles ran on it anyway.
rem Worse than an empty answer: TZipper.SaveToStream returns at `CheckEntries=0`
rem having written NOTHING, so the file left behind was 0 bytes -- which this
rem package's own reader calls corrupt. A caller who mistyped a directory name
rem was told the backup succeeded and handed an archive nothing can open.
rem Cleared first, so each assert_false below proves this CALL did not create the
rem file rather than that nothing ever had. bin/p9b_safe outlives a single run.
dir_create("bin/p9b_safe/hollow")
gone% = file_delete("bin/p9b_safe/ghost.zip")
gone% = file_delete("bin/p9b_safe/hollow.zip")
gone% = file_delete("bin/p9b_safe/nothing.zip")
assert_eq(zip_compress("bin/p9b_safe/ghost.zip", "bin/p9b_safe/no_such_dir"), 0, "compressing a directory that is not there FAILS")
assert_eq(zip_error(), 1, "and says so")
assert_false(file_exists("bin/p9b_safe/ghost.zip"), "leaving no file that only looks like an archive")
assert_eq(zip_compress("bin/p9b_safe/hollow.zip", "bin/p9b_safe/hollow"), 0, "and so does a directory with nothing in it")
assert_false(file_exists("bin/p9b_safe/hollow.zip"), "paszlib cannot write a readable empty archive, so none is claimed")

rem zip_close is where a writer's archive reaches disk, so it is where the caller
rem learns whether it did. A writer holding no entries answered 1 and left the
rem same 0-byte file.
e2@ = zip_create@("bin/p9b_safe/nothing.zip")
assert_eq(zip_close(e2@), 0, "closing a writer with nothing in it is not a success")
assert_eq(zip_error(), 1, "and records why")
assert_false(file_exists("bin/p9b_safe/nothing.zip"), "and writes no file at all")

rem zip_extract hands the name to TUnZipper.UnZipFiles, which treats a name list
rem as a FILTER -- and a filter matching nothing is not an error to it. So an
rem entry the archive does not hold answered 1 with zip_error() clear, and the
rem destination directory was not even created. The sibling zip_read$ gets the
rem same absent name right, so nothing in the answer told the program.
r3@ = zip_open@(z2$)
assert_eq(zip_extract(r3@, "not_in_here.txt", "bin/p9b_safe/deep/dest"), 0, "extracting an entry the archive does not hold FAILS")
assert_eq(zip_error(), 1, "and records it, exactly as zip_read$ already did")
assert_eq(zip_extract(r3@, "keep.txt", "bin/p9b_safe/deep/dest"), 1, "while the entry that IS there still extracts")
assert_true(file_exists("bin/p9b_safe/deep/dest/keep.txt"), "and lands where it was sent")
zip_close(r3@)

test_case("crt/crt_done answers the number its name and its reference promise")
rem It returned a string, so `x = crt_done()` died with 'cannot store string into
rem number variable' -- the documented shutdown call could not be captured.
x = crt_done()
assert_eq(x, 0, "captured like any other numeric call")
