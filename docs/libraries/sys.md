# sys — the machine around the program: arguments, paths, directories, colours

`engine/libs/PhosphorSysLib.pas` · 22 functions · always available

## What it is for

This is the library that answers questions about **the machine the program
happens to be running on**, rather than about the program's own data: the process
arguments, the platform's path separators, its temp and home directories, names
for a file nobody has used yet, make/remove a directory, does a file exist, remove
it, read an environment variable — plus a small self-contained colour table.

Its unit header states the design stance in one line, and it is worth taking
seriously: *many of these answer differently per platform and a few are empty on
desktop by design*. The tests for this library therefore assert that a call
**returns rather than raising**, and that a value is non-empty — not that it equals
any particular string. Nothing here fails, nothing here throws, and **empty is a
real answer**: `altseparator$()` is `""` on Linux because there is no second
separator there, and the eighteen platform paths below are `""` on every desktop
build because the desktop has no such place.

The second thing to know is **what a number coming back from the filesystem calls
means**. `mkdir`, `rmdir`, `chdir` and `kill` answer `1` whatever the filesystem
did — creating a directory that already exists, removing one that was never there,
and changing to a directory that does not exist all answer `1`. That `1` is
inherited from the oracle and carries no information. A `0` from any of them means
something quite specific: the call was **refused before it was attempted**, either
by the sandbox root the host installed or by the rule that a destructive call is
never handed a bare drive root or an empty path. Reporting success for something
that was never attempted is the fabricated answer this project forbids, so refusal
is the one thing these functions do report. Only `forcedirectories` and
`fileexists` genuinely answer the question they were asked.

The third is the **sandbox**. When a host installs a root (`phosphor --sandbox
<dir>`), the platform's scratch places answer *inside* it: `temppath$()`,
`homepath$()`, `documentspath$()` and `tempfilename$()` all point into the root's
scratch directory instead of the real user profile, so a script that keeps its
working files in the temp directory runs unchanged and contained rather than
failing on its first write. Redirecting beats refusing. `sandboxroot$()` reports
the cage but cannot open it — there is no registered setter, only the host, in
Pascal, can set or clear a root. One consequence surprises people: a **relative**
path is resolved against the *process working directory* before it is checked, and
`--sandbox` does not change that directory, so `mkdir("inside_ok")` is refused
unless the process already runs inside the root. Build working paths from
`temppath$()` and they are inside by construction.

## Functions

### Process arguments

| function | what it answers |
| --- | --- |
| `paramcount() → num` | how many arguments the **host process** was launched with, not counting the program name itself. This is the host's command line, not the script's: run under `bin/phosphor`, the `.bas` file is argument 1 and the console host accepts nothing after it |
| `paramstr$(i) → str` | argument `i` as text. `0` is the executable's own path, `1`…`paramcount()` the arguments. `""` for any index out of range, negative included — never an error. The one place in this engine where index `0` is meaningful, because that is the OS convention it reports |

### Separators

| function | what it answers |
| --- | --- |
| `dirseparator$() → str` | the directory separator: `"\"` on Windows, `"/"` elsewhere |
| `pathseparator$() → str` | the separator *between entries* of a search path such as `PATH`: `";"` on Windows, `":"` elsewhere |
| `altseparator$() → str` | the other separator the platform also accepts: `"/"` on Windows, `""` everywhere else. The empty string is the answer "there is no second one", not a failure — code that appends it blindly still works |

### Known directories

Each answers a path with a trailing separator, and each answers inside the sandbox
root when one is set.

| function | what it answers |
| --- | --- |
| `temppath$() → str` | the platform's temp directory. Under a sandbox, the root's `phosphor-scratch` directory, created on demand |
| `homepath$() → str` | the user's home directory. Under a sandbox, the same scratch directory |
| `documentspath$() → str` | the home directory with `Documents` appended. This one is **composed, not asked of the OS**: the directory is never checked, and on a system whose documents folder is named in another language it names a place that does not exist |
| `sandboxroot$() → str` | the filesystem root the host confined this process to — absolute, with no trailing separator — and `""` when there is no sandbox. Read-only by design: nothing a script can call sets or clears it |

### The eighteen platform paths

These exist so a program written against a mobile-shaped platform compiles and
runs unchanged on the desktop. On every build this engine currently ships they all
share one implementation and answer `""`; the test asserts only that all eighteen
return without raising.

```
shareddocumentspath$()  librarypath$()          cachepath$()
publicpath$()           picturespath$()         sharedpicturespath$()
camerapath$()           sharedcamerapath$()     musicpath$()
sharedmusicpath$()      moviespath$()           sharedmoviespath$()
alarmspath$()           sharedalarmspath$()     downloadspath$()
shareddownloadspath$()  ringtonespath$()        sharedringtonespath$()
```

Check the result before using it. An empty string joined to a filename produces a
*relative* path, which will quietly resolve against the working directory.

### Generated names

| function | what it answers |
| --- | --- |
| `tempfilename$() → str` | a full path in the temp directory for a file that does not exist yet. It **names** the file, it does not create it — so two calls in a row can hand back the same name, and only writing the first one makes the second differ. Under a sandbox: the scratch directory, a 32-character hex name and `.tmp` |
| `randomfilename$() → str` | 32 uppercase hex characters from a fresh GUID — a bare name, with no directory and no extension. Never empty, never repeated |
| `guidfilename$(dashes) → str` | a GUID as text with the braces removed: 36 characters with dashes when `dashes` is non-zero, 32 without when it is `0`. The zero form is exactly `randomfilename$()`'s shape |

### Directories and files

`0` from any of these means **refused**, not failed — see the third paragraph
above. An empty path, or a bare drive root such as `C:\` or `/`, is refused by
every destructive one of them even with no sandbox in force.

| function | what it answers |
| --- | --- |
| `mkdir(path$) → num` | `1`, having attempted to create the directory. Also `1` when it already existed, and when the parent does not exist and nothing was created. `0` only when refused |
| `rmdir(path$) → num` | `1`, having attempted to remove the directory. Also `1` for a directory that was never there, and for a non-empty one it could not remove. `0` only when refused. Removes one level: it is not recursive |
| `forcedirectories(path$) → num` | the odd one out, and the one to prefer: `1` when the whole chain of directories exists afterwards — creating however many levels were missing — and `0` when it could not be made, or was refused |
| `chdir(path$) → num` | `1`, having attempted to change the process working directory. Also `1` for a directory that does not exist, and for `""`, neither of which changes anything. `0` only when refused, which for this one means outside the sandbox root — it is a read, so the drive-root rule does not apply |
| `fileexists(path$, followlink) → num` | `1` when the file is there, `0` when it is not. A non-zero `followlink` resolves a symbolic link and asks about its target; `0` asks about the link itself. A refused path also answers `0`, which is indistinguishable from absent |
| `kill(path$) → num` | `1`, having attempted to delete the file. Also `1` for a file that was not there and for one the OS would not delete, so it is not a confirmation — call `fileexists` if you need one. `0` only when refused. Files only; a directory needs `rmdir` |

### Environment

| function | what it answers |
| --- | --- |
| `environ$(name$) → str` | the value of that environment variable, and `""` when it is not set. A variable set to the empty string and one that does not exist give the same answer, so this cannot test for presence. Read-only: there is no setter |

### Colours

The engine has no GUI, so this is a **self-contained name↔number table** — the
sixteen HTML colour names, held here and nowhere else. The numbers are in TColor
byte order (`$00BBGGRR`), which is why `Red` is `255` and `Blue` is `16711680`
rather than the other way round.

| function | what it answers |
| --- | --- |
| `color(name$) → num` | the number for a colour name, matched case-insensitively against the sixteen. Failing that it parses the string as a literal, so `"$00FF00"` and `"65280"` both read. A name it does not know answers `0` — which *is* Black, so an unrecognised name cannot be told apart from a request for black |
| `colortostr$(n) → str` | the name, when `n` is exactly one of the sixteen values. Otherwise a `$` and the number in hex, padded to six digits: `colortostr$(12345)` is `"$003039"`. A negative number is not clipped — `colortostr$(-1)` is `"$FFFFFFFF"` |
| `alphacolor(name$) → num` | the same lookup with an opaque alpha byte set: `alphacolor("Red")` is `4278190335`. Because the alpha byte is always added, an unknown name answers `4278190080` — opaque black — and never `0` |

## A worked example

A scratch working directory under the platform's own temp path: made, used, and
taken away again. It runs identically inside a sandbox, where every path it builds
lands in the root instead.

```basic
rem A scratch working directory under the platform's own temp path: made,
rem used, and taken away again. Every call below that touches the disk
rem answers 0 only when it was REFUSED, so that is what is worth testing.

println "arguments: " + str$(paramcount()) + ", program " + extractfilename$(paramstr$(0))
println "separators: dir '" + dirseparator$() + "'  path '" + pathseparator$() + "'  alt '" + altseparator$() + "'"
println "sandbox root: '" + sandboxroot$() + "'"

work$ = path_combine$(temppath$(), "phosphor_sys_demo")
logs$ = path_combine$(work$, "logs")
if forcedirectories(logs$) = 0 then
  println "refused: " + logs$
else
  note$ = path_combine$(logs$, randomfilename$() + ".txt")
  file_writealltext(note$, "home is " + homepath$())
  println "wrote " + extractfilename$(note$)
  println "exists: " + str$(fileexists(note$, 0)) + ", absent: " + str$(fileexists(path_combine$(logs$, "nope.txt"), 0))

  rem tempfilename$ picks a name; it does not create the file, which is
  rem why the next line says the file it named is not there.
  pick$ = tempfilename$()
  println "temp name " + extractfilename$(pick$) + ", exists: " + str$(fileexists(pick$, 0))

  kill(note$)
  println "after kill, exists: " + str$(fileexists(note$, 0))
  rmdir(logs$)
  rmdir(work$)
  println "directory still there: " + str$(dir_exists(work$))
endif

rem Colours are a table this library carries itself; the numbers are in
rem TColor byte order, so Red is 255 and Blue is not.
c = color("Teal")
println "Teal = " + str$(c) + " -> '" + colortostr$(c) + "', opaque " + str$(alphacolor("Teal"))
println "Blue = " + str$(color("Blue")) + ", a literal $00FF00 = " + str$(color("$00FF00"))
println "an unknown name = " + str$(color("chartreuse")) + " (which is " + colortostr$(0) + ")"
println "no such variable: '" + environ$("P9B_NOT_SET") + "', PATH length " + str$(len(environ$("PATH")))
println "an id for a run: " + guidfilename$(1)
```

Real output from a Windows box, run with no sandbox:

```
arguments: 1, program phosphor.exe
separators: dir '\'  path ';'  alt '/'
sandbox root: ''
wrote 060F5FB3F8A1449F923DFDCFAB1CB3D4.txt
exists: 1, absent: 0
temp name TMP00000.tmp, exists: 0
after kill, exists: 0
directory still there: 0
Teal = 8421376 -> 'Teal', opaque 4286611456
Blue = 16711680, a literal $00FF00 = 65280
an unknown name = 0 (which is Black)
no such variable: '', PATH length 3478
an id for a run: 866A1AEE-FED6-4AEC-B4A9-26B76782AE18
```

Two things worth noticing:

- **`temp name TMP00000.tmp, exists: 0`.** `tempfilename$()` reserves nothing.
  Between the name and the write there is a window in which another process — or
  the same program, calling twice — can take it. Use it as a suggestion, not as a
  claim, and write to it immediately; `randomfilename$()` is a better basis when
  the name only has to be unique among files this program makes.
- **`an unknown name = 0 (which is Black)`.** `color` cannot report failure,
  because every possible answer is a valid colour. If the name comes from a user
  or a config file, round-trip it — `colortostr$(color(name$))` gives back a name
  only when the table actually knew it.

## Notes

**Path *strings* are a different library.** Taking a path apart and putting it
back together — `extractfilename$`, `extractfilepath$`, `extractfileext$`,
`changefileext$`, `path_combine$` — is string surgery that never touches the disk,
and lives in the io library along with `dir_exists`, `dir_create`, `dir_delete`,
`file_delete` and the rest of the file API. Note that the io names and the six
here overlap in purpose but not in behaviour: `dir_create` and `file_delete`
report what actually happened, while `mkdir` and `kill` answer `1` regardless.
When the answer matters, prefer the io ones; these exist so an oracle-era program
keeps working.

**The sandbox seen from Pascal.** Everything a script can observe about the cage
is `sandboxroot$()` plus the redirection of the scratch paths. The ceiling itself
is proven from outside, in `tests/probe_sandbox.lpr`, which builds a victim tree
beyond the root and asserts it is still standing afterwards; `tests/suite/58_sandbox.bas`
pins only what a running program can see.
