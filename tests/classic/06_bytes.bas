rem Byte-level file work: the engine byte primitives, and byte-exactness of every
rem path that carries binary. Each line here pins a fix for a confirmed defect.
f$ = path_combine$(temppath$(), "phosphor_bytes_test.bin")

rem --- the byte primitives ---------------------------------------------------
b$ = bytestr$(0) + bytestr$(65) + bytestr$(128) + bytestr$(255)
println "bytelen      "; bytelen(b$)
println "byteat 1..4  "; byteat(b$, 1); " "; byteat(b$, 2); " "; byteat(b$, 3); " "; byteat(b$, 4)
println "bytemid 3,2  "; byteat(bytemid$(b$, 3, 2), 1); " "; byteat(bytemid$(b$, 3, 2), 2)
println "bytemid clamp "; bytelen(bytemid$(b$, 3, 999)); " "; bytelen(bytemid$(b$, 99, 2))

rem bytestr$ makes ONE byte where chr$ would UTF-8-encode it
println "bytestr vs chr "; bytelen(bytestr$(200)); " "; bytelen(chr$(200))
rem len counts characters, bytelen counts bytes
println "cafe len/bytelen "; len("caf" + chr$(233)); " "; bytelen("caf" + chr$(233))

rem --- a byte-exact whole-file round trip ------------------------------------
ok% = file_writealltext(f$, b$)
r$ = file_readalltext$(f$)
println "file size    "; file_getsize(f$)
println "roundtrip    "; bytelen(r$) = bytelen(b$)
same% = 1
for i = 1 to bytelen(b$)
  if byteat(r$, i) <> byteat(b$, i) then same% = 0
next
println "every byte   "; same%

rem --- the classic channels must not mangle bytes >= 128 ---------------------
rem (line input # and input # used to turn 0x80/0xFF into '?')
open f$ for input as #1
c$ = input$(4, #1)
close #1
println "input$ bytes "; byteat(c$, 3); " "; byteat(c$, 4)

ok% = file_writealltext(f$, bytestr$(65) + bytestr$(128) + bytestr$(255) + bytestr$(66))
open f$ for input as #2
line input #2, l$
close #2
println "line input # "; byteat(l$, 2); " "; byteat(l$, 3)

open f$ for input as #3
input #3, v$
close #3
println "input #      "; byteat(v$, 2); " "; byteat(v$, 3)

rem --- patch one byte in place, size unchanged -------------------------------
raw$ = file_readalltext$(f$)
p$ = bytemid$(raw$, 1, 1) + bytestr$(9) + bytemid$(raw$, 3, bytelen(raw$) - 2)
ok% = file_writealltext(f$, p$)
q$ = file_readalltext$(f$)
println "patched      "; byteat(q$, 2); " size "; bytelen(q$)

rem --- strings_free must refuse a handle that is not a string list -----------
a@ = dim@(2)
arr_set@(a@, 1, 7)
println "free refuses "; strings_free(a@); " array kept "; a@[1]

ok% = file_delete(f$)
println "cleaned      "; ok%
