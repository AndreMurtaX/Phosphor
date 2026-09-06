# config — settings a program keeps between runs, as an INI file

`engine/libs/PhosphorConfigLib.pas` · 31 functions · always available (registered by the engine, so every host has it)

## What it is for

A program that wants to remember something — a window size, a theme, how many
times it has run — needs a place to put it and a format both it and a person can
read. This library is that place: a **config handle** over an INI file, opened
with `cfg_open@(path$)`, read with the `cfg_get*` family and written with the
`cfg_set*` family. The file is the familiar `[Section]` / `key=value` shape, so
it can be edited by hand between runs.

The handle holds the whole file **in memory**. A set changes the memory copy and
marks the handle modified; nothing reaches the disk until `cfg_save(c@)`, or on
every set if the config was opened with `cfg_open_auto@` (or switched later with
`cfg_autosave@`). Dropping the handle at the end of the program writes *nothing*
— that is deliberate, so a program that deleted its config file does not find it
recreated on the way out. `cfg_reload@(c@)` goes the other way: throw the memory
copy away and re-read what is on disk. Two handles on the same file are two
independent copies, and the last one to save wins.

Three design stances are worth knowing before the first call. **An empty section
name means the default section `General`**, so `cfg_set@(c@, "", "theme",
"dark")` and `cfg_sets@(c@, "theme", "dark")` reach the same key — the
`s`-suffixed calls are a shorthand for the default section, not a different
store. **Numbers are written in a fixed, invariant format** (`.` as the decimal
point, no thousands separator), never the machine locale, so a file written on a
Portuguese desktop reads back identically on an English server. And **a missing
key is not a failure**: every read takes the answer you want for that case as its
last argument and hands it straight back, so there is no error to check and no
sentinel to recognise.

What *is* an error is a bad handle. `cfg_open@` answers a handle, and every other
call rejects a value that is not one with a catchable runtime error, `not a valid
config handle` — the error is returned by the library and raised by the VM, so
`on error goto` sees it like any other. The mutators answer **the handle they
were given** rather than a success flag, which is what lets a set be written
inline where its handle is wanted next.

Two things a caller would otherwise be surprised by. `cfg_getn` applies your
default only when the key is **absent**; a key that is present but does not parse
as a number reads as `0`, because the key does exist. And `cfg_getb` treats
exactly the string `1` as true — a hand-edited `true` or `yes` reads as false.

## An .ini is a file

A configuration file is confined by the [sandbox root](../embedding.md#the-filesystem-sandbox)
like anything else a program opens. Outside it, `cfg_open@` **binds no file**: the
handle still opens and the config still works entirely in memory, `cfg_filename$`
answers `""`, and `cfg_save` answers `0` having written nothing. A program gets an
object it can use and a failure it can see, rather than a nil handle or a write
somewhere it did not ask for.

That was not always true. Until 2026-09-06 this library opened an `.ini` by path
with no check at all, so a sandboxed script could read and write one anywhere on
the disk while `file_writealltext` to the very same path was refused — and
`scripts/check-sandbox.py` said nothing, because the ways it knew of opening a
file did not include an INI. Both are fixed, and `tests/suite/58_sandbox` pins the
refusal and the ordinary case together.

## Functions

### Opening a config, and where configs live

| function | what it answers |
| --- | --- |
| `cfg_open@(path$) → handle` | a config handle bound to `path$`, holding the file's contents in memory. A path that does not exist is not an error: the config is simply empty, and the file appears on the first save. A path **outside the sandbox root** binds no file at all — see *An .ini is a file* above |
| `cfg_open_auto@(path$) → handle` | the same, with autosave already on — every later set writes the whole file through. Nothing is written until that first set |
| `cfg_filename$(c@) → str` | the path the handle was opened with, unchanged |
| `cfg_path$() → str` | the platform's per-application configuration directory, as a path; the system temp directory when the platform names none, and a directory **inside the sandbox root** when a root is set. It answers a location, it does not create it |

### Strings

| function | what it answers |
| --- | --- |
| `cfg_set@(c@, section$, key$, value$) → handle` | the handle. `section$` empty means `General` |
| `cfg_get$(c@, section$, key$, default$) → str` | the stored string; `default$` unchanged when the key is not there |
| `cfg_sets@(c@, key$, value$) → handle` | the handle; writes into `General` |
| `cfg_gets$(c@, key$, default$) → str` | the string from `General`, or `default$` when absent |

### Numbers

Written with `.` as the decimal point regardless of locale, and read back the
same way.

| function | what it answers |
| --- | --- |
| `cfg_setn@(c@, section$, key$, n) → handle` | the handle |
| `cfg_getn(c@, section$, key$, default) → num` | the stored number; `default` when the key is absent; `0` when the key is there but its text is not a number |
| `cfg_setns@(c@, key$, n) → handle` | the handle; writes into `General` |
| `cfg_getns(c@, key$, default) → num` | the number from `General`, with the same two cases |

### Booleans

Stored as the text `1` or `0`; anything non-zero going in is `1`.

| function | what it answers |
| --- | --- |
| `cfg_setb@(c@, section$, key$, n) → handle` | the handle |
| `cfg_getb(c@, section$, key$, default) → num` | `1` when the stored text is exactly `1`, `0` for any other stored text, and `default` when the key is absent |
| `cfg_setbs@(c@, key$, n) → handle` | the handle; writes into `General` |
| `cfg_getbs(c@, key$, default) → num` | the flag from `General`, with the same three cases |

### Asking what is there

The key-level calls map an empty section name to `General`; the section-level
ones (`cfg_section_exists`, `cfg_keycount`, `cfg_keys$`, `cfg_section_delete@`)
take the section name **literally**, so `""` there means a section actually named
`""`, which is no section at all.

| function | what it answers |
| --- | --- |
| `cfg_exists(c@, section$, key$) → num` | `1` if that key is present, `0` if it is not — including when the section itself does not exist |
| `cfg_haskey(c@, key$) → num` | the same question against `General` |
| `cfg_section_exists(c@, section$) → num` | `1` if the section is present, `0` otherwise |
| `cfg_keycount(c@, section$) → num` | how many keys the section holds; `0` for an empty section and `0` for one that does not exist — `cfg_section_exists` is what tells those apart |
| `cfg_sectioncount(c@) → num` | how many sections the config holds; `0` for an empty config |
| `cfg_sections$(c@) → str` | every section name, newline-separated, in file order; `""` when there are none |
| `cfg_keys$(c@, section$) → str` | every key name in that section, newline-separated; `""` for an empty section and `""` for one that does not exist |

### Disk

| function | what it answers |
| --- | --- |
| `cfg_modified(c@) → num` | `1` while the memory copy differs from the last save, `0` right after a save, a reload, or an open |
| `cfg_save(c@) → num` | `1` once the whole file has been written, creating any missing directories along the path. It writes whether or not anything changed. A write the OS refuses is a catchable runtime error carrying the OS message. **`0` means no file was ever bound** — the path was outside the sandbox root when the handle was opened, so there is nowhere to write and nothing was written |
| `cfg_reload@(c@) → handle` | the handle, now holding what is on disk — every unsaved change is discarded, and `cfg_modified` returns to `0`. Reloading a file that no longer exists leaves an empty config |

### Removing

| function | what it answers |
| --- | --- |
| `cfg_delete@(c@, section$, key$) → handle` | the handle. Deleting a key that was not there is not an error and changes nothing that a later read can see — but the handle is still marked modified, and under autosave the file is still rewritten |
| `cfg_deletekey@(c@, key$) → handle` | the handle; deletes from `General` |
| `cfg_section_delete@(c@, section$) → handle` | the handle, with that whole section and its keys gone |
| `cfg_clear@(c@) → handle` | the handle, now empty. This empties the *memory* copy: the file on disk keeps its old contents until the next save |

### Autosave

| function | what it answers |
| --- | --- |
| `cfg_autosave@(c@, on) → handle` | the handle, with autosave on for non-zero `on` and off for `0`. Turning it on does not flush what is already pending — the next set does, or `cfg_save` right away |

## A worked example

A program that remembers its window size, its theme and how many times it has
been run. On the first run nothing exists, so every read answers the default the
call carries; those defaults are then written down, and the second run reads them
back.

```basic
rem Settings that survive a restart.

path$ = path_combine$(cfg_path$(), "phosphor_demo.ini")
c@ = cfg_open@(path$)

runs = cfg_getns(c@, "runCount", 0) + 1
cfg_setns@(c@, "runCount", runs)

w    = cfg_getn(c@, "Window", "width", 800)
h    = cfg_getn(c@, "Window", "height", 600)
dark = cfg_getb(c@, "Features", "darkMode", 0)

println "run " + str$(runs) + ", window " + str$(w) + "x" + str$(h)
if dark <> 0 then println "dark mode is on"

rem Write back what was read, so a first run leaves the defaults behind
rem for the next one to find.
cfg_setn@(c@, "Window", "width", w)
cfg_setn@(c@, "Window", "height", h)
cfg_setb@(c@, "Features", "darkMode", dark)

for i = 1 to cfg_sectioncount(c@)
  s$ = word$(cfg_sections$(c@), i, chr$(10))
  println "  [" + s$ + "] " + str$(cfg_keycount(c@, s$)) + " keys"
next

if cfg_modified(c@) <> 0 then x = cfg_save(c@)
println "saved to " + cfg_filename$(c@)
```

Two things worth noticing:

- **The reads carry the defaults, so there is no first-run branch.** `runs`,
  `w`, `h` and `dark` are ordinary values on every run; the only difference
  between the first run and the tenth is what was on disk.
- **`cfg_modified` is the whole persistence check.** Nothing has reached the file
  before that line — remove it and the settings are still correct in memory and
  still gone at exit.

## Notes

- The enumeration calls answer one newline-separated string rather than a list
  handle, which is why the example walks it with `word$(s$, n, sep$)`. A single
  empty answer means "nothing", and `wordcount` on it would still count one
  (empty) field — loop over `cfg_sectioncount` / `cfg_keycount` instead, as
  above, and an empty config runs the loop zero times.
- The library registers no closing call. A config handle stays valid for the life
  of the program, and the sweep that frees it at exit deliberately writes nothing:
  `cfg_save`, or autosave, is the only path to disk.
- Section and key names are matched case-insensitively, the way INI files
  ordinarily behave; the *values* are stored and returned exactly as given.
