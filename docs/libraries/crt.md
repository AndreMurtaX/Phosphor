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
person's terminal in raw mode). When stdin is **not** a terminal — a pipe, a
redirect, the headless test harness — there is no keyboard at all, so `inkey$()`
and `getkey$()` answer `""` and `keypressed()` answers `0` immediately, without
blocking and without touching the terminal. A normal key comes back as its
character, a whole UTF-8 character including accented ones; an arrow or function
key comes back as `chr$(0)` plus a code byte on Windows (a virtual-key code) and
as the raw escape sequence on Unix; Escape pressed on its own is `chr$(27)` with
nothing after it.

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
| `inkey$() → str` | the key that is waiting, or `""` when none is — it never blocks. `""` also means "there is no keyboard" (piped or redirected stdin), and the two cases are indistinguishable, so a polling loop needs an end condition of its own |
| `getkey$() → str` | block until a key is pressed and answer it. It answers `""` **only** when there is nothing to wait for — no terminal, or the input ended — so an empty result means *stop*, never *try again*; a loop that retries on `""` spins forever under a pipe |
| `keypressed() → num` | `1` when a key is waiting, `0` when none is. `0` with no keyboard, again without blocking |

### Setup, and the console window

| function | what it answers |
| --- | --- |
| `crt_init() → num` | make the escape sequences render: on Windows it turns on the console's VT processing; elsewhere ANSI already works and it does nothing. `1` when VT output is available, `0` when it could not be turned on — a redirected stdout, or a console too old for it. The other functions still return their sequences either way; they just will not render. It does **not** put the terminal in raw mode |
| `crt_done() → num` | put the terminal back: undo raw mode if a key function turned it on. Always `0` (a number, so the result can be stored); harmless when raw mode was never entered, and callable more than once |
| `crt_hideconsole() → num` | let go of the console window **this process owns**, and answer whether there was one to let go of: `1` if it released one, `0` if not. A console shared with a terminal is never touched — running from a shell answers `0` and changes nothing, because that console belongs to the person using it — and Unix always answers `0`, where the terminal is never the program's. Printing afterwards is safe: standard output that *was* a console is pointed at the null device, while output already redirected to a file or a pipe keeps its redirection |
| `crt_showconsole() → num` | make a **new** console and print to it again: `1` if it did, `0` unless this program had let one go with `crt_hideconsole()`. It does not bring the old window back — it cannot, and saying so is the difference between a verb that works and one that looks like it did |

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
  present: `CrtAssembleKey` on Unix, `CrtKeyFromEvent` on Windows, exercised by
  `tests/probe_crt.lpr`.
- Runnable programs live in `examples/crt_demo.bas` (colours and attributes),
  `examples/crt_dashboard.bas` (a positioned layout) and `examples/crt_keys.bas`
  (the key loop). `tests/packages/05_crt.bas` pins every sequence byte for byte.
