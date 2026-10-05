rem ---------------------------------------------------------------
rem file_move AND dir_move REFUSE AN EXISTING TARGET, ON EVERY PLATFORM.
rem
rem docs/libraries/io.md promises 0 "when the target already exists".
rem Until 2026-10-05 that was true on Windows only, and by accident:
rem both bodies were one RenameFile, which FPC maps to MoveFileW with
rem no flags there (refuses an existing target) and to rename(2) on
rem Linux (REPLACES it). So on Linux file_move silently destroyed the
rem file at the target and answered 1, and dir_move replaced an empty
rem directory. This file passed on Windows before the repair and is
rem only able to fail on Linux -- see the playbook entry of that day.
rem
rem Every case asks for 0, the target untouched, and the source still
rem where it was. The last asks that a rename changing only the case of
rem a name still works: on a case-insensitive filesystem the "existing
rem target" IS the source, and refusing it would be a new defect.
rem Everything lives under bin/, which git ignores.
rem ---------------------------------------------------------------

root$ = "bin/p9b_mv"
if dir_exists(root$) <> 0 then dir_delete(root$, 1)
ok% = dir_create(root$)

test_case("move/file_move onto an existing file is refused")
src$ = root$ + "/src.txt"
dst$ = root$ + "/dst.txt"
ok% = file_writealltext(src$, "source")
ok% = file_writealltext(dst$, "keep me")
assert_eq(file_move(src$, dst$), 0, "file_move does not replace an existing file")
assert_eq(file_readalltext$(dst$), "keep me", "the target's content is untouched")
assert_true(file_exists(src$), "and the source is still there")

test_case("move/file_move onto an existing directory is refused")
d1$ = root$ + "/somedir"
ok% = dir_create(d1$)
assert_eq(file_move(src$, d1$), 0, "a file does not replace a directory")
assert_true(dir_exists(d1$), "the directory stands")
assert_true(file_exists(src$), "and the source is still there")

test_case("move/dir_move onto an existing empty directory is refused")
from$ = root$ + "/from"
into$ = root$ + "/into"
ok% = dir_create(from$)
ok% = file_writealltext(from$ + "/inside.txt", "x")
ok% = dir_create(into$)
assert_eq(dir_move(from$, into$), 0, "dir_move does not replace an empty directory")
assert_true(dir_isempty(into$), "the target directory is still the empty one")
assert_true(file_exists(from$ + "/inside.txt"), "and the source tree is untouched")

test_case("move/dir_move onto an existing file is refused")
assert_eq(dir_move(from$, dst$), 0, "a directory does not replace a file")
assert_eq(file_readalltext$(dst$), "keep me", "the file is untouched")
assert_true(dir_exists(from$), "and the source directory is still there")

test_case("move/a free target still moves")
fresh$ = root$ + "/fresh.txt"
assert_eq(file_move(src$, fresh$), 1, "file_move to a free name renames")
assert_true(file_exists(fresh$), "the target is there")
assert_false(file_exists(src$), "and the source is not")
moved$ = root$ + "/moved"
assert_eq(dir_move(from$, moved$), 1, "dir_move to a free name renames")
assert_true(file_exists(moved$ + "/inside.txt"), "with its files")

test_case("move/a rename that changes only the case still works")
rem On Windows and macOS the "target" names the source itself; on Linux it
rem is a different, free name. Both must answer 1.
lower$ = root$ + "/case.txt"
upper$ = root$ + "/CASE.txt"
ok% = file_writealltext(lower$, "c")
assert_eq(file_move(lower$, upper$), 1, "a case-only rename is a rename, not a collision")
assert_eq(file_readalltext$(upper$), "c", "and the content travels with it")

ok% = dir_delete(root$, 1)
