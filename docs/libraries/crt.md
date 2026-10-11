# crt — console control: screen, cursor, colour and the keyboard

`host/packages/PhosphorCrtLib.pas` · 29 functions · opt-in host package (the `phosphor` host registers it; an embedding host has it only if it calls `RegisterCrtFuncs`)

## What it is for

Classic-BASIC screen control for a terminal: clear the screen, put the cursor
somewhere, choose a colour, turn on an attribute, read a key. It is an **opt-in
package** rather than part of the engine for one reason — terminal control is
host-specific, and the engine is host-agnostic. A host that has no terminal (an
embedded one, a GUI-only build) simply does not register these names.

The design stance is the interesting part: **nothing here writes to the screen.**
Every screen-control function *returns* the ANSI escape sequence, and the program
emits it with `print`, which — unlike `println` — adds no newline. That buys two
things. The engine keeps a single output seam, so redirection, capture and a
packed program's log all still work, because a control sequence travels the same
path as ordinary text. And every sequence is a **value**: the test corpus asserts
that `at$(3, 10)` equals `chr$(27) + "[3;10H"` instead of looking at a screen.
It also composes — a positioned, bright, bold word is just a string you can build,
keep in a variable, and print later:

```basic
line$ = at$(5, 20) + color$(9) + bold$() + "READY" + reset$()
```

Rows and columns are **1-based**, like ANSI and like every other index in
Phosphor. Colours are indices `0`–`15` (`0`–`7` normal, `8`–`15` bright: 0 black,
1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan, 7 white). An index outside
that range is **not an error** — it emits the terminal's *default* colour, which
is a real answer, and the one you want when you mean "put this back the way the
user had it". Nothing in the screen or colour group can fail: no error, no
clamping, no bounds check. `at$(999, 999)` returns the sequence for row 999; what
an off-screen position does is the terminal's business, not the library's. Numeric
arguments are rounded to whole numbers on the way in.

Key input is the one part that touches the terminal for real. It reads the
keyboard directly — deliberately *not* through FPC's `crt` unit, which spins on a
non-interactive stdin — putting the terminal in raw/cbreak mode on first use, so
keys arrive one at a time and unechoed, and restoring it at `crt_done()` (unit
finalization is a backstop, so a forgotten `crt_done` still does not leave a
person's terminal in raw mode). **Ctrl+C restores it too**: Ctrl+C is the
ordinary way out of a key loop, and it ends the program as it always did — on
Unix the process is still killed by `SIGINT` (also `SIGQUIT`, `SIGTERM` and
`SIGHUP`, unless the program was started with one ignored), on Windows the
exit status is still `C000013A` — but the terminal's echo and line editing are
put back first. Until 2026-10-11 (round 9) they stayed off on both systems,
under any parent that does not reset them itself. **On Unix, Ctrl+Z and `fg`
work as in any full-screen program** (vim, less): stopping the program puts
the terminal back for the shell, and continuing it in the foreground puts raw
mode back, so the next `getkey$` answers the next key at once and unechoed.
Until round 10 bash's `fg` left the program with echo and line editing on —
`getkey$` waited for Enter — and dash prompted with echo off. (A program
continued in the background leaves the terminal alone until it is brought
forward.) A large paste into a key loop costs the same per key however much
of it is waiting; until round 10 the queue was quadratic, and a pasted
megabyte took 21 seconds to read. When stdin is **not** a terminal — a pipe, a
redirect, the headless test harness — there is no keyboard at all, so `inkey$()`
and `getkey$()` answer `""` and `keypressed()` answers `0` immediately, without
blocking and without touching the terminal.

### What a key is

One model, kept by both systems (round 8, 2026-10-11, set it down after Windows
and Linux had been answering differently):

- **A character key is its character**, a whole UTF-8 character including
  accented ones and those outside the Basic Multilingual Plane — an emoji is one
  key of four bytes on both systems, though Windows delivers it as two key
  events, which may arrive separately (until 2026-10-11, round 7, Windows
  dropped both halves without a trace; until round 8 two halves written
  separately were two U+FFFD). A Ctrl chord is its control character:
  Ctrl+A is `chr$(1)`, as a terminal sends it.
- **What is not a character is U+FFFD** (`EF BF BD`), never `""` and never raw
  bytes: a surrogate half with no partner on Windows, and on Unix a byte
  sequence that is not UTF-8 — one U+FFFD per maximal ill-formed subpart, the
  rule `environ$` keeps, so a Latin-1 terminal's `é` (byte `E9`) is U+FFFD and
  the key after it is still its own key (until round 8 Unix answered the raw
  bytes).
- **An arrow, a function key or another key with no character** comes back as
  `chr$(0)` plus a code byte on Windows (its virtual-key code) and as the raw
  escape sequence on Unix; Escape pressed on its own is `chr$(27)` with nothing
  after it. On Unix a sequence is what ECMA-48 says it is — `ESC [`, any
  parameter and intermediate bytes, and **one** final byte (`40`–`7E`); or
  `ESC O` and one byte; or the Linux console's `ESC [ [` and a letter — and
  the bytes after it are the next key. `ESC` followed by anything else is
  Escape on its own. So keys typed while the program is busy are still one key
  each: three presses of Up queued behind a `pause` are three keys, and Esc, `q`,
  `r` are three keys, as on Windows. (Until round 9 an escape took **every**
  byte already waiting, and all of those were one key.) The one ambiguity is
  the terminal's, not this library's: Escape typed and immediately followed by
  `[` or `O` while the program is busy reads as the start of a sequence.
- **A key is one key however its bytes arrive.** A terminal, an ssh link or a
  pty may hand over an arrow's `ESC` and its `[A`, or the two halves of an `é`,
  in two reads; the reader waits for the rest — **100 ms** after the last byte
  of an unfinished escape sequence (vim's `ttimeoutlen`), **500 ms** after the
  start of a UTF-8 character (the bound Windows gives the second half of a
  surrogate pair). Escape pressed alone is therefore answered 100 ms after it
  arrives. A character whose rest never comes is U+FFFD. (Until round 9 Unix
  never waited: a split arrow was three keys, a split `é` two U+FFFD.)
- **A modifier or lock key alone is not a key**: Shift, Ctrl, Alt, AltGr, the
  Windows keys, Caps Lock, Num Lock, Scroll Lock. A terminal sends nothing for
  them, and until round 8 Windows answered each press as `chr$(0)` plus its code
  — so a capital letter typed with Shift was two keys, and "press Y" read the
  Shift.
- **Alt+numpad entry is the character it composes** (hold Alt, type `0233` on
  the numpad, release Alt: `é`), which Windows delivers when Alt is released;
  the Alt press and the numpad digits are not keys.
- **A held key is a key per repeat**: Windows may report several presses of a
  held key as one event with a repeat count, and each of them is a key.

`keypressed()`, `inkey$()` and `getkey$()` read **one queue**: when
`keypressed()` answers `1`, `inkey$()` answers a key. (Until round 8 Windows'
`keypressed()` looked only at the first 32 console events, and answered `0`
forever behind 32 that were not keys — mouse moves, focus changes — while
`inkey$()` read the key at once.) A key whose first part has arrived and whose
rest may still be coming is **not a key yet**: `inkey$()` answers `""` and
`keypressed()` `0`, without waiting, until it is whole or its wait above has
run out — so a polling loop sees Escape alone 100 ms after it was pressed, and
a lone surrogate half on Windows 500 ms after a reader first saw it. (Until
round 9 Windows' `inkey$` *waited* those 500 ms, inside a call documented never
to block.)

**`input` reads a line, even in raw mode.** A key function leaves the terminal
in raw mode until `crt_done()`, but `input` puts it back in line mode for the
line — echo, line editing, the line ending at Enter — and returns it to raw mode
afterwards, so a menu key read with `getkey$` and then a name read with `input`
works without `crt_done()` between them. The line is read no further than its
Enter: a key typed straight after it is the next key function's. **Keys typed
ahead belong to the line, and are shown and edited like the rest of it**:
what the key functions had taken but not answered — on Windows the remaining
repeats of a held key, on Unix every key typed while the terminal was raw — was
typed first, so it begins the line; it appears after the prompt, and
Backspace, Ctrl+U and the rest reach back into it. What the screen shows is
what `input` answers. On Unix those keys are edited by the terminal's own
settings (`stty`: erase, kill, word erase, end of file, literal next, the echo
flags, `icanon`, `iutf8`, `icrnl`, `igncr`, `inlcr`) the way Linux's line
discipline (`n_tty`) would have edited them, so the same keys give the same
line whether they were typed ahead or after the prompt: without `iutf8` erase
takes one byte, without `icanon` nothing is edited; word erase takes what the
kernel calls alphanumeric, which includes a character such as `ã` (its table
is Latin-1, tested on a character's first byte); and a Tab is rubbed out by
the columns it took counted from where the prompt ended — the columns the
kernel counts, from what this host printed. Linux's own line discipline does
not re-read keys that arrived raw, and until round 9 handed them over as raw
bytes — a DEL inside the line, nothing on the screen; until round 10 the
editor ignored `icanon` and `iutf8`, stopped a word at a non-ASCII letter, and
rubbed a Tab out as if the line began at column 0, backing into the prompt.
On Windows the remaining presses of a held key begin the line when they are
text in a line as the console's own read keeps it — any character, a Tab and
the Ctrl chords included — and are dropped when they are not: Backspace,
Ctrl+J and Escape (which, before the line, have nothing to edit), and keys
with no character (arrows and function keys, which would move the cursor or
recall an earlier line). Until round 10 a held Tab or Ctrl chord lost them.
On Windows they were joined to the line after the console's read, invisible
and out of reach of Backspace, until round 9. (Until round 8, on Windows `input` after any key function — a
single `keypressed()` was enough — answered whatever keys had arrived, `h` and
then `ello` for the next `input`; on Linux it took the keys typed after the
Enter, where no key function could see them.)

## Functions

### Screen and cursor

| function | what it answers |
| --- | --- |
| `cls$() → str` | clear the whole screen **and** home the cursor — one string doing both, so a cleared screen never leaves the cursor where the old text ended |
| `clreol$() → str` | clear from the cursor to the end of the line; the rest of the screen is untouched |
| `clreos$() → str` | clear from the cursor to the end of the screen |
| `home$() → str` | move the cursor to row 1, column 1, changing nothing on screen |
| `at$(row, col) → str` | move the cursor to `row`, `col`, both 1-based. Off-screen numbers are emitted as given; the terminal decides what to do with them |
| `moveup$(n) → str` | move the cursor `n` cells up, relative to where it is |
| `movedown$(n) → str` | `n` cells down |
| `moveleft$(n) → str` | `n` cells left |
| `moveright$(n) → str` | `n` cells right |
| `hidecursor$() → str` | hide the cursor — worth doing before drawing, so the caret does not flicker across the screen |
| `showcursor$() → str` | show it again. A program that hides it and exits without this leaves the terminal with no cursor |
| `savepos$() → str` | tell the terminal to remember the cursor position |
| `restorepos$() → str` | go back to the remembered position. The terminal keeps **one** saved position, so these do not nest: a second `savepos$` overwrites the first, and a `restorepos$` with nothing saved goes to the terminal's idea of home |

### Text attributes

| function | what it answers |
| --- | --- |
| `reset$() → str` | turn *everything* off — every attribute and both colours. There is no per-attribute "off" here, so this is how you end any styled run |
| `bold$() → str` | bold (on many terminals, the bright variant of the current colour) |
| `faint$() → str` | faint / dim |
| `italic$() → str` | italic |
| `underline$() → str` | underline |
| `blink$() → str` | blink |
| `inverse$() → str` | swap foreground and background |

A terminal that does not implement one of these ignores its sequence — nothing is
printed and nothing fails. `faint$`, `italic$` and `blink$` are the ones most
often ignored, so do not use them to carry meaning on their own.

### Colour

| function | what it answers |
| --- | --- |
| `color$(fg) → str` | set the foreground to index `fg`. Anything outside `0`–`15` is the terminal's **default** foreground, not an error |
| `color$(fg, bg) → str` | set both in one sequence; each index falls back to its own default the same way |
| `bg$(bg) → str` | set the background only; out of range is the terminal's default background |

### Keyboard input

| function | what it answers |
| --- | --- |
| `inkey$() → str` | the key that is waiting, or `""` when none is — it never blocks, and a key only partly arrived is not one yet (see *What a key is*). `""` also means "there is no keyboard" (piped or redirected stdin), and the two cases are indistinguishable, so a polling loop needs an end condition of its own |
| `getkey$() → str` | block until a key is pressed and answer it. It answers `""` **only** when there is nothing to wait for — no terminal, or the input ended — so an empty result means *stop*, never *try again*; a loop that retries on `""` spins forever under a pipe |
| `keypressed() → num` | `1` when a key is waiting, `0` when none is. `0` with no keyboard, again without blocking |

### Setup, and the console window

| function | what it answers |
| --- | --- |
| `crt_init() → num` | make the escape sequences render: on Windows it turns on the console's VT processing; elsewhere ANSI already works and it does nothing. `1` when VT output is available, `0` when it could not be turned on — a redirected stdout, or a console too old for it. The other functions still return their sequences either way; they just will not render. It does **not** put the terminal in raw mode |
| `crt_done() → num` | put the terminal back: undo raw mode if a key function turned it on. Always `0` (a number, so the result can be stored); harmless when raw mode was never entered, and callable more than once |
| `crt_hideconsole() → num` | let go of the console window **this process owns**, and answer whether there was one to let go of: `1` if it released one, `0` if not. A console shared with a terminal is never touched — running from a shell answers `0` and changes nothing, because that console belongs to the person using it — and Unix always answers `0`, where the terminal is never the program's. Printing afterwards is safe: standard output that *was* a console is pointed at the null device, while output already redirected to a file or a pipe keeps its redirection |
| `crt_showconsole() → num` | make a **new** console and print to it again: `1` if it did, `0` unless this program had let one go with `crt_hideconsole()`. It does not bring the old window back — it cannot, and saying so is the difference between a verb that works and one that looks like it did. The program's output, the interpreter's own messages — a runtime error, for one — and `input` from the keyboard all use the new console (until 2026-10-05 none of them did) |

## A worked example

A panel drawn once and then updated in place — the shape most CRT programs take.
It runs in a real terminal, and also survives being piped somewhere, which is
what the tick cap is for.

```basic
rem A status panel: draw the frame once, then rewrite one field until
rem a key is pressed.   phosphor panel.bas

ok% = crt_init()                    rem 1 = the sequences below will render
print cls$(); hidecursor$();

print at$(2, 4); bold$(); color$(14); "PHOSPHOR PANEL"; reset$();
print at$(3, 4); faint$(); "press any key to stop"; reset$();
print at$(5, 4); underline$(); "ticks"; reset$();

n% = 0
k$ = ""
while (k$ = "") and (n% < 100)
  n% = n% + 1
  print at$(6, 4); clreol$(); color$(10); str$(n%); reset$();
  pause(0.2)
  k$ = inkey$()                     rem "" = nothing waiting -- or no keyboard
endwhile

print at$(8, 4); showcursor$();
crt_done()
println "stopped after " + str$(n%) + " ticks"
```

Two things worth noticing:

- **Every sequence went out through `print`.** Nothing in that loop reached the
  terminal by another route, which is why piping the program to a file gives you
  the escape bytes in order rather than a half-scrambled screen — and why the
  suite can assert what it drew without a screen in sight.
- **`inkey$` cannot tell "no key yet" from "no keyboard".** Both are `""`, so the
  loop carries `n% < 100` as its own way out; without it, a non-interactive run
  would poll forever. When a program genuinely wants to wait, `getkey$` is the
  other half — it blocks, and *its* `""` is unambiguous: there is nothing to wait
  for, stop.

## Notes

- `crt_hideconsole()` is the same rule the `phosphor` host offers as the
  `--no-console` startup flag (and bakes into a packed executable), sharing one
  implementation rather than growing a second one that drifts.
- The keyboard decision — where one key ends, given the bytes a terminal hands
  over — is lifted out of the terminal I/O so it can be tested with no console
  present: `CrtEventKey`, `CrtKeyFromEvent` and `CrtKeyFromPair` on Windows;
  for Unix, `CrtAssembleKey` (where a key ends), `CrtReaderKey` (when the rest
  of one is waited for, with the terminal and the clock as parameters) and
  `CrtEditLine` (how a typed-ahead line is edited and shown). The Unix three are
  compiled on every system, so `tests/probe_crt.lpr` runs them on both — with a
  scripted terminal and its own clock, so a 500 ms wait costs nothing. The I/O half
  — keys and lines typed into a real Windows console, and onto a Unix pty — is
  `tests/console_input_test.py`, run by block AH of `scripts/test.ps1` and
  `scripts/test.sh`.
- Runnable programs live in `examples/crt_demo.bas` (colours and attributes),
  `examples/crt_dashboard.bas` (a positioned layout) and `examples/crt_keys.bas`
  (the key loop). `tests/packages/05_crt.bas` pins every sequence byte for byte.
