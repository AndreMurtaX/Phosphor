rem ---------------------------------------------------------------
rem Text controls: label, edit and memo. The shared backbone
rem (PhosphorControlLib) already gives them geometry/colour/font; this
rem checks their own text, the memo's 1-based line access, and that an
rem edit's onchange reaches a BASIC handler when the text changes -- all
rem headless (a programmatic text change fires OnChange synchronously in
rem the LCL, no message loop needed).
rem ---------------------------------------------------------------

changes = 0

test_case("input/label")
f@ = form@("host", 400, 300)
l@ = label@(f@, "hello")
assert_eq(gui_error(), 0, "label@ built a label")
assert_eq(label_caption$(l@), "hello", "the constructor caption")
label_caption@(l@, "world")
assert_eq(label_caption$(l@), "world", "caption round trip")
control_move@(l@, 8, 8)
assert_eq(control_left(l@), 8, "the shared control helpers work on a label too")

test_case("input/edit")
e@ = edit@(f@)
edit_text@(e@, "abc")
assert_eq(edit_text$(e@), "abc", "text round trip")
edit_maxlength@(e@, 10)
assert_eq(edit_maxlength(e@), 10, "maxlength round trip")
edit_readonly@(e@, 1)
assert_eq(edit_readonly(e@), 1, "readonly on")
edit_readonly@(e@, 0)
edit_clear@(e@)
assert_eq(edit_text$(e@), "", "clear empties the text")

test_case("input/edit onchange reaches its handler")
edit_onchange@(e@, "on_change")
edit_text@(e@, "typed")
assert_eq(changes, 1, "a programmatic text change ran the handler")
assert_eq(edit_text$(e@), "typed", "and the text is set")
edit_onchange@(e@, "")
edit_text@(e@, "again")
assert_eq(changes, 1, "an empty name unwired the event")

test_case("input/memo")
m@ = memo@(f@)
memo_addline@(m@, "one")
memo_addline@(m@, "two")
memo_addline@(m@, "three")
assert_eq(memo_linecount(m@), 3, "three lines added")
assert_eq(memo_line$(m@, 2), "two", "the second line, 1-based")
memo_clear@(m@)
assert_eq(memo_linecount(m@), 0, "clear empties it")
memo_text@(m@, "a block")
assert_true(instr(memo_text$(m@), "a block"), "text set as a block")

function on_change(sender@)
  changes = changes + 1
  return 0
endfunction
