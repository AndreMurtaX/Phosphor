rem ---------------------------------------------------------------
rem File text I/O. Scratch files go under bin\ , which is ignored by
rem git, and are deleted at the end of the run.
rem ---------------------------------------------------------------

f$ = "bin/p9b_io_a.tmp"
g$ = "bin/p9b_io_b.tmp"

test_case("io/writealltext-roundtrip")
content$ = "hello world"
assert_eq(file_writealltext(f$, content$), 1, "write reports success")
assert_eq(file_readalltext$(f$), content$, "IOUtilsLib preserves the text exactly")

ok = 0
if file_exists(f$) <> 0 then ok = 1
assert_eq(ok, 1, "file exists after writing")

test_case("io/multiline")
multi$ = "line1\nline2"
file_writealltext(g$, multi$)
assert_eq(file_readalltext$(g$), multi$, "line breaks survive the round trip")

test_case("io/savetext-round-trip")
rem savetext$ and opentext$ used to pass through a TStringList, which is a
rem list of lines and not a string: eleven characters went in and thirteen
rem came out. They use TFile now, as file_writealltext always did.
src$ = "hello world"
savetext$(f$, "utf-8", src$)
back$ = opentext$(f$, "utf-8")
assert_eq(len(back$), 11, "nothing is added")
assert_eq(back$, src$, "what was written is what comes back")

rem The line endings inside the text survive as written, rather than being
rem normalised to the platform's.
lines$ = "one\ntwo"
savetext$(f$, "utf-8", lines$)
assert_eq(len(opentext$(f$, "utf-8")), 7, "a bare LF stays one character")
assert_eq(opentext$(f$, "utf-8"), lines$, "and the text is unchanged")

test_case("io/delete")
file_delete(f$)
file_delete(g$)
ok = 1
if file_exists(f$) <> 0 then ok = 0
assert_eq(ok, 1, "deleted file is gone")
ok = 1
if file_exists(g$) <> 0 then ok = 0
assert_eq(ok, 1, "second file is gone too")

test_case("io/path-helpers")
assert_eq(path_getfilename$("a/b/c.txt"), "c.txt")
assert_eq(path_getextension$("a/b/c.txt"), ".txt")
assert_eq(path_getfilenamenoext$("a/b/c.txt"), "c")
assert_eq(path_changeextension$("a/b/c.txt", ".bas"), "a/b/c.bas")
