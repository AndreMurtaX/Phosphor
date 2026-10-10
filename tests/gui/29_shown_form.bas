rem ---------------------------------------------------------------
rem ON A SHOWN FORM, A SETTER STILL ANSWERS (2026-10-09, round 4).
rem
rem Once a form has a window, a control's bounds go through
rem TWinControl.SendMoveSizeMessages (lcl/include/wincontrol.inc), which
rem RAISES for a left or top outside SmallInt and a width or height
rem outside Word -- after storing the value, so the window went on
rem raising at every later realign. An autosized caption wide enough to
rem pass TControl.DoSetBounds' 100000 trap raised "Division by zero"
rem from checkbox_caption@ and poisoned the form the same way. And a
rem spin edit cannot be realized past about 32780 pixels on win32, so
rem control_width@(spin@, 40000) raised from INSIDE the window procedure
rem and ended the process past any trap: THAT CASE IS LAST in this file,
rem because on a build without the fix it takes the run with it.
rem
rem Expected answers, from gui-control.md: nothing is raised; a value
rem past the host's ceiling (a position outside -32768..32767, a size
rem past 32767 -- PhosphorGuiCore.GuiMaxExtent) is refused with
rem gui_error 1 and the control keeps what it had; a size the control
rem works out for itself (an autosize) is held to that same ceiling.
rem
rem The trap is lifted around every run of assertions.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""
on error goto trapped

f@ = form@("shown", 400, 300)
b@ = button@(f@)
c@ = checkbox@(f@)
lb@ = label@(f@, "short")
x@ = control_bounds@(b@, 10, 20, 75, 25)
f@ = form_show@(f@)
x = app_processmessages()

test_case("shown/a position past a SmallInt is refused, not raised")
raised = 0
gui_clearerror()
x@ = control_left@(b@, 100000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "control_left@ 100000 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_left(b@), 10, "and the button stayed at 10")
on error goto trapped
raised = 0
gui_clearerror()
x@ = control_move@(b@, -40000, 5)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "control_move@ -40000 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped
raised = 0
gui_clearerror()
x@ = control_set@(b@, "Top", 40000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "the bridge did not raise")
assert_eq(gui_error(), 1, "and refused the same way")
assert_eq(control_top(b@), 20, "leaving the top at 20")
on error goto trapped

test_case("shown/a size past the ceiling is refused, not raised")
raised = 0
gui_clearerror()
x@ = control_height@(b@, 70000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "control_height@ 70000 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_height(b@), 25, "and the height is still 25")
on error goto trapped
raised = 0
gui_clearerror()
x@ = control_minwidth@(b@, 65536)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "control_minwidth@ 65536 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_width(b@), 75, "and the width is still 75")
on error goto trapped
raised = 0
gui_clearerror()
x@ = form_height@(f@, 70000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "form_height@ 70000 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

test_case("shown/the window is not poisoned by what was refused")
raised = 0
gui_clearerror()
b2@ = button@(f@)
x@ = control_top@(b2@, 60)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "a new button and a move after them did not raise")
assert_eq(gui_error(), 0, "nor record anything")
assert_eq(control_top(b2@), 60, "and the move took")
on error goto trapped

test_case("shown/an autosized caption is held to the ceiling")
raised = 0
gui_clearerror()
x@ = checkbox_caption@(c@, space$(100000))
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "a 100000-space check box caption did not raise")
assert_eq(len(checkbox_caption$(c@)), 100000, "the caption is all there")
assert_true(control_width(c@) <= 32767, "and the box is no wider than 32767")
on error goto trapped
w$ = "WWWWWWWWWW"
for i = 1 to 11
  w$ = w$ + w$
next
raised = 0
x@ = label_caption@(lb@, w$)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "a label 20480 W wide did not raise")
assert_true(control_width(lb@) <= 32767, "and is held to 32767 too")
on error goto trapped
raised = 0
lb2@ = label@(f@, w$)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "label@ with that caption did not raise either")
assert_true(control_width(lb2@) <= 32767, "a constructor's caption is held the same way")
on error goto trapped

test_case("shown/a group item the widgetset cannot create is refused")
rem On a fresh window, so this case does not lean on the ones above.
rem WHETHER the item can be created is the widgetset's business: win32
rem cannot make a radio button with a 100000-space caption, gtk2 can (the
rem first Linux run, 2026-10-09). What is Phosphor's is that nothing
rem raises and the answer and the group agree: refused means no item,
rem accepted means one.
f3@ = form@("group", 300, 200)
rg@ = radiogroup@(f3@)
f3@ = form_show@(f3@)
x = app_processmessages()
raised = 0
gui_clearerror()
x@ = radiogroup_add@(rg@, space$(100000))
x = app_processmessages()
big_err = gui_error()
on error goto 0
assert_eq(raised, 0, "radiogroup_add@ of 100000 spaces did not raise")
assert_true(big_err = 0 or big_err = 1, "it was accepted or refused, nothing else")
assert_eq(radiogroup_count(rg@), 1 - big_err, "and the group holds an item exactly when it was accepted")
on error goto trapped
gui_clearerror()
x@ = radiogroup_add@(rg@, "fine")
x = app_processmessages()
on error goto 0
assert_eq(gui_error(), 0, "an ordinary item still goes in")
assert_eq(radiogroup_count(rg@), 2 - big_err, "after whatever the first one was")
on error goto trapped

raised = 0
b3@ = button@(f@)
x@ = control_left@(b3@, 30)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "after both, the form still builds and moves controls")
assert_eq(control_left(b3@), 30, "and the move took")
on error goto trapped

test_case("shown/a spin edit is refused past 32767, not killed")
rem On a form of its own, so nothing refused above can stand between
rem the width and the window procedure.
f2@ = form@("spin", 300, 200)
sp@ = spinedit@(f2@)
f2@ = form_show@(f2@)
x = app_processmessages()
raised = 0
gui_clearerror()
x@ = control_set@(sp@, "Width", 40000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "the bridge did not raise")
assert_eq(gui_error(), 1, "and refused the width")
on error goto trapped
raised = 0
gui_clearerror()
x@ = control_width@(sp@, 40000)
x = app_processmessages()
on error goto 0
assert_eq(raised, 0, "control_width@ 40000 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_true(control_width(sp@) < 32768, "and the spin edit keeps a width it can hold")
on error goto trapped

end

trapped:
raised = 1
msg$ = errmsg$()
resume next
