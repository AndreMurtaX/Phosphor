rem ---------------------------------------------------------------
rem TEXT FROM THE HOST IS THE ENGINE'S UTF-8 (2026-10-09, round 3 of the
rem adversarial loop).
rem
rem docs/libraries/sys.md: environ$ answers "the value of that environment
rem variable". On Windows it read the environment through the RTL's narrow
rem GetEnvironmentVariable, which takes GetEnvironmentStringsA -- the ANSI
rem code page, so a character outside it became "?" -- and tags the bytes
rem as the OEM code page: 'ação日本€' came back as 'aþÒo??Ç', and a name
rem holding a non-ASCII letter was never found. temppath$ and tempfilename$
rem read TEMP the same way, and homepath$, documentspath$ and cfg_path$
rem converted the wide folder path to the ANSI code page. Each now reads
rem the wide form and answers UTF-8.
rem
rem WHAT THIS FILE CANNOT DO, said where it would be looked for: a program
rem has no way to SET an environment variable, and the suite runners start
rem this one with the environment they were given, which holds no
rem non-ASCII value. The reproduction of the finding itself is therefore a
rem harness that sets one -- 'ação日本€' and a name 'PHX_ÇÃO' -- and compares
rem the bytes with Python's UTF-8; it is described in
rem docs/libraries/sys.md under environ$. (temppath$ cannot be checked
rem against TEMP here either: the runner sandboxes this program, and under
rem a sandbox temppath$ is the scratch directory inside the root.) What runs
rem here is what any environment can check: the rules about which names are
rem no variable.
rem ---------------------------------------------------------------

test_case("sys-r3/a name that is not UTF-8 is no variable")
rem bytestr$(200) is the single byte $C8: a UTF-8 lead byte with nothing
rem after it. No variable is named by it; on Windows the name used to be
rem converted through a code page into some other name.
assert_eq(environ$("PATH" + bytestr$(200)), "", "a truncated UTF-8 sequence")
assert_eq(environ$(bytestr$(255)), "", "a byte no UTF-8 holds")
assert_eq(environ$("PHX_R3_" + chr$(233) + "_NOT_SET"), "", "a well-formed non-ASCII name that is not set")
assert_true(len(environ$("PATH")) > 0, "and an ordinary name still reads")

