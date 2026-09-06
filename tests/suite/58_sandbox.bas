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

rem These two hold even when no root is set: an empty path resolves to the
rem root of the current drive, which is never a directory a program meant.
assert_eq(dir_create(""), 0, "an empty path is not a directory to create")
assert_eq(dir_delete("", 1), 0, "nor one to delete")
assert_eq(dir_delete(" ", 1), 0, "and neither is whitespace")

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
