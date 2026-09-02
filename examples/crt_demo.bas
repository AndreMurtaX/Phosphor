rem ===============================================================
rem crt_demo.bas -- console screen control with the CRT package.
rem
rem Run it in a real terminal with the console host:
rem     phosphor examples/crt_demo.bas
rem
rem The screen-control functions RETURN their ANSI escape sequence,
rem so you emit them with `print` (which, unlike `println`, adds no
rem newline). crt_init() turns ANSI on for the Windows console; it is
rem a no-op elsewhere.
rem ===============================================================

ok% = crt_init()

print cls$(); hidecursor$();
print at$(1, 3); bold$(); color$(14); "Phosphor BASIC  -  CRT demo"; reset$();

rem --- the 16 colours: 0..7 normal, 8..15 bright ---
print at$(3, 3); underline$(); "foreground"; reset$();
for c% = 0 to 15
  print at$(4 + c%, 3); color$(c%); "###"; reset$(); " color("; str$(c%); ")";
next

rem --- text attributes ---
print at$(3, 26); underline$(); "attributes"; reset$();
print at$(5, 26); bold$();      "bold";      reset$();
print at$(6, 26); faint$();     "faint";     reset$();
print at$(7, 26); italic$();    "italic";    reset$();
print at$(8, 26); underline$(); "underline"; reset$();
print at$(9, 26); blink$();     "blink";     reset$();
print at$(10, 26); inverse$();  " inverse "; reset$();

rem --- background colours ---
print at$(13, 26); underline$(); "backgrounds"; reset$();
for c% = 0 to 7
  print at$(15, 26 + c% * 3); color$(15); bg$(c%); " "; str$(c%); " "; reset$();
next

print at$(20, 3); color$(10); "done."; reset$(); showcursor$();
println
