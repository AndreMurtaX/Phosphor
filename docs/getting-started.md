# Getting started with Phosphor BASIC

This page is for someone who downloaded a release and wants to run a program in
the next five minutes. Building from source is in the [README](../README.md);
the language itself is in [language-reference.md](language-reference.md).

## What is in the archive

One binary, `phosphor` (`phosphor.exe` on Windows). It is the interpreter, the
REPL, the compiler to portable bytecode, the packer that makes a standalone
executable, the debugger, and the host for GUI programs -- all in one file. Next
to it: `LICENSE`, this documentation, and `examples/`.

### What it needs from the machine

| | Windows | Linux |
| --- | --- | --- |
| the interpreter itself | nothing | `libgtk2.0-0` (the GUI library, linked even for console programs) |
| the `sqlite_*` functions | `sqlite3.dll` -- **included** in the archive, beside `phosphor.exe` | `libsqlite3-0` |
| `https` in the `http_*` functions | OpenSSL 3: `libssl-3-x64.dll` and `libcrypto-3-x64.dll` on the `PATH` or beside `phosphor.exe` (not included) | `libssl3` |

A missing library never stops a program that does not use it. A program that
does use it can ask first: `sqlite_available()` answers 0, and an https request
fails with `http_status` 0.

## Your first program

Save this as `hello.bas`:

```basic
println "Hello from Phosphor"
for i = 1 to 3
  println "line " + str$(i)
next
```

and run it:

```
phosphor hello.bas
```

`print` writes without a newline and `println` with one. Indexing is **base 1**
everywhere: the first character of a string, the first element of an array.

## The other things the binary does

```
phosphor                              an interactive REPL; state persists between lines
phosphor --sandbox <dir> <file.bas>   confine every path the program names to <dir>
phosphor compile <in.bas> <out.pbc>   compile to portable bytecode
phosphor <file.pbc>                   run compiled bytecode
phosphor pack <in.pbc> <out>          a standalone executable, no Phosphor needed to run it
phosphor debug <file.bas>             step through a program; see debugging.md
phosphor <file.bas> one "two words"   give the program arguments: paramstr$(1), (2)
phosphor <file.bas> -- --verbose      ...including ones that start with "-"
phosphor --version | --help
```

Everything after the file is the program's own: `paramcount()` says how many
there are and `paramstr$(i)` reads them, with `paramstr$(0)` the program's path.
`phosphor`'s run options (`--out`, `--sandbox`, `--no-console`, `--gui`) still
work after the file, and any other word starting with `-` is refused unless it
follows `--`, so a misspelt `--sandbox` stops the run instead of being handed to
the program; `-` alone is an ordinary word. `phosphor -- -name.bas` runs a file
whose name starts with `-`. An empty file name is refused. On Windows the line is
split by Microsoft's own rules (`\"` is a quote inside a quoted argument), which
is what every launcher encodes for, and every argument reaches the program as
UTF-8 -- bytes that are not, on Linux, arrive as U+FFFD. A packed executable's
whole command line is its program's.

The REPL waits for input: start it from a terminal you type into, and leave it
with end-of-file -- Ctrl+Z then Enter on Windows, Ctrl+D on Linux.

## Errors are values

A library function that fails does not crash the program. It answers a value
that says so (often 0 or `""`) and records why: `ioerror()` after a file
function, `http_error()` after an http one, `sqlite_error()` after an SQLite
one. A script error -- dividing by zero, a wrong type -- can be caught:

```basic
on error goto failed
x = 1 / 0
println "not reached"
end
failed:
println "caught: " + errmsg$()
```

## Running a program you did not write

`--sandbox <dir>` confines the program's file access to one directory. It is
the only limit the console host puts on a script: there is no time or memory
ceiling unless a host that embeds Phosphor sets one (see
[embedding.md](embedding.md)). Read the limits listed in the
[changelog](../CHANGELOG.md) before trusting a script you did not write.

## Where to go next

- [language-reference.md](language-reference.md) -- the language, with examples.
- [function-reference.md](function-reference.md) -- every built-in function.
- [libraries/](libraries/) -- one page per library: files, strings, JSON,
  SQLite, HTTP, zip, regex, GUI, and more.
- [embedding.md](embedding.md) -- linking the engine into your own Free Pascal
  program, with the execution ceilings a host can set.
- `examples/` in the archive -- runnable programs, including two windowed ones
  that wait for you to close them: `gui_demo.bas`, and `contact_manager.bas`, a
  whole application -- suppliers, customers, their contacts and the history of
  what was said to them, in SQLite, behind a login. Run it with
  `phosphor examples/contact_manager.bas`; it needs the SQLite runtime
  (`sqlite3.dll` beside `phosphor.exe` on Windows, `libsqlite3` on Linux).
