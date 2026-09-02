rem ===============================================================
rem crt_dashboard.bas -- a positioned, coloured layout drawn with the
rem CRT package: absolute cursor positioning (at$) plus colour build a
rem simple boxed "dashboard", the way a classic BASIC screen would.
rem
rem     phosphor examples/crt_dashboard.bas
rem ===============================================================

ok% = crt_init()
print cls$(); hidecursor$();

rem --- a box from Unicode box-drawing characters ---
top% = 2
left% = 4
width% = 40

print at$(top%, left%); color$(6); "+"; mulstring$("-", width% - 2); "+"; reset$();
for r% = 1 to 6
  print at$(top% + r%, left%); color$(6); "|"; reset$();
  print at$(top% + r%, left% + width% - 1); color$(6); "|"; reset$();
next
print at$(top% + 7, left%); color$(6); "+"; mulstring$("-", width% - 2); "+"; reset$();

rem --- title inside the box ---
print at$(top% + 1, left% + 2); bold$(); color$(14); "PHOSPHOR STATUS"; reset$();

rem --- labelled rows: label in dim, value in a status colour ---
print at$(top% + 3, left% + 2); faint$(); "engine   "; reset$(); color$(10); "running";  reset$();
print at$(top% + 4, left% + 2); faint$(); "requests "; reset$(); color$(11); "1284";     reset$();
print at$(top% + 5, left% + 2); faint$(); "errors   "; reset$(); color$(9);  "0";        reset$();
print at$(top% + 6, left% + 2); faint$(); "uptime   "; reset$(); color$(12); "3h 12m";   reset$();

print at$(top% + 9, left%); color$(8); "(a static layout -- position + colour, no cursor drift)"; reset$();
print at$(top% + 11, 1); showcursor$();
println
