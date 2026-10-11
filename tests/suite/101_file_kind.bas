rem ---------------------------------------------------------------
rem  WHAT A PATH IS, ASKED OF THE OS (adversarial round 10)
rem
rem  file_kind$ and path_canonical$ exist because judging a file by its
rem  SPELLING failed six ways in one round: on Windows an 8.3 alias of
rem  a journal or of a link, an NTFS stream (x-journal:bk), the main
rem  stream spelled out (x-wal::$DATA), a device (CON); on Linux a
rem  FIFO. Each got past checks that read the name. These two answer
rem  what the name IS and what its one name is. The expectations come
rem  from the OS's own rules, written beside each assertion -- not
rem  from a run:
rem   - Win32 opens a name through GetFullPathNameW, which drops a
rem     trailing dot and maps a bare reserved name (NUL) to \\.\NUL;
rem     NTFS reads name:stream as a stream of name, and ignores case;
rem   - POSIX: '.' and '..' are entries of the folder, ':' and '*' are
rem     characters of a name, a name differing in case is another one;
rem   - a name not there yet is canonical as its folder's canonical
rem     name joined to the name, and a folder not there has none.
rem  Links, 8.3 aliases and FIFOs need the OS to make them, which a
rem  BASIC program cannot: block AI of scripts/test.ps1 and test.sh
rem  makes them and runs the contact manager's self-test over them.
rem  The suite's sandbox root is the working directory; everything
rem  here is under bin/, which git ignores.
rem ---------------------------------------------------------------

win? = os_name$() = "Windows"
if win? = true then sep$ = chr$(92) else sep$ = "/"
root$ = "bin/p9b_kind"
if dir_exists(root$) = 0 then dir_create(root$)
if dir_exists(root$ + "/sub") = 0 then dir_create(root$ + "/sub")
f$ = root$ + "/a.db"
file_writealltext(f$, "abc")

test_case("file_kind$/what is there")
assert_eq(file_kind$(f$), "file", "a file is a file")
assert_eq(ioerror(), 0, "and an answer leaves ioerror() at 0")
assert_eq(file_kind$(root$), "dir", "a folder is a dir")
assert_eq(file_kind$(root$ + "/missing.db"), "none", "nothing there is none")
assert_eq(file_kind$(root$ + "/nofolder/missing.db"), "none", "and so is a name in a folder that is not there")
assert_eq(file_kind$(""), "none", "the empty name names nothing")
assert_eq(file_kind$(root$ + "/sub/../a.db"), "file", "a path through .. reaches the file")

test_case("path_canonical$/one name for one file")
d$ = path_canonical$(root$)
c$ = path_canonical$(f$)
assert_true(path_ispathrooted(d$), "a canonical name is absolute")
assert_eq(c$, d$ + sep$ + "a.db", "a file's is its folder's and its own name")
assert_eq(path_canonical$(root$ + "/sub/../a.db"), c$, "a path through .. is the same file")
assert_eq(path_canonical$(root$ + "/./sub/.."), d$, "and . and .. leave no trace")
assert_eq(path_canonical$(root$ + "/missing.db"), d$ + sep$ + "missing.db", "a name not there yet is its folder's name joined to it")
assert_eq(path_canonical$(root$ + "/nofolder/missing.db"), "", "a name in a folder that is not there has none")
assert_eq(ioerror(), 3, "and says it could not answer")
assert_eq(path_canonical$(""), "", "nor has the empty name")

test_case("the names a system reads its own way")
rem Case: NTFS ignores it and the canonical name has the case the folder
rem holds; on Linux A.DB is another name, not there.
if win? = true then
  assert_eq(path_canonical$(root$ + "/A.DB"), c$, "Windows: another case is the same file, named as the folder holds it")
else
  assert_eq(path_canonical$(root$ + "/A.DB"), d$ + sep$ + "A.DB", "Linux: another case is another name")
end if
rem A trailing dot: Win32 drops it, POSIX keeps it.
if win? = true then
  assert_eq(path_canonical$(f$ + "."), c$, "Windows: a trailing dot is dropped, so it is the same file")
else
  assert_eq(path_canonical$(f$ + "."), c$ + ".", "Linux: a trailing dot is part of the name")
end if
rem A colon after the drive: a stream on Windows (none of a file's own
rem names), a character on Linux.
if win? = true then
  assert_eq(file_kind$(f$ + ":bk") + "|" + path_canonical$(f$ + ":bk"), "stream|", "Windows: name:stream is a stream, with no canonical name")
  assert_eq(file_kind$(f$ + "::$DATA") + "|" + path_canonical$(f$ + "::$DATA"), "stream|", "and so is name::$DATA, the file's own stream spelled out")
else
  assert_eq(file_kind$(f$ + ":bk") + "|" + path_canonical$(f$ + ":bk"), "none|" + c$ + ":bk", "Linux: a colon is a character of a name")
  assert_eq(file_kind$(f$ + "::$DATA") + "|" + path_canonical$(f$ + "::$DATA"), "none|" + c$ + "::$DATA", "and so are two")
end if
rem A device: NUL is one wherever Windows maps the bare name; on Linux
rem the devices live in /dev, outside this sandbox, so they are refused.
if win? = true then
  assert_eq(file_kind$("NUL") + "|" + path_canonical$("NUL"), "device|", "Windows: NUL is a device, with no canonical name")
else
  assert_eq(file_kind$("/dev/null") + "|" + path_canonical$("/dev/null"), "|", "Linux: /dev/null lies outside the sandbox and is not answered")
end if
rem A wildcard: no Windows name can hold one; a Linux name can.
if win? = true then
  assert_eq(file_kind$(root$ + "/a*b") + "|" + path_canonical$(root$ + "/a*b"), "none|", "Windows: a name with a * is no name, and nothing is there")
else
  assert_eq(file_kind$(root$ + "/a*b") + "|" + path_canonical$(root$ + "/a*b"), "none|" + d$ + "/a*b", "Linux: a * is a character, and the name is not there yet")
end if

test_case("outside the sandbox, nothing is said")
assert_eq(file_kind$("../p9b_zz_outside_101/x.db"), "", "file_kind$ is refused")
assert_eq(ioerror(), 5, "and says access denied")
assert_eq(path_canonical$("../p9b_zz_outside_101/x.db"), "", "path_canonical$ is refused")
assert_eq(ioerror(), 5, "and says so too")

file_delete(f$)
dir_delete(root$ + "/sub")
dir_delete(root$)
assert_eq(dir_exists(root$), 0, "and the scratch folder is gone")
