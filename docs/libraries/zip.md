# zip — zip archives, written and read without leaving BASIC

`host/packages/PhosphorZipLib.pas` · 18 functions · opt-in host package (the shipped
`phosphor` console and GUI hosts call `RegisterZipFuncs`, so from the command line it
is always there; an embedder decides for itself)

## What it is for

A program that ships a report, bundles a folder for transport, or reads a `.zip`
someone else produced should not have to shell out to an external tool. This
package sits over FPC's `paszlib` zipper (`TZipper`/`TUnZipper`), which comes with
the compiler — **no external runtime library**, nothing to install, the same
behaviour on Windows and Linux. The engine itself stays free of it: archives are a
host concern, and a host that does not want them simply never registers the
package.

Two surfaces sit side by side, and both are complete on their own. The
**whole-archive** calls do one job each in one line — zip a directory, extract an
archive, count it, name its *n*-th entry — and touch no handle. The
**handle-based** calls open a writer (`zip_create@`) or a reader (`zip_open@`) and
then add, inspect, read in memory, or extract piece by piece. A writer's archive
does not exist on disk until `zip_close` flushes it; a reader has already examined
its entry list by the time the handle comes back, so counting and listing are free.

The design stance is the engine's I/O contract: **a failure is an answer**, not an
exception. Every function here returns `0`, `""` or a zero handle when it cannot do
what was asked, and records that in a single slot you read with `zip_error()` —
`0` means the last operation was clean. There is one deliberate exception, below.

The exception is **zip slip**. An entry name decides where a byte lands on disk,
and it comes from whoever built the archive, so `unzip_extract`, `zip_extract` and
`zip_extractall` first check every name in the archive: a leading `/` or `\`, a
Windows drive letter, or a `..` *path segment* gets the whole archive refused, and
that refusal is **raised as a runtime error**, not answered as `0`. A caller who
ignores return values must not be able to carry on believing it unpacked a tree.
Dots inside a file name (`my..notes.txt`) are not a path escape and extract
normally. Two more things worth knowing before you are surprised by them:
`zip_compress` takes only the files **directly in** the directory, not
subdirectories, and it sorts entry names byte-wise so the same folder produces the
same entry order on NTFS and ext4 alike; and `zip_addfile` checks that the file
exists and is inside the [sandbox root](../embedding.md#the-filesystem-sandbox)
**at the add**, where the program can still react, rather than letting a missing
file take the whole archive down later inside `zip_close`.

## Functions

### Whole-archive — one call, no handle

| function | what it answers |
| --- | --- |
| `zip_compress(zip$, srcdir$) → num` | `1` after writing `zip$` from the files sitting directly in `srcdir$` (subdirectories are not descended into; names are sorted byte-wise, so the entry order is identical on every filesystem). `0` if `srcdir$` is outside the sandbox root or anything fails, with `zip_error()` set to `1` |
| `unzip_extract(zip$, destdir$) → num` | `1` after extracting every entry under `destdir$`. `0` when the archive is missing or corrupt. If any entry name escapes `destdir$`, it **raises** a runtime error and writes nothing at all — not even the well-behaved entries |
| `unzip_count(zip$) → num` | how many entries the archive holds. `0` for a missing or corrupt file *and* `zip_error()` set to `1` — that flag is the only thing separating a broken archive from a genuinely empty one, which is the whole question this function is asked |
| `unzip_entry$(zip$, n) → str` | the name of the `n`-th entry, **1-based**. `""` with `zip_error()` set to `1` for an index outside the archive, or for an archive that could not be read: an out-of-range index is a refusal, not an empty name |

### Building an archive

| function | what it answers |
| --- | --- |
| `zip_create@(zip$) → handle` | a writer handle for a new archive at `zip$`. Nothing is written to disk yet — `zip_close` does that. A zero handle with `zip_error()` set to `1` if the writer could not be made |
| `zip_addfile(z@, disk$, name$) → num` | `1` after recording the file `disk$` to be stored under the archive name `name$`. `0` — right here, not later — when `disk$` does not exist or lies outside the sandbox root, and `zip_error()` becomes `1`. The rest of the archive is unaffected and still closes |
| `zip_addstr(z@, text$, name$) → num` | `1` after adding an entry named `name$` whose whole content is `text$`, with no file on disk anywhere. `0` when `z@` is not a writer handle. The name is stored exactly as given, `..` and all — this is how a hostile archive is built, and why the extractors check |
| `zip_quick(src$, zip$) → num` | `1` after making a whole archive holding just the one file `src$`, stored under its **bare name** — `bin/notes.txt` becomes the entry `notes.txt`, with no directory, whichever slash you typed. `0` on any failure |

### Reading an archive

| function | what it answers |
| --- | --- |
| `zip_open@(zip$) → handle` | a reader handle whose entry list has already been examined. A zero handle when the file is missing or is not a zip, with `zip_error()` left non-zero. A handle cannot be compared with a number in BASIC, so `zip_error()` right after the call is how you find out the open worked |
| `zip_count(z@) → num` | how many entries the reader holds. `0` when `z@` is not a reader handle (a *writer* handle is not one), with `zip_error()` set to `1` |
| `zip_exists(z@, name$) → num` | `1` when an entry with exactly that archive name is present, `0` when it is not — and also `0`, with `zip_error()` set, when `z@` is not a reader. Names match byte for byte, including their directory part |
| `zip_list$(z@) → str` | every entry name, joined by a single newline (`chr$(10)`), in archive order. `""` for an archive with no entries and `""` for a handle that is not a reader — the two are told apart by `zip_error()` |
| `zip_entrysize(z@, name$) → num` | the entry's **uncompressed** size in bytes. `0` with `zip_error()` set to `1` when there is no such entry, or when `z@` is not a reader |
| `zip_read$(z@, name$) → str` | the entry's content decompressed straight into a string, never touching the disk. `""` with `zip_error()` set to `1` when the entry is absent, unreadable, or `z@` is not a reader — an entry that really is empty answers `""` with the error slot clear |
| `zip_extract(z@, name$, dir$) → num` | `1` after writing that one entry under the **directory** `dir$`, keeping its path inside the archive (`doc/x.txt` lands at `dir$/doc/x.txt`). `0` when the entry is missing or `z@` is not a reader; **raises** if any name in the archive escapes `dir$` |
| `zip_extractall(z@, dir$) → num` | `1` after recreating the whole tree under `dir$`, regardless of any single-entry extraction done earlier on the same handle. `0` when `z@` is not a reader; **raises**, writing nothing, on an archive that escapes |

### Closing, and what went wrong

| function | what it answers |
| --- | --- |
| `zip_close(z@) → num` | `1` after releasing the handle. For a **writer** this is where the archive is compressed and written to disk, so a writer you never close leaves no file behind; for a **reader** it just frees. `0` with `zip_error()` set to `1` when `z@` is neither, so closing a handle twice reports the second attempt |
| `zip_error() → num` | `0` when the last zip operation was clean, `1` when it failed. It is one slot shared by every function on this page, so read it immediately after the call you care about. A failing call always sets it; the four pure inspectors (`zip_count`, `zip_exists`, `zip_entrysize`, `zip_list$`) only ever set it and never clear it, so a `1` left by an earlier failure survives them |

## A worked example

Bundle two generated files into one archive, read an entry back without ever
writing it to disk, and unpack the rest — with the extraction guarded, because
an archive from elsewhere is the one input this library does not trust.

```basic
rem Build a small archive from strings, inspect it, then unpack it.
dir_create("bin/reports")
z$ = "bin/reports/bundle.zip"

w@ = zip_create@(z$)
zip_addstr(w@, "id,total" + chr$(10) + "1,42", "data/rows.csv")
zip_addstr(w@, "generated by phosphor", "README.txt")
rem A file that may or may not be there: the add answers now, not at close.
if zip_addfile(w@, "bin/reports/logo.png", "img/logo.png") = 0 then
  println "no logo to bundle -- carrying on without it"
endif
zip_close(w@)                 rem the archive reaches disk on THIS line

r@ = zip_open@(z$)
rem A handle cannot be compared with a number, so the open is checked here.
if zip_error() <> 0 then
  println "cannot open " + z$
  end
endif

println "entries: " + str$(zip_count(r@))
println zip_list$(r@)
println "README.txt is " + str$(zip_entrysize(r@, "README.txt")) + " bytes"
if zip_exists(r@, "data/rows.csv") <> 0 then println zip_read$(r@, "data/rows.csv")

on error goto unsafe
n = zip_extractall(r@, "bin/reports/out")
on error goto 0
println "unpacked " + str$(zip_count(r@)) + " entries"
zip_close(r@)
end

unsafe:
println "refused: " + errmsg$()
zip_close(r@)
```

Two things worth noticing:

- **The missing logo is a value, not a catastrophe.** `zip_addfile` answers `0` at
  the call, the program prints a line and carries on, and `zip_close` still writes
  a perfectly good archive holding the two entries that were real.
- **The handler is not decoration.** Everything else here answers a failure, but a
  refused extraction *raises* — so the only way to survive an archive whose names
  climb out of `bin/reports/out` is `on error`, and `errmsg$()` then carries the
  reason. With an archive this program built itself the branch never fires; with
  one that arrived over the network it is the whole point.

## Notes

- Handles are the engine's ordinary handles, and every function here checks what
  it was actually given: a writer passed where a reader is expected — or a handle
  belonging to some other library entirely — is refused through `zip_error()` and
  never dereferenced.
- The whole-archive calls open and examine the file afresh for every question, so
  `unzip_count` followed by four `unzip_entry$` calls reads the archive five times.
  One `zip_open@` and one `zip_list$` answer the same thing from a single read.
- For compressing a single stream of bytes rather than a container of named
  entries, the sibling package is gzip (`gzip_compress$`, `gzip_compressfile`);
  both are listed in [function-reference.md](../function-reference.md).
