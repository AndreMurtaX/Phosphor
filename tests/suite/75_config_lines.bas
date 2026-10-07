rem ---------------------------------------------------------------
rem AN .INI KEEPS WHAT A PERSON WROTE IN IT, AND REFUSES WHAT IT CANNOT
rem READ BACK (ledger d12).
rem
rem The config library sat on TMemIniFile, whose one comment marker is
rem ";" and whose rule for anything else is "a line I cannot parse": a
rem "# inner" comment inside a section was saved back as "=# inner" and
rem counted as a key with an empty name; a "# top" before the first
rem section was dropped. docs/libraries/config.md invites hand edits,
rem so this is the file a user actually has. Measured on the unfixed
rem build: keycount 2, a blank entry in cfg_keys$, "# top" gone.
rem
rem And the library's own setters could write lines it could not read
rem back: a value holding a line break came back cut at it, a key
rem beginning ";" lost its value, a section beginning ";" became a
rem comment, a key holding "=" read back as a shorter key, an empty key
rem was never written, and blanks at either end of a key or value were
rem trimmed away. Each of those is now REFUSED, as a catchable error --
rem the attack plan's decision 6: errors are values, and an escape would
rem invent a convention nobody editing the file by hand could see.
rem
rem Every expected value below is derived from that rule, or from the
rem file text written out by hand above it -- none was read off a run.
rem Line breaks in a saved file are the platform's, so the order checks
rem accept either.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""
on error goto trapped

lf$ = chr$(10)
crlf$ = chr$(13) + chr$(10)
p$ = "bin/p9b_cfg_lines.ini"

test_case("config-lines/a hand-edited file keeps its comments")
file_writealltext(p$, "# top" + lf$ + "orphan=1" + lf$ + "[s]" + lf$ + "# inner" + lf$ + "k=1" + lf$)
c@ = cfg_open@(p$)
assert_eq(cfg_keycount(c@, "s"), 1, "the comment is not a key")
assert_eq(cfg_keys$(c@, "s"), "k", "and cfg_keys$ has no blank entry for it")
assert_eq(cfg_get$(c@, "s", "k", "?"), "1", "the real key reads as written")
c@ = cfg_set@(c@, "s", "k2", "2")
assert_eq(cfg_save(c@), 1, "it saves")
t$ = file_readalltext$(p$)
assert_true(instr(t$, "# top") > 0, "the comment before the first section survives")
assert_true(instr(t$, "orphan=1") > 0, "and so does a line there the reader cannot place")
assert_true(instr(t$, "# inner") > 0, "the comment inside the section survives")
assert_eq(instr(t$, "=# inner"), 0, "and is not turned into a key with no name")
assert_true(instr(t$, "# top") < instr(t$, "[s]"), "the top comment is still above the section")
assert_true(instr(t$, "[s]") < instr(t$, "# inner"), "the inner one is still inside it")
assert_true(instr(t$, "# inner") < instr(t$, "k=1"), "and above the key it sat above")
assert_true(instr(t$, "k=1") < instr(t$, "k2=2"), "a new key goes at the end of its section")
rem The leading block is followed by the section at once, with no blank line
rem between: that is how every .ini this library ever saved was written.
assert_true(instr(t$, "orphan=1" + lf$ + "[s]") + instr(t$, "orphan=1" + crlf$ + "[s]") > 0, "no blank line is invented after the leading block")

test_case("config-lines/and it reloads as the same file")
c@ = cfg_reload@(c@)
assert_eq(cfg_keycount(c@, "s"), 2, "two keys, k and k2, after a reload")
assert_eq(cfg_keys$(c@, "s"), "k" + lf$ + "k2", "in the order they were written")
assert_eq(cfg_get$(c@, "s", "k2", "?"), "2", "and the new one reads back")
x = cfg_save(c@)
assert_eq(file_readalltext$(p$), t$, "a second save of the reloaded file changes no byte")

test_case("config-lines/what cannot be read back is refused, not written")
d@ = cfg_open@("bin/p9b_cfg_refused.ini")
raised = 0
msg$ = ""
d@ = cfg_set@(d@, "t", "nl", "a" + lf$ + "b")
assert_eq(raised, 1, "a value holding a line break is refused")
assert_true(instr(msg$, "line break") > 0, "and the message says why")
assert_eq(cfg_exists(d@, "t", "nl"), 0, "and nothing was written")
raised = 0
d@ = cfg_set@(d@, ";sec", "k", "v")
assert_eq(raised, 1, "a section beginning with a semicolon is refused")
raised = 0
d@ = cfg_set@(d@, "t", ";semi", "v")
assert_eq(raised, 1, "a key beginning with a semicolon is refused")
raised = 0
d@ = cfg_set@(d@, "t", "#hash", "v")
assert_eq(raised, 1, "a key beginning with a hash is refused")
raised = 0
d@ = cfg_set@(d@, "t", "a=b", "v")
assert_eq(raised, 1, "a key holding an equals sign is refused")
raised = 0
d@ = cfg_set@(d@, "t", "", "v")
assert_eq(raised, 1, "an empty key is refused")
raised = 0
d@ = cfg_set@(d@, "t", " sp ", "v")
assert_eq(raised, 1, "a key with blanks at its ends is refused")
raised = 0
d@ = cfg_set@(d@, "t", "val", " padded ")
assert_eq(raised, 1, "a value with blanks at its ends is refused")
raised = 0
d@ = cfg_set@(d@, "a" + lf$ + "b", "k", "v")
assert_eq(raised, 1, "a section holding a line break is refused")
raised = 0
d@ = cfg_setn@(d@, "t", "a=b", 1)
assert_eq(raised, 1, "the number setter asks the same question of its key")
raised = 0
d@ = cfg_setbs@(d@, ";b", 1)
assert_eq(raised, 1, "and so does the default-section boolean setter")
raised = 0
d@ = cfg_sets@(d@, "k", "x" + lf$)
assert_eq(raised, 1, "and the default-section string setter, of its value")
assert_eq(cfg_keycount(d@, "t"), 0, "not one of them reached the config")

test_case("config-lines/what CAN be read back still is")
rem Not refused, and each one a thing a refusal written too broadly would
rem catch: "=", "#" and ";" INSIDE a value (the line splits at its FIRST
rem "="), a value ending in a backslash (suspected of joining the next line
rem and measured not to), and a section name beginning with "#" (a header
rem line begins with "[", so no comment rule applies to it).
bs$ = chr$(92)
raised = 0
d@ = cfg_set@(d@, "t", "url", "http://x/?a=b#frag;y")
d@ = cfg_set@(d@, "t", "dir", "C:" + bs$ + "tmp" + bs$)
d@ = cfg_set@(d@, "#sec", "k", "v")
d@ = cfg_set@(d@, "t", "next", "kept")
assert_eq(raised, 0, "none of these is refused")
x = cfg_save(d@)
e@ = cfg_open@("bin/p9b_cfg_refused.ini")
assert_eq(cfg_get$(e@, "t", "url", "?"), "http://x/?a=b#frag;y", "a value holding = # ; reads back whole")
assert_eq(cfg_get$(e@, "t", "dir", "?"), "C:" + bs$ + "tmp" + bs$, "a trailing backslash reads back")
assert_eq(cfg_get$(e@, "t", "next", "?"), "kept", "and does not swallow the next key")
assert_eq(cfg_get$(e@, "#sec", "k", "?"), "v", "a section named with a leading hash reads back")

x = file_delete(p$)
x = file_delete("bin/p9b_cfg_refused.ini")
on error goto 0
end

trapped:
raised = 1
msg$ = errmsg$()
resume next
