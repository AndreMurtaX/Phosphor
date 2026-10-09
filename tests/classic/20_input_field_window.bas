rem ---------------------------------------------------------------
rem INPUT # reads the same fields wherever the channel's read window ends.
rem
rem A channel is read a window at a time (64 KB, growing geometrically for a
rem long run). ChanField's pre-scan made sure the window held the whole FIELD,
rem and stopped at its terminator -- but reading a field also consumes the blanks
rem after it and ONE separator comma, and when the field ended at the last bytes
rem of the window that comma was not in it yet. So "a ,b" with the blank as the
rem window's last byte read as THREE fields, "a", "" and "b": a phantom empty
rem field, and every later field one place out. The same for a closing quote
rem or a CRLF just before the edge. (Found 2026-10-09, fixed in ChanField.)
rem
rem THE GRID. Twelve shapes -- a comma alone, blanks before it, a quoted field
rem and its "" escape, CRLF before a comma or a field, two commas (a genuine
rem empty field, which must survive the fix) -- each placed so that its marked
rem byte lands at every offset from 4 before to 4 after a window edge: 64 KB,
rem 2 x 64 KB and 3 x 64 KB behind short fields, and 4 x 64 KB behind one
rem 140000-byte field, which makes the window grow past 64 KB first.
rem
rem THE EXPECTED LINES were derived by a Python model of the documented field
rem rules (docs/language-reference.md#input-fields), applied to the same bytes this
rem program writes -- not from a run. Each line counts the fields, the filler
rem fields among them, and lists the rest between bars.
rem ---------------------------------------------------------------

f$ = path_combine$(temppath$(), "phosphor_field_window.txt")
u7$ = mulstring$("7", 63)
unit$ = u7$ + ","
u8$ = mulstring$("8", 139999)

function shape$(k)
  if k = 1 then return "a,b"
  if k = 2 then return "a ,b"
  if k = 3 then return "a \t ,b"
  if k = 4 then return "\"q\",b"
  if k = 5 then return "\"q\" ,b"
  if k = 6 then return "\"q\"\"r\",b"
  if k = 7 then return "a\r\n,b"
  if k = 8 then return "a\r\nb"
  if k = 9 then return "a,,b"
  if k = 10 then return "a , ,b"
  if k = 11 then return "\"q\"\r\n\"r\""
  return "a b"
endfunction

rem the 1-based position, inside its shape, of the byte placed on the edge
function mark(k)
  if k = 1 then return 2
  if k = 2 then return 3
  if k = 3 then return 5
  if k = 4 then return 4
  if k = 5 then return 5
  if k = 6 then return 7
  if k = 7 then return 4
  if k = 8 then return 3
  if k = 9 then return 3
  if k = 10 then return 5
  if k = 11 then return 5
  return 3
endfunction

rem L bytes of short filler fields: blanks for the odd part, then 64-byte fields
function filler$(L)
  return space$(L mod 64) + mulstring$(unit$, L \ 64)
endfunction

for fam = 1 to 4
  w = 65536 * fam
  for d = -4 to 4
    for k = 1 to 12
      s$ = shape$(k)
      at = w + d - (mark(k) - 1)
      if fam = 4 then
        body$ = u8$ + "," + filler$(at - 140000) + s$ + "\r\n"
      else
        body$ = filler$(at) + s$ + "\r\n"
      endif
      open f$ for output as #1
      print #1, body$
      close #1
      n = 0
      nf = 0
      tail$ = ""
      open f$ for input as #2
      while not eof(2)
        input #2, a$
        n = n + 1
        if a$ = u7$ or a$ = u8$ then
          nf = nf + 1
        else
          tail$ = tail$ + "|" + a$
        endif
      wend
      close #2
      println w; "/"; d; " s"; k; ": "; n; " fields, "; nf; " filler, tail "; tail$; "|"
    next
  next
next

println "deleted: "; file_delete(f$)
