rem ---------------------------------------------------------------
rem WAVE 4 (ledger d44): every GUI name no test had called, controls side.
rem
rem scripts/coverage.py kept these on a dated worklist -- registered,
rem documented, and never once executed by a test. Each is called here
rem and its effect read back. Every expected value comes from the
rem implementation or the LCL it calls, not from a run:
rem   * a setter answers the handle, a getter reads the property it set;
rem   * control_align is Ord(TAlign): alNone 0, alTop 1, alBottom 2,
rem     alLeft 3, alRight 4, alClient 5, alCustom 6; anything outside
rem     is ignored;
rem   * a font colour of clDefault is $20000000 = 536870912 (Graphics);
rem   * control_focused needs a window handle, which headless controls
rem     never get, so it is 0;
rem   * Constraints clamp the size the next SetBounds asks for.
rem
rem EVENTS. Measured on win32 and gtk2 alike: a change made FROM CODE
rem runs the handler of a radio button, a radio group, a toggle box, a
rem spin edit and a track bar, and those are driven that way. A combo
rem box, a list box and a tab control do NOT run theirs on a change from
rem code, with a window or without -- each is pinned as such below -- so
rem this runner's
rem test-only gui_test_fire calls the LCL's own method a person's action
rem ends in (TCustomComboBox.Change and the rest; see
rem host/gui/phosphorguitest.lpr). Every binding is then unbound with ""
rem and seen to stay quiet, which is how a handler that is always
rem called would be told from one that is bound.
rem
rem A WINDOW CHANGES SOME ANSWERS, and the last case shows its form for
rem them. A memo's text set from code runs its handler once the memo has
rem a window (gui-edit.md says so), and not before: the first draft of
rem this file pinned the headless silence as the rule, and an adversarial
rem review caught it the same day. Focus, too, needs a window, and so
rem does a paint (25_wave4_canvas).
rem ---------------------------------------------------------------

hits = 0
f@ = form@("wave4", 400, 300)

test_case("wave4/control alignment")
b@ = button@(f@)
assert_eq(control_align(b@), 0, "a new control is alNone")
r@ = control_align@(b@, 3)
assert_eq(control_align(r@), 3, "alLeft reads back")
control_align@(b@, 99)
assert_eq(control_align(b@), 3, "a value outside TAlign is ignored")
control_align@(b@, 0)

test_case("wave4/control font and visibility")
assert_eq(control_fontcolor(b@), 536870912, "a new control's font colour is clDefault")
control_fontcolor@(b@, 255)
assert_eq(control_fontcolor(b@), 255, "red reads back")
control_italic@(b@, 1)
assert_eq(control_italic(b@), 1, "italic on")
control_italic@(b@, 0)
assert_eq(control_italic(b@), 0, "italic off")
control_underline@(b@, 1)
assert_eq(control_underline(b@), 1, "underline on")
control_underline@(b@, 0)
assert_eq(control_underline(b@), 0, "underline off")
control_visible@(b@, 0)
assert_eq(control_visible(b@), 0, "hidden")
control_visible@(b@, 1)
assert_eq(control_visible(b@), 1, "shown again")
assert_eq(control_focused(b@), 0, "a headless control has no focus to hold")

test_case("wave4/control height and its constraints")
control_height@(b@, 40)
assert_eq(control_height(b@), 40, "height reads back")
assert_eq(control_minheight(b@), 0, "no minimum by default")
assert_eq(control_maxheight(b@), 0, "no maximum by default (0 is none)")
control_minheight@(b@, 50)
assert_eq(control_minheight(b@), 50, "a minimum reads back")
control_height@(b@, 20)
assert_eq(control_height(b@), 50, "and a smaller height is raised to it")
control_maxheight@(b@, 100)
assert_eq(control_maxheight(b@), 100, "a maximum reads back")
control_height@(b@, 300)
assert_eq(control_height(b@), 100, "and a larger height is held to it")

test_case("wave4/buttons")
bb@ = bitbtn@(f@)
bitbtn_caption@(bb@, "Go")
assert_eq(bitbtn_caption$(bb@), "Go", "a bit button's caption reads back")
sp@ = speedbutton@(f@)
r@ = speedbutton_caption@(sp@, "Fast")
assert_eq(speedbutton_caption$(r@), "Fast", "a speed button's caption reads back")
hits = 0
speedbutton_onclick@(sp@, "on_hit")
speedbutton_click@(sp@)
assert_eq(hits, 1, "a synthesised click runs the handler")
speedbutton_onclick@(sp@, "")
speedbutton_click@(sp@)
assert_eq(hits, 1, "and an empty name unbinds it")

test_case("wave4/edits")
e@ = edit@(f@)
edit_text@(e@, "hello")
r@ = edit_selectall@(e@)
assert_eq(edit_text$(r@), "hello", "and selects without changing the text")
assert_eq(gui_test_selection(e@), 5, "all five characters are selected")
me@ = maskedit@(f@)
r@ = maskedit_text@(me@, "abc")
assert_eq(maskedit_text$(r@), "abc", "with no mask the text reads back as set")
m@ = memo@(f@)
memo_readonly@(m@, 1)
assert_eq(memo_readonly(m@), 1, "a memo made read-only")
memo_readonly@(m@, 0)
assert_eq(memo_readonly(m@), 0, "and writable again")
memo_wordwrap@(m@, 0)
assert_eq(memo_wordwrap(m@), 0, "word wrap off")
memo_wordwrap@(m@, 1)
assert_eq(memo_wordwrap(m@), 1, "and on")
s@ = spinedit@(f@)
hits = 0
spinedit_onchange@(s@, "on_hit")
spinedit_value@(s@, 5)
assert_eq(hits, 1, "a spin edit's value set from code runs its handler")
spinedit_onchange@(s@, "")
spinedit_value@(s@, 6)
assert_eq(hits, 1, "unbound, it stays quiet")

test_case("wave4/combo and list")
c@ = combobox@(f@)
combo_add@(c@, "a")
combo_add@(c@, "b")
combo_itemindex@(c@, 2)
assert_eq(combo_text$(c@), "b", "choosing item 2 makes its text the combo's")
hits = 0
combo_onchange@(c@, "on_hit")
combo_itemindex@(c@, 1)
assert_eq(hits, 0, "an item chosen from code does not run the handler")
assert_eq(gui_test_fire(c@, "change"), 1, "the LCL's own Change does")
assert_eq(hits, 1, "once")
combo_onchange@(c@, "")
x = gui_test_fire(c@, "change")
assert_eq(hits, 1, "unbound, it stays quiet")
l@ = listbox@(f@)
list_add@(l@, "x")
list_add@(l@, "y")
assert_eq(list_count(l@), 2, "two items")
r@ = list_clear@(l@)
assert_eq(list_count(r@), 0, "and empties the list")
list_add@(l@, "z")
hits = 0
list_onclick@(l@, "on_hit")
list_itemindex@(l@, 1)
assert_eq(hits, 0, "an item chosen from code is not a click")
assert_eq(gui_test_fire(l@, "click"), 1, "the LCL's own Click is")
assert_eq(hits, 1, "and runs the handler")
list_onclick@(l@, "")
x = gui_test_fire(l@, "click")
assert_eq(hits, 1, "unbound, it stays quiet")

test_case("wave4/radios, toggles and groups")
r@ = radiobutton@(f@)
hits = 0
radio_onchange@(r@, "on_hit")
radio_checked@(r@, 1)
assert_eq(hits, 1, "checking a radio button runs its handler")
radio_onchange@(r@, "")
radio_checked@(r@, 0)
assert_eq(hits, 1, "unbound, it stays quiet")
g@ = radiogroup@(f@)
radiogroup_add@(g@, "one")
radiogroup_add@(g@, "two")
radiogroup_caption@(g@, "Pick")
assert_eq(radiogroup_caption$(g@), "Pick", "a radio group's caption reads back")
hits = 0
radiogroup_onchange@(g@, "on_hit")
radiogroup_itemindex@(g@, 2)
assert_eq(hits, 1, "choosing an item runs the group's handler")
radiogroup_onchange@(g@, "")
radiogroup_itemindex@(g@, 1)
assert_eq(hits, 1, "unbound, it stays quiet")
t@ = togglebox@(f@)
hits = 0
togglebox_onchange@(t@, "on_hit")
togglebox_checked@(t@, 1)
assert_eq(hits, 1, "pressing a toggle box runs its handler")
togglebox_onchange@(t@, "")
togglebox_checked@(t@, 0)
assert_eq(hits, 1, "unbound, it stays quiet")
k@ = checkgroup@(f@)
checkgroup_caption@(k@, "Options")
assert_eq(checkgroup_caption$(k@), "Options", "a check group's caption reads back")
checkgroup_add@(k@, "first")
checkgroup_add@(k@, "second")
assert_eq(checkgroup_item$(k@, 2), "second", "its items are 1-based")
assert_eq(checkgroup_item$(k@, 3), "", "and one past the end is empty")
r@ = checkgroup_clear@(k@)
assert_eq(checkgroup_count(r@), 0, "and empties it")

test_case("wave4/tabs")
tc@ = tabcontrol@(f@)
tabcontrol_add@(tc@, "one")
tabcontrol_add@(tc@, "two")
hits = 0
tabcontrol_onchange@(tc@, "on_hit")
tabcontrol_tabindex@(tc@, 2)
assert_eq(hits, 0, "a tab chosen from code does not run the handler")
assert_eq(gui_test_fire(tc@, "change"), 1, "the LCL's own Change does")
assert_eq(hits, 1, "once")
tabcontrol_onchange@(tc@, "")
x = gui_test_fire(tc@, "change")
assert_eq(hits, 1, "unbound, it stays quiet")
pc@ = pagecontrol@(f@)
ts@ = tabsheet@(pc@, "first")
r@ = tabsheet_caption@(ts@, "renamed")
assert_eq(tabsheet_caption$(r@), "renamed", "a tab sheet's caption reads back")

test_case("wave4/ranges")
pb@ = progressbar@(f@)
progressbar_max@(pb@, 50)
assert_eq(progressbar_max(pb@), 50, "a progress bar's maximum reads back")
progressbar_min@(pb@, 10)
assert_eq(progressbar_min(pb@), 10, "and its minimum")
sb@ = scrollbar@(f@)
scrollbar_max@(sb@, 200)
assert_eq(scrollbar_max(sb@), 200, "a scroll bar's maximum reads back")
scrollbar_min@(sb@, 5)
assert_eq(scrollbar_min(sb@), 5, "and its minimum")
tb@ = trackbar@(f@)
trackbar_min@(tb@, 2)
assert_eq(trackbar_min(tb@), 2, "a track bar's minimum reads back")
hits = 0
trackbar_onchange@(tb@, "on_hit")
trackbar_position@(tb@, 4)
assert_eq(hits, 1, "moving a track bar from code runs its handler")
trackbar_onchange@(tb@, "")
trackbar_position@(tb@, 5)
assert_eq(hits, 1, "unbound, it stays quiet")
ud@ = updown@(f@)
updown_min@(ud@, -5)
updown_max@(ud@, 5)
assert_eq(updown_min(ud@), -5, "an up-down's minimum reads back")
assert_eq(updown_max(ud@), 5, "and its maximum")

test_case("wave4/image, list item, timer, font dialog")
im@ = image@(f@)
image_proportional@(im@, 1)
assert_eq(image_proportional(im@), 1, "proportional on")
image_proportional@(im@, 0)
assert_eq(image_proportional(im@), 0, "and off")
lv@ = listview@(f@)
it@ = listitem@(lv@, "old")
r@ = listitem_caption@(it@, "new")
assert_eq(listitem_caption$(r@), "new", "a list item's caption reads back")
tm@ = timer@()
timer_interval@(tm@, 600000)
timer_enabled@(tm@, 1)
assert_eq(timer_enabled(tm@), 1, "a timer enabled")
timer_enabled@(tm@, 0)
assert_eq(timer_enabled(tm@), 0, "and disabled before it can fire")
fd@ = fontdialog@()
fontdialog_fontcolor@(fd@, 65280)
assert_eq(fontdialog_fontcolor(fd@), 65280, "a font dialog's colour reads back")
assert_eq(app_processmessages(), 0, "processing pending messages answers 0")

test_case("wave4/tray icon")
ti@ = trayicon@()
assert_eq(trayicon_visible(ti@), 0, "a new tray icon is hidden")
r@ = trayicon_show@(ti@)
assert_eq(trayicon_visible(r@), 1, "and shows it")
r@ = trayicon_hide@(ti@)
assert_eq(trayicon_visible(r@), 0, "and hides it")
hits = 0
trayicon_onclick@(ti@, "on_hit")
assert_eq(gui_test_fire(ti@, "click"), 1, "a click reaches the tray icon")
assert_eq(hits, 1, "and its handler")
trayicon_onclick@(ti@, "")
x = gui_test_fire(ti@, "click")
assert_eq(hits, 1, "unbound, it stays quiet")

test_case("wave4/with a window: memo changes and focus")
w@ = form@("wave4 shown", 300, 200)
wm@ = memo@(w@)
wb@ = button@(w@)
w@ = form_show@(w@)
x = app_processmessages()
hits = 0
memo_onchange@(wm@, "on_hit")
memo_text@(wm@, "typed")
assert_eq(hits, 1, "a memo's text set from code runs its handler, as gui-edit.md says")
memo_addline@(wm@, "another")
assert_eq(hits, 2, "and so does a line added")
memo_onchange@(wm@, "")
memo_text@(wm@, "quiet")
assert_eq(hits, 2, "unbound, it stays quiet")
assert_eq(control_focused(wb@), 0, "a button nobody focused has no focus")
wb@ = control_setfocus@(wb@)
rem FOCUS ARRIVES ASYNCHRONOUSLY ON GTK2: the window manager has to activate
rem the window first. Measured on the Linux VM (mutter, XWayland), 12 runs:
rem focused after 1 or 2 pumps, never more -- and this assertion, asked after
rem ONE, failed 3 runs in 10. Win32 answers on the first pump. So pump until
rem it arrives, bounded at 2 s; a setfocus that did nothing still exhausts
rem the bound and fails here.
k = 0
x = app_processmessages()
while control_focused(wb@) = 0 and k < 40
  x = pause(0.05)
  x = app_processmessages()
  k = k + 1
wend
assert_eq(control_focused(wb@), 1, "and has it once focused")
w@ = form_close@(w@)
x = app_processmessages()
end

function on_hit(sender@)
  hits = hits + 1
  return 0
endfunction
