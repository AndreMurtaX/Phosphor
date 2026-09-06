rem ---------------------------------------------------------------
rem IOUtilsLib. check-coverage.py reported 10/52: the whole
rem directory, timestamp, byte and path half had never been run.
rem
rem Everything lives under bin\ , which git ignores, and the working
rem directory is put back before the file ends.
rem ---------------------------------------------------------------

root$ = "bin/p9b_io"
sub$ = "bin/p9b_io/inner"
a$ = "bin/p9b_io/a.txt"
b$ = "bin/p9b_io/b.log"

if dir_exists(root$) <> 0 then dir_delete(root$, 1)

test_case("io/directories")
assert_eq(dir_create(root$), 1, "dir_create makes one")
assert_true(dir_exists(root$), "and it is there")
assert_true(dir_isempty(root$), "a fresh directory is empty")

assert_eq(dir_create(sub$), 1, "and a nested one")
assert_false(dir_isempty(root$), "which stops the parent being empty")

test_case("io/listing")
file_writealltext(a$, "alpha")
file_writealltext(b$, "beta")

files$ = dir_getfiles$(root$)
assert_true(instr(files$, "a.txt"), "dir_getfiles$ names a file it holds")
assert_true(instr(files$, "b.log"), "and the other one")

only$ = dir_getfiles$(root$, "*.log")
assert_true(instr(only$, "b.log"), "the pattern form keeps the match")
assert_eq(instr(only$, "a.txt"), 0, "and drops what does not match")

deep$ = dir_getfiles$(root$, "*.txt", 1)
assert_true(instr(deep$, "a.txt"), "the recursive form still finds the top level")

dirs$ = dir_getdirectories$(root$)
assert_true(instr(dirs$, "inner"), "dir_getdirectories$ names a subdirectory")
assert_eq(instr(dirs$, "a.txt"), 0, "and no files")

pat$ = dir_getdirectories$(root$, "inn*")
assert_true(instr(pat$, "inner"), "its pattern form matches")
rec$ = dir_getdirectories$(root$, "*", 1)
assert_true(instr(rec$, "inner"), "and its recursive form")

all$ = dir_getentries$(root$)
assert_true(instr(all$, "a.txt"), "dir_getentries$ has the files")
assert_true(instr(all$, "inner"), "and the directories")
ent$ = dir_getentries$(root$, "*.txt")
assert_true(instr(ent$, "a.txt"), "its pattern form matches too")

test_case("io/directory-paths")
assert_true(len(dir_getparent$(sub$)), "dir_getparent$ answers something")
assert_true(dir_isrelativepath(root$), "a path without a root is relative")
assert_false(dir_isrelativepath("C:\\absolute"), "and one with a root is not")

was$ = dir_getcurrent$()
assert_true(len(was$), "dir_getcurrent$ answers the working directory")
assert_eq(dir_setcurrent(root$), 1, "dir_setcurrent moves there")
dir_setcurrent(was$)
assert_eq(dir_getcurrent$(), was$, "and moving back restores it")

test_case("io/file-copy-move")
c$ = "bin/p9b_io/copy.txt"
m$ = "bin/p9b_io/moved.txt"
assert_eq(file_copy(a$, c$), 1, "file_copy makes a copy")
assert_eq(file_readalltext$(c$), "alpha", "with the same content")

rem The three-argument form says whether an existing target may be
rem overwritten.
file_writealltext(c$, "changed")
assert_eq(file_copy(a$, c$, 1), 1, "the overwrite form replaces it")
assert_eq(file_readalltext$(c$), "alpha", "and the content is the source again")

assert_eq(file_move(c$, m$), 1, "file_move renames")
assert_true(file_exists(m$), "the target is there")
assert_false(file_exists(c$), "and the source is not")

test_case("io/file-content")
e$ = "bin/p9b_io/empty.txt"
assert_eq(file_createempty(e$), 1, "file_createempty makes one")
assert_true(file_exists(e$), "and it exists")
assert_eq(file_getsize(e$), 0, "with nothing in it")

file_writealltext(e$, "one")
file_appendalltext(e$, "two")
assert_eq(file_readalltext$(e$), "onetwo", "file_appendalltext adds to the end")

test_case("io/bytes")
rem file_readallbytes@ answers a stream and file_writeallbytes takes one
rem back. The pair is the only way to move a file that is not text.
buf@ = file_readallbytes@(a$)
assert_true(pnttonum(buf@), "file_readallbytes@ answers a handle")
bin$ = "bin/p9b_io/bytes.out"
assert_eq(file_writeallbytes(bin$, buf@), 1, "file_writeallbytes reports success")
assert_eq(file_readalltext$(bin$), "alpha", "and the bytes are the ones that were read")

rem A pointer that is not a stream answers zero rather than obeying.
rem What defends this is the try..except around the call, not a handle
rem check -- the stream is registered with the collector and not with
rem the handle registry, so there is nothing to check it against.
assert_eq(file_writeallbytes("bin/p9b_io/never.bin", pointer@(123456)), 0, "a bogus handle writes nothing")
assert_false(file_exists("bin/p9b_io/never.bin"), "and leaves no file behind")

test_case("io/timestamps")
rem The setters take a number and the getters answer one. Round-tripping
rem a fixed date proves both without asserting the clock.
when = strtodate("2020-06-15")
assert_eq(file_setcreationtime(a$, when), 1, "file_setcreationtime reports success")
assert_near(file_getcreationtime(a$), when, 0.01, "and the date reads back")

assert_eq(file_setlastwritetime(a$, when), 1, "file_setlastwritetime reports success")
assert_near(file_getlastwritetime(a$), when, 0.01, "and reads back")

assert_eq(file_setlastaccesstime(a$, when), 1, "file_setlastaccesstime reports success")
assert_near(file_getlastaccesstime(a$), when, 0.01, "and reads back")

assert_eq(dir_setcreationtime(sub$, when), 1, "dir_setcreationtime reports success")
assert_near(dir_getcreationtime(sub$), when, 0.01, "and reads back")
assert_eq(dir_setlastwritetime(sub$, when), 1, "dir_setlastwritetime reports success")
assert_near(dir_getlastwritetime(sub$), when, 0.01, "and reads back")
assert_eq(dir_setlastaccesstime(sub$, when), 1, "dir_setlastaccesstime reports success")
assert_near(dir_getlastaccesstime(sub$), when, 0.01, "and reads back")

test_case("io/paths")
rem Pure string work: no file has to exist for any of these.
assert_eq(path_combine$("one", "two.txt"), "one" + dirseparator$() + "two.txt", "path_combine$ joins with the platform separator")
assert_true(len(path_combine$("one", "two", "three.txt")), "and the three-part form answers")

p$ = "bin\\folder\\notes.txt"
assert_eq(path_getdirectoryname$(p$), "bin\\folder", "path_getdirectoryname$ drops the name")
assert_true(path_hasextension(p$), "path_hasextension sees one")
assert_false(path_hasextension("noext"), "and none where there is none")

assert_true(len(path_getfullpath$("bin")), "path_getfullpath$ answers an absolute path")
assert_false(path_ispathrooted("bin"), "a bare name is not rooted")
assert_true(path_isrelativepath("bin"), "which is the same thing said the other way")
assert_true(len(path_getpathroot$(path_getfullpath$("bin"))), "path_getpathroot$ answers a root")

assert_true(path_matchespattern("notes.txt", "*.txt"), "path_matchespattern matches")
assert_false(path_matchespattern("notes.log", "*.txt"), "and does not match what it should not")
rem The third argument is caseSENSitive, not case-insensitive: 1 makes the
rem comparison strict, and the two-argument form is the lenient one.
assert_false(path_matchespattern("NOTES.TXT", "*.txt", 1), "case-sensitive refuses a different case")
assert_true(path_matchespattern("NOTES.TXT", "*.txt", 0), "and case-insensitive accepts it")
assert_true(path_matchespattern("NOTES.TXT", "*.txt"), "which is what the two-argument form does")

assert_true(path_hasvalidpathchars("bin/folder"), "path_hasvalidpathchars accepts a sane path")
assert_true(path_hasvalidfilenamechars("notes.txt"), "path_hasvalidfilenamechars accepts a sane name")

test_case("io/errors")
rem ioerror answers a code and iostrerror$ the message for it. Reading a
rem file that is not there is the cheapest way to produce one.
file_readalltext$("bin/p9b_io/absent-on-purpose.txt")
assert_true(ioerror(), "a failed read leaves a code")
assert_true(len(iostrerror$()), "and a message to go with it")

file_readalltext$(a$)
assert_eq(ioerror(), 0, "and a good read clears it")
assert_eq(iostrerror$(), "No error", "message and all")

test_case("io/deletion")
assert_eq(dir_delete(sub$), 1, "dir_delete removes an empty directory")
assert_false(dir_exists(sub$), "and it is gone")

dir_create(sub$)
file_writealltext(sub$ + "/inside.txt", "x")
assert_eq(dir_delete(root$, 1), 1, "the recursive form removes a full tree")
assert_false(dir_exists(root$), "and the whole thing is gone")

test_case("io/dir-copy-move")
src$ = "bin/p9b_io_src"
cp$ = "bin/p9b_io_cp"
mv$ = "bin/p9b_io_mv"
if dir_exists(src$) <> 0 then dir_delete(src$, 1)
if dir_exists(cp$) <> 0 then dir_delete(cp$, 1)
if dir_exists(mv$) <> 0 then dir_delete(mv$, 1)

dir_create(src$)
file_writealltext(src$ + "/one.txt", "content")
assert_eq(dir_copy(src$, cp$), 1, "dir_copy copies the tree")
assert_true(file_exists(cp$ + "/one.txt"), "with the files in it")

assert_eq(dir_move(cp$, mv$), 1, "dir_move renames a tree")
assert_true(file_exists(mv$ + "/one.txt"), "the target has the files")
assert_false(dir_exists(cp$), "and the source is gone")

dir_delete(src$, 1)
dir_delete(mv$, 1)

test_case("io/dir_delete answers what happened, and says so when refused")
rem It used to DISCARD RemoveDir's answer and return 1 unconditionally: deleting a
rem directory that still held a file answered 1, left the directory standing, and
rem set no error -- a program had no way at all to learn it had failed. Its sibling
rem file_delete already answered Ord(DeleteFile); this was the outlier.
dd$ = path_combine$(temppath$(), "phosphor_dirdel")
ok% = dir_create(dd$)
ok% = file_writealltext(path_combine$(dd$, "inside.txt"), "x")
assert_eq(dir_delete(dd$), 0, "a non-empty directory is REFUSED, not reported as deleted")
assert_eq(dir_exists(dd$), 1, "and it is still there, which is what 0 means")
assert_true(ioerror(), "the refusal is recorded where a program looks for it")
ok% = file_delete(path_combine$(dd$, "inside.txt"))
assert_eq(dir_delete(dd$), 1, "emptied, it deletes")
assert_eq(dir_exists(dd$), 0, "and is gone")
assert_eq(ioerror(), 0, "with the error cleared")

rem the recursive form answers the same question the same way
dr$ = path_combine$(temppath$(), "phosphor_dirtree")
ok% = dir_create(dr$)
ok% = dir_create(path_combine$(dr$, "sub"))
ok% = file_writealltext(path_combine$(dr$, "sub/deep.txt"), "y")
assert_eq(dir_delete(dr$, 1), 1, "recursive delete of a populated tree succeeds")
assert_eq(dir_exists(dr$), 0, "and the tree is gone")

test_case("io/a destructive call refuses a path that names a whole filesystem")
rem THIS ONE COST A DISK. dir_delete("", 1) used to reach DeleteTree(""), and
rem IncludeTrailingPathDelimiter("") answers the path delimiter -- so the walk began
rem at the ROOT OF THE CURRENT DRIVE and deleted everything it could reach, then
rem answered 1, because DirectoryExists("") is False and the post-check read the
rem disaster as success. One line of BASIC.
rem
rem NO dir_delete OF A ROOT IS CALLED HERE, in any form. This block used to make
rem three non-recursive ones -- refused every time, on every version -- on the
rem reasoning that the guard fires before the recursive split so the harmless
rem spelling proves the dangerous one. That reasoning is sound and the file still
rem should not contain the call: a test that names a drive root and a delete in the
rem same line is one edit, or one regression in the guard, away from being the
rem disaster it exists to prevent. This project has already lost thirteen working
rem trees that way.
rem
rem The refusal itself is proven where it can be ASKED instead of attempted:
rem tests/probe_sandbox.lpr calls SandboxAllows -- the gate dir_delete consults --
rem on every spelling of a root, and IsPerilousPath directly. Both are pure
rem functions that answer True or False and touch nothing.
rem
rem dir_create stays: making a directory is not destructive, and it exercises the
rem same guard from the other side.
assert_eq(dir_create(""), 0, "an empty path is refused -- ForceDirectories('') answers True having made nothing")
assert_true(ioerror(), "and the refusal is recorded")

rem the legitimate path is untouched by the guard
gp$ = path_combine$(temppath$(), "phosphor_guard_ok")
assert_eq(dir_create(gp$), 1, "an ordinary directory is still created")
assert_eq(dir_exists(gp$), 1, "and really exists")
assert_eq(dir_delete(gp$), 1, "and is still deletable")
assert_eq(dir_exists(gp$), 0, "and really goes")
