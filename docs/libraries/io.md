# io — files, directories and paths, where a failure is an answer

`engine/libs/PhosphorIoLib.pas` · 58 functions · always available

## What it is for

This is the library a program uses to read and write whole files, walk
directories, and take a path apart. Its founding promise is **byte fidelity**: no
BOM is written and no line ending is translated, so eleven characters written are
eleven read back and a bare LF stays one character. A file written on Windows and
read on Linux is the same file, and a golden over one holds on both.

Nothing here raises. A write that could not happen answers `0`, a read of a file
that is not there answers `""`, a listing of a directory that does not exist
answers `""` — and where the reason is worth knowing, `ioerror()` holds a code and
`iostrerror$()` the English text for it. That is the same house rule the rest of
the engine follows, with one consequence a caller must plan for: **empty is a real
answer**. `""` from `file_readalltext$` is an empty file *or* a missing one;
`file_getsize` answers `0` for a file with nothing in it *and* for a file that was
never there. When the difference matters, ask `file_exists` or read `ioerror()`
immediately after the call — not three calls later, because only some functions
write to that slot and the rest leave whatever the last one left.

A mutator answers **information**, not "I tried". `dir_delete` answers whether the
directory is gone afterwards, so a non-empty directory without the recursive flag
answers `0` and stays standing; `dir_create` answers whether the directory exists
afterwards, so creating one that is already there answers `1`. Both refuse an empty
path or a bare filesystem root before touching anything — `dir_delete("", 1)` once
resolved the empty string to the root of the current drive and deleted from there,
answering success.

The path half is **pure string work**: no file has to exist, nothing is checked
against the disk, and `/` and `\` both separate on every platform, so a path
written with `/` behaves identically on Windows and Linux. Directory listings are
LF-joined, hold **bare names** (never full paths, even from a recursive walk), and
are sorted by **bytes** rather than by the machine's collation — an arbitrary
order, but the same arbitrary order everywhere. Index them with `line$(list$, n)`,
which is base-1 like every other index in Phosphor.

Everything that touches the disk asks the [filesystem
sandbox](../embedding.md#the-filesystem-sandbox) first, at **every level** of a
recursive walk, so a directory symlink cannot carry a listing or a deletion out of
the root. Outside the root, `file_exists` and `dir_exists` answer `0` — a
deliberate lie, because answering truthfully would map a filesystem the script is
not allowed to read.

## Functions

### Whole-file text

| function | what it answers |
| --- | --- |
| `file_readalltext$(path$) → str` | the whole file, byte for byte. `""` when the file is missing, locked or outside the sandbox — and `ioerror()` becomes `2`. An empty file answers `""` too |
| `file_writealltext(path$, text$) → num` | `1` when the bytes were written (creating or replacing the file), `0` when the path was refused or could not be opened. Writing `""` makes an empty file |
| `file_appendalltext(path$, text$) → num` | `1` when the text was added to the end; a file that does not exist is created. It reads the file and rewrites it, so the cost is the size of the **file**, not of the addition — for repeated appending, open a channel instead |
| `file_exists(path$) → num` | `1` if the file is there. `0` for a directory, and `0` for anything outside the sandbox root whether it exists or not |
| `file_delete(path$) → num` | `1` when the file is gone by this call. `0` when it was missing, in use, or refused — a refusal also sets `ioerror()` to `3`, a plain failure sets nothing |
| `file_copy(src$, dst$ [, overwrite]) → num` | `1` when the bytes arrived. `0` when either end was refused, the source could not be read — or the three-argument form was given `0` and the target already exists. **The two-argument form always overwrites** |
| `file_move(src$, dst$) → num` | `1` when the rename happened. `0` when refused, when the target already exists, or when the two paths are on different volumes: it is one rename, with no copy-and-delete fallback |
| `file_createempty(path$) → num` | `1` when a zero-length file exists afterwards — it **truncates** one that was already there. `0` when refused |
| `file_getsize(path$) → num` | the size in bytes. `0` for a missing, locked or refused file, which is also what an empty file answers |
| `savetext$(path$, enc$, text$) → str` | `path$` — always, written or not. The encoding argument is accepted and ignored (utf-8 *is* raw bytes here). This is the one function on the page that **cannot report a failure**: it neither answers one nor sets `ioerror()`. Use `file_writealltext` when you need to know |
| `opentext$(path$, enc$) → str` | the file's text, `""` when it could not be read. Unlike `file_readalltext$` it leaves `ioerror()` untouched, so a failure here is invisible |

### Bytes

| function | what it answers |
| --- | --- |
| `file_readallbytes@(path$) → handle` | a byte buffer holding the file. A missing or refused file still answers a **valid handle** — an empty one, so `buffer_len` of it is `0`. There is no failure handle to check for |
| `file_writeallbytes(path$, bytes@) → num` | `1` when the buffer's bytes reached the file. `0` when the path was refused, or when the handle is not a byte buffer — a fabricated handle writes nothing rather than being obeyed |

The handle is the same one `buffer_new@` works on, so a file can be read, edited in
place and written back without a conversion step.

### Timestamps

Times are **date numbers**, the same values `now` and `strtodate` speak.

| function | what it answers |
| --- | --- |
| `file_getcreationtime(path$) → num`, `file_getlastwritetime(path$) → num`, `file_getlastaccesstime(path$) → num` | the file's timestamp. All three read the **same** underlying value — the modification time the filesystem keeps — so they always agree. `0` when the file is missing or refused |
| `file_setcreationtime(path$, t) → num`, `file_setlastwritetime(path$, t) → num`, `file_setlastaccesstime(path$, t) → num` | `1` when the sandbox allowed the attempt, `0` when it refused. All three set that same modification time, and none of them checks that the OS accepted it, so `1` means "asked", not "verified" — read it back if it matters |
| `dir_setcreationtime(path$, t) → num`, `dir_setlastwritetime(path$, t) → num`, `dir_setlastaccesstime(path$, t) → num` | always `1`. These do **not touch the filesystem**: the value goes into a table inside the process, in three separate slots, because a directory's date cannot be read back portably |
| `dir_getcreationtime(path$) → num`, `dir_getlastwritetime(path$) → num`, `dir_getlastaccesstime(path$) → num` | the value stored earlier **in this run**, and `0` when nothing was stored — including for a directory that really exists with a real date on disk. The key is the literal string given, so `"a/b"` and `"a/b/"` are different entries, and the table dies with the process |

### Directories

| function | what it answers |
| --- | --- |
| `dir_exists(path$) → num` | `1` if the directory is there; `0` outside the sandbox root, existing or not |
| `dir_create(path$) → num` | `1` when the directory exists afterwards — the whole missing chain is made, and one that already existed also answers `1`. `0` with `ioerror()` `3` when refused, which includes an empty path and a filesystem root |
| `dir_delete(path$ [, recursive]) → num` | `1` when the directory is gone. Without the flag, a **non-empty** directory answers `0` and stays where it is (`ioerror()` `3`); with the flag the tree goes. Two asymmetries worth knowing: a directory that was never there answers `0` non-recursively but `1` recursively, and an empty path, a bare separator or a drive root is refused outright by both |
| `dir_isempty(path$) → num` | `1` when the listing holds neither files nor subdirectories. A directory that does not exist, or that the sandbox refuses, also lists nothing and so also answers `1` |
| `dir_getfiles$(path$ [, pattern$ [, recursive]]) → str` | the file names, LF-separated and byte-sorted. `""` when there are none, when the directory is missing, or when it was refused. The glob (`*`, `?`) is matched **case-insensitively on every platform**, and the recursive form still answers bare names — you lose which subdirectory each came from |
| `dir_getdirectories$(path$ [, pattern$ [, recursive]]) → str` | the same, for subdirectory names |
| `dir_getentries$(path$ [, pattern$]) → str` | files and subdirectories together, one list. There is no recursive form of this one |
| `dir_getparent$(path$) → str` | everything before the last separator, a trailing separator on the input ignored first. `""` when there is no separator — a bare name has no parent to name, and neither does a root |
| `dir_isrelativepath(path$) → num` | `1` when the path has no leading separator and no drive letter. `""` answers `1` |
| `dir_getcurrent$() → str` | the process working directory. Not filtered by the sandbox — it is where relative paths resolve from, whether or not the script may read it |
| `dir_setcurrent(path$) → num` | `1` when the working directory moved. `0` when the directory does not exist, or when it is outside the root — the move is refused rather than the writes that would follow it |
| `dir_copy(src$, dst$) → num` | `1` when the destination root was created and both ends were permitted, having then copied the tree file by file. A single file inside that could not be copied is **not** reported: the answer covers the destination, not every leaf |
| `dir_move(src$, dst$) → num` | `1` when the rename happened. `0` when refused, when the target exists, or across volumes — like `file_move`, there is no copy fallback |

### Paths — pure string operations

None of these touch the disk, none is sandbox-checked, and `/` and `\` both count
as separators on every platform.

| function | what it answers |
| --- | --- |
| `path_combine$(a$, b$ [, c$]) → str` | the parts joined with the platform separator, unless the left part already ends in one. A **rooted second part is appended, not obeyed**: `path_combine$("one", "/two")` answers `one\/two`, it does not start over at the root |
| `path_getdirectoryname$(path$) → str` | the directory part **without** a trailing separator; `""` when the path has no separator |
| `extractfilepath$(path$) → str` | the same directory part **with** its trailing separator; `""` when there is no separator |
| `path_getfilename$(path$) → str`, `extractfilename$(path$) → str` | the last component — the whole string when there is no separator. Two spellings of one function |
| `path_getextension$(path$) → str`, `extractfileext$(path$) → str` | the last dot of the **last component** onward, dot included. `""` when that component has no dot, so a dot in a directory name is never mistaken for an extension |
| `path_getfilenamenoext$(path$) → str` | the last component with its extension cut off; the whole name when there is none |
| `path_changeextension$(path$, ext$) → str`, `changefileext$(path$, ext$) → str` | the path with everything from the last dot replaced by `ext$` — **appended** when there was no extension. Pass `ext$` with its dot; nothing is inserted for you |
| `path_hasextension(path$) → num` | `1` when the last component contains a dot, `0` otherwise |
| `path_getfullpath$(path$) → str` | the absolute form, resolved against the current working directory. It does not check that anything exists, and it is not sandbox-checked — an answer here is not permission |
| `path_ispathrooted(path$) → num` | `1` when the path starts with a separator or carries a drive letter; `0` for `""` |
| `path_isrelativepath(path$) → num` | the same question the other way round; identical to `dir_isrelativepath` |
| `path_getpathroot$(path$) → str` | `C:\` for a drive-letter path (with that backslash on every platform), the leading separator for a rooted one, `""` for a relative path |
| `path_matchespattern(name$, pattern$ [, casesensitive]) → num` | `1` when the glob matches. The third argument is case-**sensitive**: `1` is strict, `0` and the two-argument form are lenient. `*` and `?` have no path-segment meaning here — `*` matches separators too |
| `path_hasvalidpathchars(s$) → num` | `0` when the string holds a control character (below 32), `1` otherwise. `""` answers `1` |
| `path_hasvalidfilenamechars(s$) → num` | the same, and also `0` for `/ \ : * ? " < > |` — rejected on every platform, so a name that is legal on Linux and illegal on Windows is refused on both |

### The last I/O error

| function | what it answers |
| --- | --- |
| `ioerror() → num` | `0` clean, `2` a read that found nothing, `3` an operation refused. Only the functions noted above write to it — everything else leaves it alone, so read it **immediately** after the call you care about, not later |
| `iostrerror$() → str` | the text for that code: `"No error"` for `0`, `"file not found"`, `"path not found"`, and named entries for the other codes a BASIC program meets. Always English, on every machine: the operating system's own message came back in the machine's language and its ANSI code page, which is not valid UTF-8 and could not hold a golden across two computers. A code with no entry reads `I/O error <n>` |

## A worked example

A small archiving job: build a work directory under the platform's temp path,
write some logs into it, copy every `.log` into an archive beside them, and clear
up — checking the answer at each step instead of assuming it.

```basic
rem Collect every .log in a work directory into an archive beside it.

work$ = path_combine$(temppath$(), "phosphor_io_demo")
arch$ = path_combine$(work$, "archive")

if dir_exists(work$) <> 0 then dir_delete(work$, 1)

if dir_create(work$) = 0 then
  println "cannot use " + work$ + ": " + iostrerror$()
else
  dir_create(arch$)
  file_writealltext(path_combine$(work$, "monday.log"), "6 passed" + chr$(10))
  file_writealltext(path_combine$(work$, "tuesday.log"), "7 passed, 1 failed" + chr$(10))
  file_writealltext(path_combine$(work$, "notes.txt"), "not a log")

  names$ = dir_getfiles$(work$, "*.log")
  total = 0
  i = 1
  while line$(names$, i) <> ""
    name$ = line$(names$, i)
    src$ = path_combine$(work$, name$)
    total = total + file_getsize(src$)
    rem the 0 says "do not overwrite": an archive copy already there is kept
    ok = file_copy(src$, path_combine$(arch$, name$), 0)
    println name$ + "  " + str$(file_getsize(src$)) + " bytes  copied=" + str$(ok)
    i = i + 1
  wend
  println "archived " + str$(total) + " bytes"

  if dir_delete(work$, 1) = 0 then println "cleanup failed: " + iostrerror$()
endif
```

Three things it relies on:

- **The listing is names, not paths.** `dir_getfiles$` answers `monday.log`, not
  the path to it, so every use of a listed name goes back through `path_combine$`.
  That is also why the loop can end on `""`: `line$` past the end is empty, and an
  empty listing is empty on the first pass.
- **`archive` is not in the listing.** `dir_getfiles$` is files only and
  non-recursive by default, so the directory the loop is writing into cannot turn
  up as one of its own inputs.
- **Every answer is checked, including the cleanup.** `dir_delete` reports whether
  the tree really went. A version that ignored it would leave a full directory
  behind and say nothing — which is exactly the bug the function was changed to
  make impossible.

## Notes

**Streaming, not whole-file.** Everything here reads or writes a file in one go.
For record-at-a-time work — reading a large file line by line, appending without
rewriting, seeking — use the classic channel statements (`open … for input as #1`,
`input #1`, `println #1`, `seek`, `eof`), which are language, not library, and are
described in [language-reference.md](../language-reference.md).

**Binary.** `file_readallbytes@` and `file_writeallbytes` are the ends of the pipe;
the middle is the [buffer](buffer.md) package, which mutates the very same handle,
and the `bytelen`/`byteat`/`bytemid$` primitives in `str`, which read bytes out of
a string.

**Two spellings of four functions.** `extractfilename$`, `extractfileext$` and
`changefileext$` are the traditional BASIC names for `path_getfilename$`,
`path_getextension$` and `path_changeextension$` — the same code registered twice,
so a program written against either spelling runs. `extractfilepath$` is the one
that is genuinely different from its `path_*` neighbour: it keeps the trailing
separator that `path_getdirectoryname$` drops.
