rem ---------------------------------------------------------------
rem A HAND-EDITED .INI: A SECTION WRITTEN TWICE IS ONE SECTION, AND A
rem LINE NO READER CAN REACH IS TEXT, NOT A KEY (2026-10-09, round 3 of
rem the adversarial loop).
rem
rem docs/libraries/config.md: lines "the reader cannot place as
rem key=value" are kept as text and "None of them counts as a key:
rem cfg_keycount and cfg_keys$ see only the real ones"; and
rem cfg_section_delete@ answers "the handle, with that whole section and
rem its keys gone". TMemIniFile keeps ONE section object per header LINE
rem and every lookup takes the first, so for a file that wrote [a] twice:
rem   * a key in the second [a] was unreadable (cfg_get$ answered the
rem     default), while cfg_sectioncount counted 3 and cfg_sections$
rem     listed "a" twice;
rem   * a key written twice in one section was counted twice, and
rem     cfg_delete@ removed the first -- after which the key still
rem     existed and read the second value;
rem   * cfg_section_delete@ removed the first copy only: the section still
rem     existed and the save still wrote "[a]" and "z=3".
rem And the RTL turns "=value" into a key whose name is EMPTY -- counted
rem by cfg_keycount, listed by cfg_keys$ as an empty line, reachable by
rem no read, since the library refuses an empty key as unreadable. The
rem same is true of a header "[]" (a section named "", which the page says
rem is no section at all) and "[;x]", whose name begins with the comment
rem marker: it was listed nowhere, its keys were unreachable, and a save
rem wrote the header back as ";x" -- a comment -- so the next load put its
rem keys in whichever section came before.
rem
rem The expected answers come from the page's rules, not from a run: a
rem section is its name, matched without regard to case as every name
rem is; a key's FIRST line is the key (the RTL's own reading, and Windows'
rem GetPrivateProfileString's); a save writes one blank line between
rem sections, key=value without blanks, and foreign lines verbatim. The
rem file text is compared with CR removed, because a save writes the
rem platform's line endings.
rem ---------------------------------------------------------------

nl$ = chr$(10)
function text$(p$)
  return replacestr$(file_readalltext$(p$), chr$(13), "")
endfunction

test_case("config-r3/a section written twice is one section")
p$ = "bin/p9b_cfg_r3_dup.ini"
x = file_writealltext(p$, "[a]" + nl$ + "x=1" + nl$ + "k=1" + nl$ + "k=2" + nl$ + "[b]" + nl$ + "y=2" + nl$ + "[a]" + nl$ + "z=3" + nl$)
c@ = cfg_open@(p$)
assert_eq(cfg_get$(c@, "a", "z", "<absent>"), "3", "a key in the second [a] is a key of a")
assert_eq(cfg_sectioncount(c@), 2, "two sections, a and b")
assert_eq(cfg_sections$(c@), "a" + nl$ + "b", "each listed once, in file order")
assert_eq(cfg_keycount(c@, "a"), 3, "x, k and z: k once")
assert_eq(cfg_keys$(c@, "a"), "x" + nl$ + "k" + nl$ + "z", "each key name once")
assert_eq(cfg_get$(c@, "a", "k", "<absent>"), "1", "a key written twice reads its first line")
c@ = cfg_delete@(c@, "a", "k")
assert_eq(cfg_exists(c@, "a", "k"), 0, "deleting a key deletes every line of it")
assert_eq(cfg_get$(c@, "a", "k", "<absent>"), "<absent>", "so it no longer reads 2")
x = cfg_save(c@)
c@ = cfg_reload@(c@)
assert_eq(cfg_exists(c@, "a", "k"), 0, "and it does not come back from the file")
assert_eq(cfg_get$(c@, "a", "z", "<absent>"), "3", "z survives the save")
assert_eq(cfg_get$(c@, "a", "x", "<absent>"), "1", "and so does x")
c@ = cfg_set@(c@, "a", "z", "9")
x = cfg_save(c@)
c@ = cfg_reload@(c@)
assert_eq(cfg_get$(c@, "a", "z", "<absent>"), "9", "a set of a key from the second copy reads back")
assert_eq(cfg_keycount(c@, "a"), 2, "x and z, and z once")
c@ = cfg_section_delete@(c@, "a")
assert_eq(cfg_section_exists(c@, "a"), 0, "deleting the section deletes every copy of it")
assert_eq(cfg_sectioncount(c@), 1, "b is left")
x = cfg_save(c@)
assert_eq(text$(p$), "[b]" + nl$ + "y=2" + nl$, "and the file holds b alone")
c@ = cfg_reload@(c@)
assert_eq(cfg_section_exists(c@, "a"), 0, "a does not come back from the file")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r3/section names match without regard to case, as key names do")
p$ = "bin/p9b_cfg_r3_case.ini"
x = file_writealltext(p$, "[Sec]" + nl$ + "p=1" + nl$ + "[SEC]" + nl$ + "q=2" + nl$ + "P=3" + nl$)
c@ = cfg_open@(p$)
assert_eq(cfg_sections$(c@), "Sec", "[SEC] is the section [Sec], named as first written")
assert_eq(cfg_get$(c@, "sec", "q", "<absent>"), "2", "q, from the second header, reads")
assert_eq(cfg_keys$(c@, "Sec"), "p" + nl$ + "q", "P is the key p written again")
assert_eq(cfg_get$(c@, "Sec", "P", "<absent>"), "1", "and reads p's first line")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r3/a line with an empty key is text, not a key")
p$ = "bin/p9b_cfg_r3_empty.ini"
x = file_writealltext(p$, "[s]" + nl$ + "k = v" + nl$ + "=emptykey" + nl$ + "  = blanks" + nl$ + "# c" + nl$ + "free text" + nl$)
c@ = cfg_open@(p$)
assert_eq(cfg_keycount(c@, "s"), 1, "only k is a key")
assert_eq(cfg_keys$(c@, "s"), "k", "and only k is listed")
assert_eq(cfg_get$(c@, "s", "k", "<absent>"), "v", "k reads")
x = cfg_save(c@)
assert_eq(text$(p$), "[s]" + nl$ + "k=v" + nl$ + "=emptykey" + nl$ + "  = blanks" + nl$ + "# c" + nl$ + "free text" + nl$, "the empty-key lines are kept verbatim")
c@ = cfg_reload@(c@)
assert_eq(cfg_keycount(c@, "s"), 1, "and are still no keys after a reload")
x = cfg_free(c@)
file_delete(p$)

test_case("config-r3/a header no read can reach is text, and its block with it")
p$ = "bin/p9b_cfg_r3_hdr.ini"
x = file_writealltext(p$, "[a]" + nl$ + "x=1" + nl$ + "[]" + nl$ + "q=1" + nl$ + "[;x]" + nl$ + "r=2" + nl$ + "[b]" + nl$ + "y=2" + nl$)
c@ = cfg_open@(p$)
assert_eq(cfg_sectioncount(c@), 2, "[] and [;x] are no sections")
assert_eq(cfg_sections$(c@), "a" + nl$ + "b", "and are not listed as empty or comment names")
assert_eq(cfg_keys$(c@, "a"), "x", "their lines do not become keys of a")
assert_eq(cfg_get$(c@, "b", "y", "<absent>"), "2", "b still reads")
x = cfg_save(c@)
rem Each unreachable header's block is a block of its own (round 4,
rem tests/suite/94_config_sys_round4.bas), so a save writes one blank line
rem between it and its neighbours, as between sections. Until round 4 this
rem line expected none: the blocks were glued to [a], which is what lost a
rem key later set into [a].
assert_eq(text$(p$), "[a]" + nl$ + "x=1" + nl$ + nl$ + "[]" + nl$ + "q=1" + nl$ + nl$ + "[;x]" + nl$ + "r=2" + nl$ + nl$ + "[b]" + nl$ + "y=2" + nl$, "the save writes them back as they were, [;x] with its brackets")
c@ = cfg_reload@(c@)
assert_eq(cfg_sectioncount(c@), 2, "and a reload reads the same")
assert_eq(cfg_keys$(c@, "a"), "x", "with the same keys")
x = cfg_free(c@)
file_delete(p$)
