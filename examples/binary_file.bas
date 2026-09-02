rem binary_file.bas -- reading and writing a file BYTE BY BYTE.
rem
rem A Phosphor string carries all 256 byte values intact, so it doubles as a byte
rem buffer. But the ordinary string functions count UTF-8 CHARACTERS, which is
rem right for text and wrong for binary. For byte work use the byte family:
rem
rem   bytelen(s$)         how many BYTES the string holds
rem   byteat(s$, i)       the value 0..255 of byte i (1-based)
rem   bytestr$(v)         a ONE-BYTE string holding v   <-- not chr$(v)
rem   bytemid$(s$, i, n)  n bytes starting at byte i
rem
rem and read/write whole files with file_readalltext$ / file_writealltext, which
rem are raw byte primitives despite the "text" in their names: no BOM, no newline
rem translation, no transcoding.
rem
rem Run it with:  phosphor run examples/binary_file.bas

f$ = path_combine$(temppath$(), "phosphor_bytes.bin")

rem --- 1. build a binary file from computed byte values ----------------------
rem A 7-byte record: the magic "PB", a version byte, three data bytes, and a
rem checksum byte. Every non-ASCII byte comes from bytestr$ -- chr$ would
rem UTF-8-ENCODE the value and emit two bytes instead of one.
blob$ = "PB" + bytestr$(1) + bytestr$(0) + bytestr$(128) + bytestr$(255)
sum% = 0
for i = 1 to bytelen(blob$)
  sum% = (sum% + byteat(blob$, i)) mod 256
next
blob$ = blob$ + bytestr$(sum%)
ok% = file_writealltext(f$, blob$)
println "wrote "; bytelen(blob$); " bytes, checksum "; sum%

rem --- 2. read it back and walk every byte -----------------------------------
raw$ = file_readalltext$(f$)
print "bytes:"
for i = 1 to bytelen(raw$)
  print " "; byteat(raw$, i)
next
println ""
println "size on disk = "; file_getsize(f$)

rem --- 3. change ONE byte, rebuilding the whole blob --------------------------
rem Fine for a small file: everything before it, the new byte, everything after.
pos% = 6
was% = byteat(raw$, pos%)
new$ = bytemid$(raw$, 1, pos% - 1) + bytestr$(64) + bytemid$(raw$, pos% + 1, bytelen(raw$) - pos%)
ok% = file_writealltext(f$, new$)
chk$ = file_readalltext$(f$)
println "byte "; pos%; " was "; was%; ", now "; byteat(chk$, pos%)
println "size unchanged = "; bytelen(chk$) = bytelen(raw$)

rem --- 4. change ONE byte IN PLACE, without reading the file ------------------
rem OPEN ... FOR BINARY is read/write and positionable: SEEK moves the cursor,
rem PRINT # overwrites at it. This is the way to patch a large file -- nothing is
rem loaded and nothing else in the file is touched.
open f$ for binary as #1
seek #1, 4
print #1, bytestr$(7)
close #1
println "byte 4 in place = "; byteat(file_readalltext$(f$), 4)

rem --- 5. read at any position; loc() reports the cursor, 1-based -------------
open f$ for binary as #1
seek #1, 2
two$ = input$(2, #1)
println "bytes 2..3 = "; byteat(two$, 1); " "; byteat(two$, 2); ", loc now "; loc(1)
println "file length = "; lof(1)
close #1

rem --- 6. reading forward only: FOR INPUT streams, it does not load the file --
rem input$(k, #n) reads k BYTES (not characters); a file larger than memory is fine.
open f$ for input as #1
magic$ = input$(2, #1)
left% = lof(1) - 2
close #1
println "magic = "; magic$; ", bytes left = "; left%

rem --- 7. the two traps, side by side ----------------------------------------
rem len() counts CHARACTERS and chr$ ENCODES one. On text that is what you want;
rem on bytes it quietly misleads, and nothing raises an error.
t$ = "café"
println "'café': bytelen = "; bytelen(t$); " but len = "; len(t$)
println "bytestr$(200) is "; bytelen(bytestr$(200)); " byte, chr$(200) is "; bytelen(chr$(200)); " bytes"

ok% = file_delete(f$)
