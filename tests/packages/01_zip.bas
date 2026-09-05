rem ---------------------------------------------------------------
rem zip archive (opt-in host package): create files, zip them, then
rem unzip to a new directory and check the content round-trips.
rem Everything lives under bin\ , which git ignores.
rem ---------------------------------------------------------------

root$ = "bin/p9b_zip"
src$ = "bin/p9b_zip/src"
out$ = "bin/p9b_zip/out"
zip$ = "bin/p9b_zip/a.zip"

if dir_exists(root$) <> 0 then dir_delete(root$, 1)
dir_create(root$)
dir_create(src$)
file_writealltext(src$ + "/one.txt", "first file")
file_writealltext(src$ + "/two.txt", "second file")

test_case("zip/compress and list")
assert_eq(zip_compress(zip$, src$), 1, "zip_compress reports success")
assert_true(file_exists(zip$), "the archive exists")
assert_eq(unzip_count(zip$), 2, "it holds two entries")
assert_true(len(unzip_entry$(zip$, 1)), "the first entry has a name")

test_case("zip/extract round trip")
dir_create(out$)
assert_eq(unzip_extract(zip$, out$), 1, "unzip_extract reports success")
assert_eq(file_readalltext$(out$ + "/one.txt"), "first file", "one.txt came back intact")
assert_eq(file_readalltext$(out$ + "/two.txt"), "second file", "two.txt came back intact")

rem clean up the whole tree
dir_delete(root$, 1)
assert_false(dir_exists(root$), "and the scratch tree is gone")

test_case("zip/a failure is RECORDED, not just answered")
rem The unit header promises failures reach zip_error(). unzip_count and
rem unzip_entry swallowed the exception and answered 0/"" with the slot untouched,
rem so a caller could not tell a corrupt archive from an empty one -- which is the
rem only question those two are ever asked.
bad$ = path_combine$(temppath$(), "phosphor_not_a_zip.zip")
ok% = file_writealltext(bad$, "this is definitely not a zip archive")
zc% = unzip_count(bad$)
assert_eq(zc%, 0, "a corrupt archive counts nothing")
assert_true(zip_error(), "and SAYS it failed, which is the difference from an empty one")
ze$ = unzip_entry$(bad$, 1)
assert_eq(ze$, "", "reading an entry from it answers nothing")
assert_true(zip_error(), "and records that too")
ok% = file_delete(bad$)
