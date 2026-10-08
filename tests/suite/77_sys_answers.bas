rem ---------------------------------------------------------------
rem mkdir, rmdir, chdir and kill ANSWER WHAT HAPPENED, and so do
rem file_delete and dir_setcurrent.
rem
rem The four classic names answered 1 whatever the filesystem said --
rem Plan9Basic's behaviour, kept "for the oracle" -- and set nothing in
rem ioerror(). dir_create and dir_delete had been fixed for exactly that;
rem these are the same operations under older names. file_delete and
rem dir_setcurrent already answered the truth but left ioerror() holding
rem whatever came before. Now 1 means the operation happened, 0 means it
rem did not, and ioerror() is 0 after a success and 3 after a failure
rem (5 is a refusal, which 76_ioerror_refused covers).
rem
rem Every expected answer comes from the operating system's own rule,
rem the same on POSIX and Win32, not from a run: creating a directory
rem that exists fails (EEXIST), and so does one whose parent is missing;
rem removing a directory that is not empty, or not there, fails; deleting
rem a directory as a file, or a file that is not there, fails; changing
rem to a directory that does not exist fails and moves nothing. "" is not
rem even tried: the sandbox gate refuses an empty path (ioerror() 5), so
rem chdir("") answers 0 for that reason, which is still nothing moved. Each failure is preceded by a success, so a 3 can only be
rem this call's, and each success by a failure, so its 0 is too.
rem
rem Everything lives under bin/ and is removed by the end; nothing here
rem deletes a path it did not create in this file.
rem ---------------------------------------------------------------

d$ = "bin/p9b_answers"
f$ = d$ + "/inside.txt"
g$ = "bin/p9b_answers_g.txt"
if fileexists(f$, 0) <> 0 then x = kill(f$)
if dir_exists(d$) <> 0 then x = rmdir(d$)
if fileexists(g$, 0) <> 0 then x = kill(g$)

test_case("answers/mkdir")
assert_eq(mkdir(d$), 1, "mkdir creates a directory that was not there")
assert_eq(ioerror(), 0, "and records no error")
assert_eq(mkdir(d$), 0, "mkdir answers 0 for a directory that already exists")
assert_eq(ioerror(), 3, "and records the failure")
assert_eq(mkdir("bin/p9b_answers_no_parent/child"), 0, "and 0 when the parent is missing")
assert_eq(dir_exists("bin/p9b_answers_no_parent/child"), 0, "having made nothing")

test_case("answers/rmdir and kill")
file_writealltext(f$, "x")
assert_eq(rmdir(d$), 0, "rmdir answers 0 for a directory that is not empty")
assert_eq(ioerror(), 3, "and records the failure")
assert_eq(dir_exists(d$), 1, "and the directory is still there")
assert_eq(kill(d$), 0, "kill answers 0 for a directory -- it deletes files only")
assert_eq(dir_exists(d$), 1, "and the directory is still there")
assert_eq(kill(f$), 1, "kill deletes the file")
assert_eq(ioerror(), 0, "and records no error")
assert_eq(kill(f$), 0, "kill answers 0 for a file that is not there")
assert_eq(ioerror(), 3, "and records the failure")
assert_eq(rmdir(d$), 1, "rmdir removes the now-empty directory")
assert_eq(ioerror(), 0, "and records no error")
assert_eq(rmdir(d$), 0, "rmdir answers 0 for a directory that is not there")
assert_eq(ioerror(), 3, "and records the failure")

test_case("answers/chdir")
here$ = dir_getcurrent$()
assert_eq(chdir("bin/p9b_answers_never_made"), 0, "chdir answers 0 for a directory that does not exist")
assert_eq(ioerror(), 3, "and records the failure")
assert_eq(dir_getcurrent$(), here$, "and the working directory has not moved")
assert_eq(chdir(""), 0, "an empty path is refused, not a directory to move to")
assert_eq(dir_getcurrent$(), here$, "and nothing moved")
assert_eq(chdir("bin"), 1, "chdir moves into a directory that exists")
assert_eq(ioerror(), 0, "and records no error")
x = chdir("..")
assert_eq(dir_getcurrent$(), here$, "and back")

test_case("answers/file_delete and dir_setcurrent")
assert_eq(file_delete(g$), 0, "file_delete answers 0 for a file that is not there")
assert_eq(ioerror(), 3, "and now records the failure too")
file_writealltext(g$, "x")
assert_eq(file_delete(g$), 1, "file_delete deletes the file")
assert_eq(ioerror(), 0, "and clears the error")
assert_eq(dir_setcurrent("bin/p9b_answers_never_made"), 0, "dir_setcurrent answers 0 for a directory that does not exist")
assert_eq(ioerror(), 3, "and now records the failure too")
assert_eq(dir_setcurrent("bin"), 1, "dir_setcurrent moves into one that exists")
assert_eq(ioerror(), 0, "and clears the error")
x = dir_setcurrent("..")
assert_eq(dir_getcurrent$(), here$, "and back")

test_case("answers/forcedirectories and fileexists write the slot too")
rem Each answer below follows a REFUSAL, which records 5, so a 5 still
rem standing after it is the defect an adversarial round found on
rem 2026-10-07: neither call wrote ioerror() when it answered. A failed
rem forcedirectories read as "refused", and a refused fileexists could not
rem be told from "not there". A "no" from fileexists is an answer, so its
rem slot is 0 either way; forcedirectories is a mutator, 0 or 3.
o$ = "../p9b_outside_never_made/x"
x = fileexists(o$, 0)
assert_eq(ioerror(), 5, "the control: a path outside the root records 5")
assert_eq(forcedirectories(d$ + "/a/b"), 1, "forcedirectories makes the chain")
assert_eq(ioerror(), 0, "and clears the refusal before it")
file_writealltext(g$, "x")
x = fileexists(o$, 0)
assert_eq(forcedirectories(g$ + "/sub"), 0, "a file in the way fails the chain")
assert_eq(ioerror(), 3, "and is recorded as a failure, not left reading as a refusal")
x = fileexists(o$, 0)
assert_eq(fileexists(g$, 0), 1, "fileexists answers for a file that is there")
assert_eq(ioerror(), 0, "and clears the slot")
x = fileexists(o$, 0)
assert_eq(fileexists(d$ + "/none.txt", 0), 0, "and for one that is not")
assert_eq(ioerror(), 0, "where no is an answer, not a failure")
x = kill(g$)
x = rmdir(d$ + "/a/b")
x = rmdir(d$ + "/a")
x = rmdir(d$)
assert_eq(dir_exists(d$), 0, "and everything it made is gone")
