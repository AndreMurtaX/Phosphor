rem ---------------------------------------------------------------
rem CRT / console control (opt-in host package). The screen-control
rem functions RETURN their ANSI escape sequence (host-agnostic and
rem byte-exact); the program emits them with `print`. Here we assert
rem the exact sequences, and that key input is non-blocking when idle.
rem ---------------------------------------------------------------

e$ = chr$(27)

test_case("crt/screen and cursor")
assert_eq(cls$(), e$ + "[2J" + e$ + "[H", "cls clears the screen and homes the cursor")
assert_eq(home$(), e$ + "[H", "home")
assert_eq(at$(3, 10), e$ + "[3;10H", "position at row 3, col 10")
assert_eq(clreol$(), e$ + "[K", "clear to end of line")
assert_eq(moveup$(2), e$ + "[2A", "cursor up 2")
assert_eq(moveright$(5), e$ + "[5C", "cursor right 5")
assert_eq(movedown$(3), e$ + "[3B", "cursor down 3")
assert_eq(moveleft$(4), e$ + "[4D", "cursor left 4")
assert_eq(clreos$(), e$ + "[J", "clear to end of screen")
assert_eq(savepos$(), e$ + "7", "save cursor position")
assert_eq(restorepos$(), e$ + "8", "restore cursor position")

test_case("crt/attributes and colour")
assert_eq(reset$(), e$ + "[0m", "reset attributes")
assert_eq(bold$(), e$ + "[1m", "bold")
assert_eq(underline$(), e$ + "[4m", "underline")
assert_eq(inverse$(), e$ + "[7m", "inverse video")
assert_eq(color$(1), e$ + "[31m", "red foreground (index 1)")
assert_eq(color$(9), e$ + "[91m", "bright red foreground (index 9)")
assert_eq(color$(2, 4), e$ + "[32;44m", "green on blue")
assert_eq(bg$(3), e$ + "[43m", "yellow background")

test_case("crt/composition (what a program actually emits)")
line$ = at$(5, 20) + color$(9) + bold$() + "READY" + reset$()
assert_eq(line$, e$ + "[5;20H" + e$ + "[91m" + e$ + "[1mREADY" + e$ + "[0m", "position + bright bold + text + reset composes")

rem The non-blocking key functions must answer "no key" (and never block) when there
rem is nothing waiting -- which is always the case under the headless test harness.
test_case("crt/key input is non-blocking when idle")
assert_eq(inkey$(), "", "inkey$ is empty when no key is waiting")
assert_eq(keypressed(), 0, "keypressed() is 0 when no key is waiting")
