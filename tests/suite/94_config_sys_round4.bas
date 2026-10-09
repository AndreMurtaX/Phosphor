rem ---------------------------------------------------------------
rem A HAND-EDITED .INI KEEPS ITS TEXT, AND A COLOUR LITERAL IS SIGN AND
rem MAGNITUDE (2026-10-09, round 4 of the adversarial loop).
rem
rem docs/libraries/config.md: "whatever a setter accepts reads back
rem identically after a save and a reload", "A hand edit's text survives
rem a save", and a header no read can reach ("[]", "[;x]") "is kept as
rem text with its whole block". Round 3 kept that block -- but at the end
rem of the block that was open, the section ABOVE it, where the RTL held
rem its lines as that section's comment lines. So:
rem   * a set into that section appended its key after them; the save
rem     wrote "new=v" under "[;x]", and after the reload the key was gone;
rem   * cfg_section_delete@ of that section deleted the hand-written block.
rem And the RTL keeps Trim(line) of every line, which cuts each byte at or
rem below a space at both ends: the layer's marker protected the front of
rem a line it kept as text and nothing protected the end, so " #" chr 1
rem was saved as " #", a kept line lost its trailing tab, a line made only
rem of a NUL vanished, and a padded ";" comment lost its blanks.
rem
rem docs/libraries/sys.md: color() parses "the string as a literal", and
rem a literal outside 0..4294967295 answers 0. It went to FPC's
rem TryStrToInt64, which reinterprets a radix magnitude as signed BEFORE
rem negating it (-$FFFFFFFFFFFFFFFF read as 1, -$FFFFFFFF00000001 as
rem white) and reads through a 255-byte ShortString (300 zeros and "FF",
rem the literal 255, was refused). docs/decisions.md made radix text sign
rem and magnitude at the input # door in round 3; this is that rule.
rem
rem The expected answers come from the pages' rules, not from a run: a
rem save writes one blank line between sections (none after the comment
rem block that opens a file), key=value without blanks, and every line it
rem keeps as text byte for byte; a blank line -- spaces and tabs only --
rem is layout and is not kept. Colour values are the arithmetic written
rem beside each assertion. File text is compared with CR removed, because
rem a save writes the platform's line endings.
rem
rem temppath$ and tempfilename$ with TEMP and TMP unset, and environ$ of
rem bytes that are not UTF-8 on Linux, need an environment this program
rem cannot set (and the runner sandboxes it, so temppath$ is the scratch
rem directory here): blocks AB and AC of scripts/test.ps1 and test.sh.
rem ---------------------------------------------------------------

nl$ = chr$(10)
function text$(p$)
  return replacestr$(file_readalltext$(p$), chr$(13), "")
endfunction

test_case("config-r4/a set into the section above an unreachable header reads back")
p$ = "bin/p9b_cfg_r4_set.ini"
x = file_writealltext(p$, "[a]" + nl$ + "k=1" + nl$ + "[;x]" + nl$ + "y=2" + nl$)
c@ = cfg_open@(p$)
c@ = cfg_set@(c@, "a", "new", "v")
x = cfg_save(c@)
c@ = cfg_reload@(c@)
assert_eq(cfg_get$(c@, "a", "new", "MISSING"), "v", "the key set before the save reads after the reload")
assert_eq(cfg_keycount(c@, "a"), 2, "k and new")
assert_eq(cfg_sections$(c@), "a", "and [;x] is still no section")
assert_eq(text$(p$), "[a]" + nl$ + "k=1" + nl$ + "new=v" + nl$ + nl$ + "[;x]" + nl$ + "y=2" + nl$, "new=v is written in a, and the hand-written block after it")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r4/deleting the section above an unreachable header keeps the header's block")
p$ = "bin/p9b_cfg_r4_del.ini"
x = file_writealltext(p$, "[a]" + nl$ + "k=1" + nl$ + "[]" + nl$ + "note=kept by hand" + nl$ + "[b]" + nl$ + "j=2" + nl$)
c@ = cfg_open@(p$)
c@ = cfg_section_delete@(c@, "a")
assert_eq(cfg_sections$(c@), "b", "a is gone and [] was never a section")
x = cfg_save(c@)
assert_eq(text$(p$), "[]" + nl$ + "note=kept by hand" + nl$ + nl$ + "[b]" + nl$ + "j=2" + nl$, "the [] block is still in the file")
c@ = cfg_reload@(c@)
assert_eq(cfg_get$(c@, "b", "j", "MISSING"), "2", "and b reads")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r4/deleting a twice-written key does not glue the block back")
rem cfg_delete@ of a key written twice hands the RTL its own text back
rem (to drop the later lines); the unreachable block must survive that.
p$ = "bin/p9b_cfg_r4_dup.ini"
x = file_writealltext(p$, "[a]" + nl$ + "k=1" + nl$ + "k=2" + nl$ + "[;x]" + nl$ + "y=2" + nl$ + "[b]" + nl$ + "j=3" + nl$)
c@ = cfg_open@(p$)
c@ = cfg_delete@(c@, "a", "k")
c@ = cfg_set@(c@, "a", "new", "v")
x = cfg_save(c@)
c@ = cfg_reload@(c@)
assert_eq(cfg_get$(c@, "a", "new", "MISSING"), "v", "the key set after the delete reads after the reload")
assert_eq(cfg_exists(c@, "a", "k"), 0, "k, both lines of it, is gone")
assert_eq(cfg_sections$(c@), "a" + nl$ + "b", "two sections")
assert_eq(text$(p$), "[a]" + nl$ + "new=v" + nl$ + nl$ + "[;x]" + nl$ + "y=2" + nl$ + nl$ + "[b]" + nl$ + "j=3" + nl$, "the block is its own, between a and b")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r4/an unreachable header after the opening comments")
p$ = "bin/p9b_cfg_r4_top.ini"
x = file_writealltext(p$, "; top" + nl$ + "[]" + nl$ + "q=1" + nl$ + "[a]" + nl$ + "k=1" + nl$)
c@ = cfg_open@(p$)
c@ = cfg_set@(c@, "a", "z", "2")
x = cfg_save(c@)
c@ = cfg_reload@(c@)
assert_eq(cfg_get$(c@, "a", "z", "MISSING"), "2", "a set reads back")
assert_eq(cfg_keys$(c@, "a"), "k" + nl$ + "z", "and q is no key of a")
assert_eq(text$(p$), "; top" + nl$ + "[]" + nl$ + "q=1" + nl$ + nl$ + "[a]" + nl$ + "k=1" + nl$ + "z=2" + nl$, "no blank after the opening comment, one between the blocks")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r4/a line kept as text keeps every byte")
p$ = "bin/p9b_cfg_r4_bytes.ini"
nul$ = bytestr$(0)
tab$ = bytestr$(9)
top1$ = " # top" + bytestr$(1)
top2$ = nul$
top3$ = "  ; padded top " + tab$
l1$ = " #" + bytestr$(1)
l2$ = "k = " + nul$ + "xv" + tab$
l3$ = nul$
l4$ = "  ; padded comment  "
l5$ = "free text " + bytestr$(3)
l6$ = bytestr$(11) + bytestr$(12)
l7$ = ";" + bytestr$(3) + "k=2" + tab$ + nul$
blank$ = "   " + tab$
body$ = "[a]" + nl$ + l1$ + nl$ + "k=1" + nl$ + l2$ + nl$ + l3$ + nl$ + blank$ + nl$ + l4$ + nl$ + l5$ + nl$ + l6$ + nl$ + l7$ + nl$
x = file_writealltext(p$, top1$ + nl$ + top2$ + nl$ + top3$ + nl$ + body$)
c@ = cfg_open@(p$)
assert_eq(cfg_keys$(c@, "a"), "k", "k is the one key")
assert_eq(cfg_get$(c@, "a", "k", "MISSING"), "1", "and reads its first line")
x = cfg_save(c@)
want$ = top1$ + nl$ + top2$ + nl$ + top3$ + nl$ + "[a]" + nl$ + l1$ + nl$ + "k=1" + nl$ + l2$ + nl$ + l3$ + nl$ + l4$ + nl$ + l5$ + nl$ + l6$ + nl$ + l7$ + nl$
assert_eq(text$(p$), want$, "every kept line byte for byte; only the blank line goes")
c@ = cfg_reload@(c@)
x = cfg_save(c@)
assert_eq(text$(p$), want$, "and a second save writes the same bytes")
assert_eq(cfg_keycount(c@, "a"), 1, "still one key after the reload")
x = cfg_free(c@)
file_delete(p$)

test_case("color-r4/a literal is sign and magnitude, at any length")
rem -$FFFFFFFFFFFFFFFF is -(2^64 - 1) and -$FFFFFFFF00000001 is
rem -(2^64 - 2^32 + 1): both below 0, so no colour.
assert_eq(color("-$FFFFFFFFFFFFFFFF"), 0, "minus 2^64-1 is no colour, not 1")
assert_eq(color("-$FFFFFFFF00000001"), 0, "minus 2^64-2^32+1 is no colour, not white")
assert_eq(alphacolor("-$FFFFFFFF00000001"), 4278190080, "unknown, so opaque black: 0 + 255*2^24")
assert_eq(color("-%1"), 0, "a negative binary literal")
assert_eq(color("-0"), 0, "minus zero is zero")
rem "$", 300 zeros and "FF" is 255; 300 zeros and "255" is 255.
assert_eq(color("$" + string$(300, 48) + "FF"), 255, "leading zeros past 255 bytes")
assert_eq(color(string$(300, 48) + "255"), 255, "and in decimal")
assert_eq(color("$" + string$(300, 48) + "100000000"), 0, "2^32 is still no colour, however written")
rem $FF = &377 = %11111111 = 0xFF = 255
assert_eq(color("&377"), 255, "octal")
assert_eq(color("%11111111"), 255, "binary")
assert_eq(color("0xFF"), 255, "0x")
assert_eq(color("+$FF"), 255, "a plus sign")
assert_eq(color("255" + bytestr$(0) + "x"), 0, "a NUL is no digit: the text is no literal")
assert_eq(color("$FFFFFFFF"), 4294967295, "the largest colour still reads")
