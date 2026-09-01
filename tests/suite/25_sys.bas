rem ---------------------------------------------------------------
rem SysLib. check-coverage.py reported 1/43: paths, directories,
rem process arguments and colours had all never been run.
rem
rem Several of these answer differently per platform, and a few are
rem empty on desktop by design. Where a value cannot be asserted, what
rem is asserted is that the call returns rather than raising -- which
rem is not nothing: an unreachable function fails the file.
rem ---------------------------------------------------------------

test_case("sys/arguments")
if paramcount() >= 0 then pc_ok = 1
assert_true(pc_ok, "paramcount answers a count")
assert_true(len(paramstr$(0)), "paramstr$(0) is the program itself")

test_case("sys/separators")
assert_true(len(dirseparator$()), "dirseparator$ answers one")
assert_true(len(pathseparator$()), "pathseparator$ answers one")
reached = 0
alt$ = altseparator$()
reached = 1
assert_eq(reached, 1, "altseparator$ answers, empty or not")

test_case("sys/path-parts")
rem These are string surgery and do not touch the disk, so they can be
rem asserted exactly.
rem
rem The separators are doubled because this language escapes inside a
rem literal: "C:\folder\notes.txt" is C: form-feed older newline
rem otes.txt, not a path. Written once, a Windows path is quietly a
rem different string; written twice, it is the path.
p$ = "C:\\folder\\notes.txt"
assert_eq(extractfilename$(p$), "notes.txt", "extractfilename$ takes the last part")
assert_eq(extractfileext$(p$), ".txt", "extractfileext$ keeps the dot")
assert_eq(extractfilepath$(p$), "C:\\folder\\", "extractfilepath$ keeps the trailing separator")
assert_eq(changefileext$(p$, ".bak"), "C:\\folder\\notes.bak", "changefileext$ swaps the extension")
assert_eq(changefileext$("noext", ".txt"), "noext.txt", "and adds one where there was none")

test_case("sys/path-parts-take-either-separator")
rem The RTL splits on the platform separator only, so on Windows these
rem five saw a forward slash as an ordinary character: extractfilename$
rem answered the whole path back, and forcedirectories could not find a
rem parent to create. Every other file function in this engine takes
rem either, and now so do these.
fwd$ = "bin/folder/notes.txt"
assert_eq(extractfilename$(fwd$), "notes.txt", "extractfilename$ sees a forward slash")
assert_eq(extractfileext$(fwd$), ".txt", "so does extractfileext$")
assert_true(len(extractfilepath$(fwd$)), "and extractfilepath$ finds a directory")
assert_eq(extractfilename$(changefileext$(fwd$, ".bak")), "notes.bak", "and changefileext$ keeps the name intact")

test_case("sys/known-paths")
rem Present on every platform this engine builds for.
assert_true(len(temppath$()), "temppath$")
assert_true(len(homepath$()), "homepath$")
assert_true(len(documentspath$()), "documentspath$")

rem Answered but often empty on desktop: asserting a value here would
rem be asserting the machine, not the library.
reached = 0
x$ = shareddocumentspath$()
x$ = librarypath$()
x$ = cachepath$()
x$ = publicpath$()
x$ = picturespath$()
x$ = sharedpicturespath$()
x$ = camerapath$()
x$ = sharedcamerapath$()
x$ = musicpath$()
x$ = sharedmusicpath$()
x$ = moviespath$()
x$ = sharedmoviespath$()
x$ = alarmspath$()
x$ = sharedalarmspath$()
x$ = downloadspath$()
x$ = shareddownloadspath$()
x$ = ringtonespath$()
x$ = sharedringtonespath$()
reached = 1
assert_eq(reached, 1, "all eighteen platform paths answer without raising")

test_case("sys/generated-names")
assert_true(len(tempfilename$()), "tempfilename$ answers a path")
assert_true(len(randomfilename$()), "randomfilename$ answers a name")
assert_true(len(guidfilename$(1)), "guidfilename$ with separators")
assert_true(len(guidfilename$(0)), "guidfilename$ without them")

rem The separator-less form is the shorter of the two, which is the
rem whole difference between them.
if len(guidfilename$(0)) < len(guidfilename$(1)) then shorter = 1
assert_true(shorter, "and dropping the separators makes it shorter")

test_case("sys/directories")
rem mkdir and rmdir are the Pascal built-ins: they raise on failure and
rem answer 1 whatever happens, so the 1 carries no information. Calling
rem rmdir on a directory that is not there is a runtime error, not a
rem zero, which is why the guard below is dir_exists and not the return
rem value. forcedirectories is the odd one out and does report.
d$ = "bin/p9b_sys_dir"
deep$ = "bin/p9b_sys_deep/a/b"
if dir_exists(d$) <> 0 then rmdir(d$)

assert_eq(mkdir(d$), 1, "mkdir answers")
assert_true(dir_exists(d$), "and the directory is there")
assert_eq(rmdir(d$), 1, "rmdir answers")
assert_false(dir_exists(d$), "and it is gone")

assert_eq(forcedirectories(deep$), 1, "forcedirectories reports success")
assert_true(dir_exists(deep$), "and makes the whole chain")

test_case("sys/files")
f$ = "bin/p9b_sys_file.txt"
file_writealltext(f$, "content")
assert_eq(fileexists(f$, 0), 1, "fileexists finds it")
assert_eq(fileexists(f$, 1), 1, "and follows links when told to")
assert_eq(fileexists("bin/p9b_sys_absent.txt", 0), 0, "and does not invent one")
assert_eq(kill(f$), 1, "kill deletes it")
assert_eq(fileexists(f$, 0), 0, "and it is gone")

test_case("sys/environment")
rem The variable that exists on every platform this runs on differs, so
rem what is asserted is that a name nobody sets answers empty.
assert_eq(environ$("P9B_A_NAME_NOBODY_SETS"), "", "an unset variable answers empty")

test_case("sys/colours")
rem A round trip, so no colour name has to be assumed. 255 is whatever
rem this platform calls it; what matters is that the two agree.
name$ = colortostr$(255)
assert_true(len(name$), "colortostr$ answers a name")
assert_eq(color(name$), 255, "and color reads it back")
assert_true(alphacolor("Red"), "alphacolor understands a colour name")

test_case("sys/chdir")
rem Changing the working directory affects every file that runs after
rem this one, so it goes last and the restore is the next statement.
assert_eq(chdir("bin"), 1, "chdir answers")
chdir("..")
assert_true(dir_exists("bin"), "and the relative path still resolves afterwards")

if dir_exists(deep$) <> 0 then rmdir(deep$)
rem Phosphor: remove the whole scratch chain so bin/ is left clean.
if dir_exists("bin/p9b_sys_deep/a") <> 0 then rmdir("bin/p9b_sys_deep/a")
if dir_exists("bin/p9b_sys_deep") <> 0 then rmdir("bin/p9b_sys_deep")
