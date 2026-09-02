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

rem --- 3. change ONE byte in the middle, byte-exact ---------------------------
rem Rebuild the blob as: everything before it, the new byte, everything after.
rem Nothing else moves and the file size never changes.
pos% = 6
was% = byteat(raw$, pos%)
new$ = bytemid$(raw$, 1, pos% - 1) + bytestr$(64) + bytemid$(raw$, pos% + 1, bytelen(raw$) - pos%)
ok% = file_writealltext(f$, new$)
chk$ = file_readalltext$(f$)
println "byte "; pos%; " was "; was%; ", now "; byteat(chk$, pos%)
println "size unchanged = "; bytelen(chk$) = bytelen(raw$)

rem --- 4. the classic # channel route: read a fixed number of bytes -----------
rem input$(k, #n) reads k BYTES (not characters), and lof(n) is the byte length.
open f$ for input as #1
magic$ = input$(2, #1)
left% = lof(1) - 2
close #1
println "magic = "; magic$; ", bytes left = "; left%

rem --- 5. the two traps, side by side ----------------------------------------
rem len() counts CHARACTERS and chr$ ENCODES one. On text that is what you want;
rem on bytes it quietly misleads, and nothing raises an error.
t$ = "café"
println "'café': bytelen = "; bytelen(t$); " but len = "; len(t$)
println "bytestr$(200) is "; bytelen(bytestr$(200)); " byte, chr$(200) is "; bytelen(chr$(200)); " bytes"

ok% = file_delete(f$)
