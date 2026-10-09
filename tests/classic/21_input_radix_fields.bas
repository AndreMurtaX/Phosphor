rem ---------------------------------------------------------------
rem INPUT # and INPUT read a RADIX field -- $FF, 0x1F, &17, %101, with a
rem sign -- as sign and magnitude, and refuse one no int% can hold.
rem
rem Until 2026-10-09 (round 3) such a field went to FPC's TryStrToInt64,
rem which reads a magnitude up to 2^64-1, reinterprets it as a SIGNED
rem Int64 and only then applies the sign: "-$FFFFFFFFFFFFFFFF" read as 1,
rem "-$8000000000000001" as 9223372036854775807, "$FFFFFFFFFFFFFFFF" as -1
rem -- a minus sign giving a positive number, all silently -- while one
rem past 2^64 was "not a number" and one past 255 bytes (leading zeros)
rem was refused outright. The language's own radix text is sign and
rem magnitude (hex$(-255) is "-FF"), and the decimal door refuses an
rem integer it cannot hold rather than wrapping it.
rem
rem THE GRID: 11 magnitudes (0, 1, 255, 2^62, 2^63-1, 2^63, 2^63+1, 2^64-1,
rem 2^64, 2^64+1, 2^100) x 5 prefixes x 3 signs x 0, 1 or 260 leading
rem zeros, each read into an int% and into a number; then malformed
rem fields; then every power-of-two edge of int% written by hex$, oct$
rem and bin$ and read back; then val() and isnumeric(), which read no
rem radix at all; then the console door, fed by 21_input_radix_fields.in.
rem
rem THE EXPECTED LINES are the documented rule computed with Python's
rem unbounded integers: sign * magnitude, refused outside -2^63..2^63-1
rem (docs/language-reference.md#input-fields). Not from a run.
rem ---------------------------------------------------------------

function mag$(r, m)
  if r = 16 then
    if m = 1 then return "0"
    if m = 2 then return "1"
    if m = 3 then return "FF"
    if m = 4 then return "4000000000000000"
    if m = 5 then return "7FFFFFFFFFFFFFFF"
    if m = 6 then return "8000000000000000"
    if m = 7 then return "8000000000000001"
    if m = 8 then return "FFFFFFFFFFFFFFFF"
    if m = 9 then return "10000000000000000"
    if m = 10 then return "10000000000000001"
    if m = 11 then return "10000000000000000000000000"
  endif
  if r = 8 then
    if m = 1 then return "0"
    if m = 2 then return "1"
    if m = 3 then return "377"
    if m = 4 then return "400000000000000000000"
    if m = 5 then return "777777777777777777777"
    if m = 6 then return "1000000000000000000000"
    if m = 7 then return "1000000000000000000001"
    if m = 8 then return "1777777777777777777777"
    if m = 9 then return "2000000000000000000000"
    if m = 10 then return "2000000000000000000001"
    if m = 11 then return "2000000000000000000000000000000000"
  endif
  if r = 2 then
    if m = 1 then return "0"
    if m = 2 then return "1"
    if m = 3 then return "11111111"
    if m = 4 then return "100000000000000000000000000000000000000000000000000000000000000"
    if m = 5 then return "111111111111111111111111111111111111111111111111111111111111111"
    if m = 6 then return "1000000000000000000000000000000000000000000000000000000000000000"
    if m = 7 then return "1000000000000000000000000000000000000000000000000000000000000001"
    if m = 8 then return "1111111111111111111111111111111111111111111111111111111111111111"
    if m = 9 then return "10000000000000000000000000000000000000000000000000000000000000000"
    if m = 10 then return "10000000000000000000000000000000000000000000000000000000000000001"
    if m = 11 then return "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  endif
  return "?"
endfunction

function pre$(p)
  if p = 1 then return "$"
  if p = 2 then return "0x"
  if p = 3 then return "0X"
  if p = 4 then return "&"
  if p = 5 then return "%"
  return "?"
endfunction

function base(p)
  if p <= 3 then return 16
  if p = 4 then return 8
  return 2
endfunction

function sgn$(s)
  if s = 2 then return "+"
  if s = 3 then return "-"
  return ""
endfunction

function pad(z)
  if z = 2 then return 1
  if z = 3 then return 260
  return 0
endfunction

function magname$(m)
  if m = 1 then return "0"
  if m = 2 then return "1"
  if m = 3 then return "255"
  if m = 4 then return "2^62"
  if m = 5 then return "2^63-1"
  if m = 6 then return "2^63"
  if m = 7 then return "2^63+1"
  if m = 8 then return "2^64-1"
  if m = 9 then return "2^64"
  if m = 10 then return "2^64+1"
  if m = 11 then return "2^100"
  return "?"
endfunction

function text$(s, p, m, z) local d$
  d$ = mag$(base(p), m)
  if p = 2 then d$ = lcase$(d$)
  return sgn$(s) + pre$(p) + mulstring$("0", pad(z)) + d$
endfunction

f$ = path_combine$(temppath$(), "phosphor_radix_fields.txt")
open f$ for output as #1
for s = 1 to 3
  for p = 1 to 5
    for m = 1 to 11
      for z = 1 to 3
        t$ = text$(s, p, m, z)
        println #1, t$
        println #1, t$
      next
    next
  next
next
close #1

rem Each line is read twice: into an int%, then into a number. A refused
rem field is consumed all the same, so the next read starts on the next line.
open f$ for input as #2
on error goto bad
for s = 1 to 3
  for p = 1 to 5
    for m = 1 to 11
      for z = 1 to 3
        lbl$ = sgn$(s) + pre$(p) + " " + magname$(m) + " zeros=" + str$(pad(z))
        e$ = ""
        x% = 0
        input #2, x%
        if e$ = "" then
          println lbl$; " int% "; x%
        else
          println lbl$; " int% "; e$
        endif
        e$ = ""
        y = 0
        input #2, y
        if e$ = "" then
          println lbl$; " num "; y
        else
          println lbl$; " num "; e$
        endif
      next
    next
  next
next
on error goto 0
close #2

rem --- malformed and odd fields (one per line) ----------------------------
open f$ for output as #1
println #1, "$"
println #1, "0x"
println #1, "&"
println #1, "%"
println #1, "-$"
println #1, "+0x"
println #1, "$g"
println #1, "&8"
println #1, "%2"
println #1, "$-1"
println #1, "--$1"
println #1, "+-$1"
println #1, "0x+1"
println #1, "00x10"
println #1, "x10"
println #1, "$1.5"
println #1, "&h1F"
println #1, "0b101"
println #1, "$FF$"
println #1, "$1e3"
println #1, "-%1e3"
println #1, "&777"
println #1, "-0X7fffffffffffffff"
println #1, "%-1"
close #1
open f$ for input as #2
on error goto bad
for k = 1 to 24
  e$ = ""
  x% = 0
  input #2, x%
  if e$ = "" then
    println "field "; k; " int% "; x%
  else
    println "field "; k; " int% "; e$
  endif
next
on error goto 0
close #2

rem --- the language's own radix text reads back: hex$, oct$, bin$ --------
rem Every power of two 2^k for k = 0..62 and its neighbours (2^k - 1, -2^k,
rem -2^k + 1, 2^k + 1), plus the int% extremes, each written as $, 0x, &
rem and % text (a negative one as "-$" + its digits) and read back exactly.
function rtext$(v%, q) local h$, neg
  neg = 0
  if q <= 2 then h$ = hex$(v%)
  if q = 3 then h$ = oct$(v%)
  if q = 4 then h$ = bin$(v%)
  if left$(h$, 1) = "-" then
    neg = 1
    h$ = mid$(h$, 2)
  endif
  if q = 1 then h$ = "$" + h$
  if q = 2 then h$ = "0x" + h$
  if q = 3 then h$ = "&" + h$
  if q = 4 then h$ = "%" + h$
  if neg = 1 then h$ = "-" + h$
  return h$
endfunction

function edge%(k, j) local p%, i
  if k = 63 then
    if j = 1 then return 9223372036854775807
    return -9223372036854775807 - 1
  endif
  p% = 1
  for i = 1 to k
    p% = p% * 2
  next
  if j = 1 then return p%
  if j = 2 then return p% - 1
  if j = 3 then return 0 - p%
  if j = 4 then return 1 - p%
  return p% + 1
endfunction

function lastj(k)
  if k = 63 then return 2
  return 5
endfunction

open f$ for output as #1
for k = 0 to 63
  for j = 1 to lastj(k)
    for q = 1 to 4
      println #1, rtext$(edge%(k, j), q)
    next
  next
next
close #1
checked = 0
wrong = 0
open f$ for input as #2
on error goto bad
for k = 0 to 63
  for j = 1 to lastj(k)
    for q = 1 to 4
      e$ = ""
      x% = 0
      input #2, x%
      checked = checked + 1
      if e$ <> "" or x% <> edge%(k, j) then
        wrong = wrong + 1
        println "MISMATCH "; rtext$(edge%(k, j), q); " read "; x%; " "; e$
      endif
    next
  next
next
on error goto 0
close #2
println "round trip: "; checked; " fields, "; wrong; " wrong"

rem --- val() and isnumeric() read decimal text only (language-reference.md) --
println "val $FF = "; val("$FF"); " valcode "; valcode(); " isnumeric "; isnumeric("$FF")
println "val -$FF = "; val("-$FF"); " valcode "; valcode(); " isnumeric "; isnumeric("-$FF")
println "val 0x1F = "; val("0x1F"); " valcode "; valcode(); " isnumeric "; isnumeric("0x1F")
println "val &17 = "; val("&17"); " valcode "; valcode(); " isnumeric "; isnumeric("&17")
println "val %101 = "; val("%101"); " valcode "; valcode(); " isnumeric "; isnumeric("%101")
println "val 0X0 = "; val("0X0"); " valcode "; valcode(); " isnumeric "; isnumeric("0X0")

rem --- the console door: the same reader, fields from the .in file --------
on error goto bad
for k = 1 to 5
  e$ = ""
  x% = 0
  input x%
  if e$ = "" then
    println "console "; k; " int% "; x%
  else
    println "console "; k; " int% "; e$
  endif
next
on error goto 0

println "deleted: "; file_delete(f$)
end

bad:
  e$ = errmsg$()
  resume next
