rem ---------------------------------------------------------------
rem EVERY SANDBOX REFUSAL RECORDS ITSELF IN ioerror() (ledger n10, d62).
rem
rem A refused file_readalltext$ used to set ioerror() to 2, "file not
rem found" -- a refusal reported as a missing file (n10). Five more names
rem set 3, which iostrerror$() prints as "path not found". And the other
rem thirty-odd names that reach the sandbox set NOTHING, so ioerror() kept
rem the previous call's code and a script read it as this call's (d62).
rem Now each refusal records 5, "access denied" -- the code the attack
rem plan's decision 4 chose, already in the text table.
rem
rem This sweeps ALL the names that reach the gate in the three units that
rem own ioerror(), not a sample: the gate rule in check-sandbox.py keeps
rem them asking through one helper, and this proves what that helper
rem answers. Before each call ioerror() is brought back to 0 by a read
rem that succeeds, so a 5 left over from the previous name cannot pass
rem for this one's.
rem
rem The suite runs with the working directory as its sandbox root, so
rem "../" is outside it. Every refused path also does NOT EXIST: should
rem the gate ever stop refusing, the call has nothing to delete and
rem nowhere to write -- the non-destructive door CLAUDE.md asks a test of
rem a guard to go through.
rem ---------------------------------------------------------------

me$ = "tests/suite/76_ioerror_refused.bas"
o$ = "../p9b_zz_outside_76"
f$ = o$ + "/x.txt"
g$ = o$ + "/y.txt"
bytes@ = file_readallbytes@(me$)
l@ = strings@()

test_case("ioerror/the reset this file relies on")
gosub zero
assert_eq(ioerror(), 0, "a read that succeeds leaves ioerror() at 0")

test_case("ioerror/the codes that are not refusals keep their meaning")
z$ = file_readalltext$("bin/p9b_zz_missing_76.txt")
assert_eq(ioerror(), 2, "a missing file inside the root is still 2, nothing there to read")
gosub zero
z$ = file_readalltext$(f$)
assert_eq(ioerror(), 5, "a refused read is 5, not the 2 it used to be")
assert_eq(iostrerror$(), "access denied", "and says so")

test_case("ioerror/files: every name that reaches the gate")
gosub zero
x = file_writealltext(f$, "x")
assert_eq(ioerror(), 5, "file_writealltext")
gosub zero
x = file_appendalltext(f$, "x")
assert_eq(ioerror(), 5, "file_appendalltext")
gosub zero
x = file_createempty(f$)
assert_eq(ioerror(), 5, "file_createempty")
gosub zero
x = file_writeallbytes(f$, bytes@)
assert_eq(ioerror(), 5, "file_writeallbytes")
gosub zero
b@ = file_readallbytes@(f$)
assert_eq(ioerror(), 5, "file_readallbytes@")
gosub zero
x = file_exists(f$)
assert_eq(ioerror(), 5, "file_exists")
gosub zero
x = file_delete(f$)
assert_eq(ioerror(), 5, "file_delete")
gosub zero
x = file_getsize(f$)
assert_eq(ioerror(), 5, "file_getsize")
gosub zero
x = file_copy(f$, g$)
assert_eq(ioerror(), 5, "file_copy")
gosub zero
x = file_copy(f$, g$, 0)
assert_eq(ioerror(), 5, "file_copy without overwrite")
gosub zero
x = file_move(f$, g$)
assert_eq(ioerror(), 5, "file_move")
gosub zero
x = file_getcreationtime(f$)
assert_eq(ioerror(), 5, "file_getcreationtime")
gosub zero
x = file_getlastwritetime(f$)
assert_eq(ioerror(), 5, "file_getlastwritetime")
gosub zero
x = file_getlastaccesstime(f$)
assert_eq(ioerror(), 5, "file_getlastaccesstime")
gosub zero
x = file_setcreationtime(f$, 0)
assert_eq(ioerror(), 5, "file_setcreationtime")
gosub zero
x = file_setlastwritetime(f$, 0)
assert_eq(ioerror(), 5, "file_setlastwritetime")
gosub zero
x = file_setlastaccesstime(f$, 0)
assert_eq(ioerror(), 5, "file_setlastaccesstime")
gosub zero
z$ = savetext$(f$, "utf-8", "x")
assert_eq(ioerror(), 5, "savetext$, which used to report nothing at all")
gosub zero
z$ = opentext$(f$, "utf-8")
assert_eq(ioerror(), 5, "opentext$, which used to leave the slot untouched")

test_case("ioerror/directories: every name that reaches the gate")
gosub zero
x = dir_create(o$)
assert_eq(ioerror(), 5, "dir_create")
gosub zero
x = dir_delete(o$)
assert_eq(ioerror(), 5, "dir_delete")
gosub zero
x = dir_delete(o$, 1)
assert_eq(ioerror(), 5, "dir_delete, recursive")
gosub zero
x = dir_exists(o$)
assert_eq(ioerror(), 5, "dir_exists")
gosub zero
x = dir_isempty(o$)
assert_eq(ioerror(), 5, "dir_isempty")
gosub zero
z$ = dir_getfiles$(o$)
assert_eq(ioerror(), 5, "dir_getfiles$")
gosub zero
z$ = dir_getdirectories$(o$)
assert_eq(ioerror(), 5, "dir_getdirectories$")
gosub zero
z$ = dir_getentries$(o$)
assert_eq(ioerror(), 5, "dir_getentries$")
gosub zero
x = dir_copy(o$, o$ + "b")
assert_eq(ioerror(), 5, "dir_copy")
gosub zero
x = dir_move(o$, o$ + "b")
assert_eq(ioerror(), 5, "dir_move")
gosub zero
x = dir_setcurrent(o$)
assert_eq(ioerror(), 5, "dir_setcurrent")

test_case("ioerror/the classic names in PhosphorSysLib")
gosub zero
x = mkdir(o$)
assert_eq(ioerror(), 5, "mkdir")
gosub zero
x = rmdir(o$)
assert_eq(ioerror(), 5, "rmdir")
gosub zero
x = forcedirectories(o$)
assert_eq(ioerror(), 5, "forcedirectories")
gosub zero
x = chdir(o$)
assert_eq(ioerror(), 5, "chdir")
gosub zero
x = fileexists(f$, 0)
assert_eq(ioerror(), 5, "fileexists")
gosub zero
x = kill(f$)
assert_eq(ioerror(), 5, "kill")

test_case("ioerror/the string list's file doors")
gosub zero
x = strings_savetofile(l@, f$)
assert_eq(ioerror(), 5, "strings_savetofile")
gosub zero
x = strings_savetofile(l@, f$, "utf-8")
assert_eq(ioerror(), 5, "strings_savetofile with an encoding")
gosub zero
x = strings_save(l@, f$)
assert_eq(ioerror(), 5, "strings_save")
gosub zero
x = strings_loadfromfile(l@, f$)
assert_eq(ioerror(), 5, "strings_loadfromfile")
gosub zero
x = strings_loadfromfile(l@, f$, "utf-8")
assert_eq(ioerror(), 5, "strings_loadfromfile with an encoding")
gosub zero
x = strings_load(l@, f$)
assert_eq(ioerror(), 5, "strings_load")
end

zero:
z$ = file_readalltext$(me$)
return
