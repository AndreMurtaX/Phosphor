rem ---------------------------------------------------------------
rem WHICH RADIO IS CHECKED IS THE PROGRAM'S ANSWER, ON EVERY OS (round
rem 10, 2026-10-11; docs/libraries/gui-choice.md, two-state controls).
rem
rem The rule, from the LCL's TRadioButton: radios that share a parent
rem are exclusive -- checking one unchecks each sibling
rem (radiobutton.inc ApplyChanges with no window; win32callback.inc
rem ClearSiblingRadioButtons and the gtk2 radio group with one) -- and
rem the checked one stays checked until something checks another.
rem Nothing in these cases touches a radio between the program's set
rem and the read, so each expected value is the program's last set.
rem
rem Three ways it was broken, all on a form that had been shown:
rem
rem   - SHOWN AGAIN. On Windows a radio that gets the focus while
rem     unchecked checks itself, and a form shown again hands the focus
rem     back to the control that had it. A dialog whose program checked
rem     d2 while it was hidden came back with d1 checked -- d1 had the
rem     focus when it went -- through form_show@ and form_showmodal
rem     alike. Linux kept d2.
rem   - MADE OR MOVED IN WHILE HIDDEN. Such a radio has no window while
rem     its siblings have one, and each widgetset's walk covers only its
rem     own half: two radios of one panel read checked (Linux after
rem     radio_checked@, Windows after a move).
rem   - A CHECKED RADIO MOVED IN. Once the windows exist the one arriving
rem     wins (its window is created checked, which unchecks the group:
rem     measured on a shown Windows form, d1 0 and m3 1 straight after
rem     control_parent@); before they exist both read checked.
rem ---------------------------------------------------------------

function pair$(a@, b@)
  return str$(radio_checked(a@)) + str$(radio_checked(b@))
end function

function shown_then_hidden(f@)
  form_show@(f@)
  x = app_processmessages()
  form_close@(f@)
  x = app_processmessages()
  return 0
end function

rem --- shown again --------------------------------------------------
test_case("reshow/a choice set while the dialog is hidden survives form_show@")
dlg@ = form@("options", 300, 200)
dp@ = panel@(dlg@)
d1@ = radiobutton@(dp@)
d2@ = radiobutton@(dp@)
radio_checked@(d1@, 1)
form_show@(dlg@)
x = app_processmessages()
assert_eq(pair$(d1@, d2@), "10", "d1 is the choice while it is up")
form_close@(dlg@)
x = app_processmessages()
radio_checked@(d2@, 1)
assert_eq(pair$(d1@, d2@), "01", "d2 is the choice once set, hidden")
form_show@(dlg@)
x = app_processmessages()
assert_eq(pair$(d1@, d2@), "01", "and still d2 once it is shown again")
form_close@(dlg@)
x = app_processmessages()
assert_eq(pair$(d1@, d2@), "01", "and after it is closed")

test_case("reshow/no choice set while it is hidden survives form_show@")
rem radio_checked@(d2@, 0) leaves the group with nothing checked; the
rem form had handed its focus to d2 (the checked one) when it was up.
radio_checked@(d2@, 0)
assert_eq(pair$(d1@, d2@), "00", "nothing is checked, hidden")
form_show@(dlg@)
x = app_processmessages()
assert_eq(pair$(d1@, d2@), "00", "nor once it is shown again")
form_close@(dlg@)
x = app_processmessages()

test_case("reshow/a choice set between two modal sessions survives the second")
mdlg@ = form@("modal options", 300, 200)
mp@ = panel@(mdlg@)
e1@ = radiobutton@(mp@)
e2@ = radiobutton@(mp@)
radio_checked@(e1@, 1)
seen$ = ""
gui_test_modal("answer_read")
r = form_showmodal(mdlg@)
assert_eq(r, 1, "the first session was answered")
assert_eq(seen$, "10", "e1 was the choice while it was up")
radio_checked@(e2@, 1)
gui_test_modal("answer_read")
r = form_showmodal(mdlg@)
assert_eq(r, 1, "the second session was answered")
assert_eq(seen$, "01", "e2 was the choice while the second was up")
assert_eq(pair$(e1@, e2@), "01", "and after it")

function answer_read(f@)
  seen$ = pair$(e1@, e2@)
  form_modalresult@(f@, 1)
  return 0
end function

rem --- made or moved in while hidden --------------------------------
test_case("exclusive/a radio made in a shown-then-hidden form is exclusive")
xf@ = form@("made", 300, 200)
xp@ = panel@(xf@)
x1@ = radiobutton@(xp@)
x = shown_then_hidden(xf@)
x2@ = radiobutton@(xp@)
radio_checked@(x1@, 1)
radio_checked@(x2@, 1)
assert_eq(pair$(x1@, x2@), "01", "checking the new one unchecks the old")
radio_checked@(x1@, 1)
assert_eq(pair$(x1@, x2@), "10", "and checking the old one the new")
x = shown_then_hidden(xf@)
assert_eq(pair$(x1@, x2@), "10", "the last set survives a show")

test_case("exclusive/a radio moved into a shown-then-hidden form is exclusive")
yf@ = form@("moved", 300, 200)
yp@ = panel@(yf@)
y1@ = radiobutton@(yp@)
ymain@ = form@("moved from", 300, 200)
y3@ = radiobutton@(ymain@)
x = shown_then_hidden(yf@)
control_parent@(y3@, yp@)
radio_checked@(y1@, 1)
radio_checked@(y3@, 1)
assert_eq(pair$(y1@, y3@), "01", "checking the moved one unchecks the old")
radio_checked@(y1@, 1)
assert_eq(pair$(y1@, y3@), "10", "and checking the old one the moved one")
x = shown_then_hidden(yf@)
assert_eq(pair$(y1@, y3@), "10", "the last set survives a show")

rem --- a checked radio moved in -------------------------------------
test_case("arrive/a checked radio moved into a form never shown wins")
af@ = form@("never shown", 300, 200)
ap@ = panel@(af@)
a1@ = radiobutton@(ap@)
a3@ = radiobutton@(af@)
radio_checked@(a1@, 1)
radio_checked@(a3@, 1)
assert_eq(pair$(a1@, a3@), "11", "in different parents, both are checked")
control_parent@(a3@, ap@)
assert_eq(pair$(a1@, a3@), "01", "moved in, the one arriving is the choice")

test_case("arrive/the same on a form shown and hidden")
bf@ = form@("shown once", 300, 200)
bp@ = panel@(bf@)
b1@ = radiobutton@(bp@)
b3@ = radiobutton@(bf@)
x = shown_then_hidden(bf@)
radio_checked@(b1@, 1)
radio_checked@(b3@, 1)
control_parent@(b3@, bp@)
assert_eq(pair$(b1@, b3@), "01", "the one arriving is the choice")
x = shown_then_hidden(bf@)
assert_eq(pair$(b1@, b3@), "01", "and still once shown")

test_case("arrive/the same on a form on screen")
cf@ = form@("on screen", 300, 200)
cp@ = panel@(cf@)
c1@ = radiobutton@(cp@)
c3@ = radiobutton@(cf@)
radio_checked@(c1@, 1)
radio_checked@(c3@, 1)
form_show@(cf@)
x = app_processmessages()
control_parent@(c3@, cp@)
assert_eq(pair$(c1@, c3@), "01", "the one arriving is the choice")
x = app_processmessages()
assert_eq(pair$(c1@, c3@), "01", "and stays it")
form_close@(cf@)
x = app_processmessages()

end
