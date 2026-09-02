rem file_report.bas -- classic file I/O and PRINT USING together.
rem
rem Writes a small sales table to a file with classic # I/O, reads it back with
rem INPUT #, and prints a formatted report with PRINT USING. Run it with:
rem
rem   phosphor run examples/file_report.bas
rem
rem It writes (and cleans up) one file in the OS temp directory.

data$ = path_combine$(temppath$(), "phosphor_sales.csv")

rem --- write the data file: one "name,units,price" record per line ----------
open data$ for output as #1
println #1, "Widget,120,3.50"
println #1, "Gadget,75,9.99"
println #1, "Gizmo,240,1.25"
close #1

rem --- read it back and print a formatted report ----------------------------
println "  Product      Units      Total"
println "  ------------------------------"
grand = 0
open data$ for input as #1
while not eof(1)
  input #1, name$, units%, price
  total = units% * price
  grand = grand + total
  rem a '\ ... \' field is a fixed-width string; in a Phosphor literal each of its
  rem backslashes is written '\\' (string literals use backslash escapes).
  println using "  \\          \\  #,### $$#,###.##"; name$; units%; total
wend
close #1
println "  ------------------------------"
println using "  Grand total       $$#,###.##"; grand

rem --- tidy up --------------------------------------------------------------
ok% = file_delete(data$)
