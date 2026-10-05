rem ---------------------------------------------------------------
rem strings_savetofile ANSWERS 0 WHEN NOTHING WAS WRITTEN.
rem
rem It returned the list's line count whatever happened to the write:
rem the Boolean the writer returned was discarded on the next line. So a
rem save the sandbox refused, or one into a directory that does not
rem exist, told the program every line had been written (ledger n7). A
rem missing directory is the refusal any host can produce, so it is the
rem one pinned here; the sandbox door shares the same writer and the
rem same discarded answer.
rem
rem Everything lives under bin/, which git ignores.
rem ---------------------------------------------------------------

root$ = "bin/p9b_strsave"
if dir_exists(root$) <> 0 then dir_delete(root$, 1)
ok% = dir_create(root$)

l@ = strings@()
ok% = strings_add(l@, "one")
ok% = strings_add(l@, "two")
ok% = strings_add(l@, "three")

test_case("strsave/a write that cannot happen answers 0")
nowhere$ = root$ + "/no_such_dir/out.txt"
assert_eq(strings_savetofile(l@, nowhere$), 0, "no lines were written, so the answer is 0")
assert_false(file_exists(nowhere$), "and indeed there is no file")

test_case("strsave/a write that happens answers the line count")
here$ = root$ + "/out.txt"
assert_eq(strings_savetofile(l@, here$), 3, "three lines rendered and written")
assert_true(file_exists(here$), "and the file is there")
back@ = strings@()
assert_eq(strings_loadfromfile(back@, here$), 3, "and reads back as three lines")

ok% = dir_delete(root$, 1)
