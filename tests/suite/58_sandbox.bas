rem ---------------------------------------------------------------
rem The filesystem sandbox, from the side a SCRIPT can see.
rem
rem The root itself is host-facing -- a .bas file cannot set it, and
rem deliberately has no way to -- so the ceiling's real proof is
rem tests/probe_sandbox.lpr, which builds a victim tree outside the
rem root and asserts it is still standing afterwards. What is pinned
rem HERE is what a running program observes: that it can read the
rem cage it is in, that the platform's scratch places answer inside
rem it, and that a path leading out is refused rather than obeyed.
rem
rem The runner sets the root to its working directory, so this file
rem runs inside the checkout and "outside" means the parent of it.
rem
rem NOTHING BELOW ASKS FOR A DELETION OUTSIDE THE ROOT. A guard whose
rem job is to stop a deletion must not be tested by attempting one on
rem something that matters: if the guard regressed, the test would be
rem the disaster it tests for. The refusals asserted here are writes,
rem reads and listings, whose worst case if the guard failed is one
rem stray file. dir_delete outside the root is proven in the probe,
rem against a tree the probe itself created.
rem ---------------------------------------------------------------

test_case("sandbox/the root is visible")

root$ = sandboxroot$()
assert_true(len(root$), "sandboxroot$ answers the root the host set")
assert_false(dir_isrelativepath(root$), "and it is an absolute path")
assert_true(dir_exists(root$), "which exists")

test_case("sandbox/inside it, nothing changed")

inside$ = "bin/p9b_sandbox_inside.txt"
assert_eq(file_writealltext(inside$, "contained"), 1, "a write inside the root works")
assert_eq(file_readalltext$(inside$), "contained", "and reads back")
assert_eq(file_delete(inside$), 1, "and deletes")

d$ = "bin/p9b_sandbox_dir"
if dir_exists(d$) <> 0 then dir_delete(d$, 1)
assert_eq(dir_create(d$), 1, "a directory inside the root is made")
assert_eq(dir_delete(d$, 1), 1, "and removed again")

test_case("sandbox/the scratch places answer inside it")

rem With a root set, temppath$/homepath$/cfg_path$ point INSIDE it rather
rem than at the real user profile, so a program that keeps its working
rem files in the platform's temp directory runs unchanged and contained.
tp$ = temppath$()
assert_true(len(tp$), "temppath$ still answers something")
assert_eq(instr(tp$, root$), 1, "and it is inside the root")
assert_eq(instr(homepath$(), root$), 1, "homepath$ too")
assert_eq(instr(cfg_path$(), root$), 1, "and the config directory")

scratch$ = path_combine$(tp$, "p9b_sandbox_scratch.txt")
assert_eq(file_writealltext(scratch$, "ok"), 1, "and the scratch place is writable")
assert_eq(file_delete(scratch$), 1, "and tidies up")

test_case("sandbox/a path leading out is refused")

out$ = dir_getparent$(root$)
assert_true(len(out$), "the parent of the root is a real path")

stray$ = path_combine$(out$, "p9b_sandbox_escape.txt")
assert_eq(file_writealltext(stray$, "should never land"), 0, "a write outside answers 0")
assert_eq(file_exists(stray$), 0, "and the file is not there")

assert_eq(file_readalltext$(stray$), "", "a read outside answers empty")
assert_eq(dir_create(path_combine$(out$, "p9b_sandbox_made")), 0, "dir_create outside answers 0")
assert_eq(dir_getfiles$(out$), "", "a listing outside answers nothing")
assert_eq(dir_setcurrent(out$), 0, "and the working directory cannot move out")

rem A relative path is resolved before it is judged, so climbing out with
rem ".." is the same refusal as naming the parent outright.
assert_eq(file_writealltext("bin/../../p9b_sandbox_climb.txt", "x"), 0, "climbing out with .. answers 0")

test_case("sandbox/the perilous paths, which are refused with or without a root")

rem This holds even when no root is set: an empty path resolves to the root of
rem the current drive, which is never a directory a program meant.
rem
rem The two dir_delete calls that used to be here were removed on 2026-09-06.
rem They passed -- the gate refused them, as it always had -- but one of them was
rem spelled dir_delete("", 1), which is the RECURSIVE form and the exact call that
rem once walked the root of the current drive. A suite file should not contain it
rem at all. probe_sandbox now asks SandboxAllows the same question instead, which
rem answers True or False and cannot delete anything.
assert_eq(dir_create(""), 0, "an empty path is not a directory to create")
assert_eq(dir_create(" "), 0, "and neither is whitespace")

test_case("sandbox/a channel is bounded by the same root")

rem OPEN is the other way to the filesystem. It is refused out loud (a
rem catchable runtime error) rather than by answering a value, because
rem OPEN has no return value to answer with.
chan$ = path_combine$(out$, "p9b_sandbox_chan.txt")
caught = 0
on error goto h_chan
open chan$ for output as #1
assert_eq(caught, 1, "OPEN outside the root is refused, not obeyed")
assert_eq(file_exists(chan$), 0, "and no file was made outside")
on error goto 0
goto skip_chan
h_chan:
  caught = 1
  resume next
skip_chan:

test_case("sandbox/an .ini is a file too")

rem The config library opens a file by path like any other library, and for a
rem while it was the one that did not ask: with a root set, file_writealltext to
rem a path outside answered 0 while cfg_open@ + cfg_save wrote the file. Found by
rem reading the library to document it, not by a check -- scripts/check-sandbox.py
rem did not know TMemIniFile was a way to open a file.
rem
rem A refused config still OPENS: it works in memory and binds no file, so the
rem program gets an object it can use and a save that answers 0.
fora$ = path_combine$(dir_getparent$(root$), "p9b_sandbox_cfg.ini")
c@ = cfg_open@(fora$)
assert_eq(cfg_filename$(c@), "", "a config outside the root binds no file")
x@ = cfg_sets@(c@, "k", "v")
assert_eq(cfg_gets$(c@, "k", ""), "v", "and still works in memory")
assert_eq(cfg_save(c@), 0, "but saving it answers 0 -- no file was bound")
assert_eq(file_exists(fora$), 0, "and nothing was written outside the root")

rem Inside the root it behaves exactly as before.
dentro$ = "bin/p9b_sandbox_cfg.ini"
if file_exists(dentro$) <> 0 then file_delete(dentro$)
d@ = cfg_open@(dentro$)
y@ = cfg_sets@(d@, "k", "v")
assert_eq(cfg_save(d@), 1, "a config inside the root saves")
assert_eq(file_exists(dentro$), 1, "and the file is there")
assert_eq(file_delete(dentro$), 1, "tidied up")
