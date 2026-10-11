rem ---------------------------------------------------------------
rem MOVING A CONTROL WHILE THE LCL WALKS ITS PARENT'S LIST, AND THE
rem FORMS A FREE LEAVES WITHOUT A HOST (round 8, 2026-10-11).
rem
rem TRadioButton.ApplyChanges (lcl/include/radiobutton.inc), when the
rem radios have no window handle -- before form_show@, or headless as
rem here -- unchecks each sibling of the radio being checked:
rem
rem     for i := 0 to Parent.ControlCount - 1 do ... Parent.Controls[i]
rem
rem The bound is read ONCE, and a sibling's onchange runs BASIC from
rem inside the loop. Round 7 deferred a FREE inside a handler; a
rem control_parent@ that moved a sibling out of the panel still took it
rem out of the list at once, and the loop read past its end: "List
rem index (2) out of bounds", raised at the radio_checked@ that started
rem the walk. A move a walk may stand on -- out of the list of a
rem running handler's sender or of one of its ancestors -- now waits
rem until that handler has returned; any other lands at once (round 9;
rem docs/libraries/gui-control.md, control_parent@).
rem
rem The doors into the walked list, each crossed here: a MOVE out of it
rem (the defect), a FREE (deferred since round 7), a control MADE under
rem it (TWinControl.Insert appends at ControlCount, past the bound the
rem loop already read), and a REORDER (control_sendtoback@ keeps the
rem count, so it lands at once). Expected for each, from the loop above:
rem nothing is raised, and the walk unchecks r2.
rem
rem THE REORDER MUST REORDER (round 10). This case used to bring r3 to
rem the front, and r3 was already last: TWinControl.SetChildZPosition
rem clamps the new place to Count-1, which was r3's own, and moved
rem nothing -- every assertion held with the handler doing nothing. It
rem now sends r3 to the BACK, ahead of the r1 the walk started from,
rem and asks the order back (zbefore, below). And a reorder asked while
rem a move of the control waits applies to the parent it is going to,
rem once it gets there (gui-control.md, control_sendtoback@): crossed by
rem "moveback", which moves r3 out under the walk and sends it to the
rem back of the OTHER panel. Applied at once instead, it would reorder
rem the walked list and leave r3 at the front of the other panel.
rem
rem THE ORDER OF A PARENT'S LIST IS READ BACK THROUGH A WALK TOO. With
rem w checked and its onchange checking x, checking c walks the list:
rem met before w, x is still unchecked and the handler checks it after;
rem met after w, the handler checks it first and the walk then unchecks
rem it. So x ends checked exactly when x comes before w.
rem
rem WHERE A CONTROL LIVES IS READ BACK THROUGH THE SAME WALK. There is
rem no parent getter, but sibling radios uncheck each other and radios
rem in different parents do not: check a, then b; a is still checked
rem exactly when b is NOT a's sibling. Every "landed" assertion below is
rem that test.
rem
rem And a form embedded with control_parent@ owns itself, so freeing
rem its host does not free it: TWinControl.Destroy (wincontrol.inc)
rem destroys the host's window -- the embedded one with it -- and then
rem only unparents its children ("controls are freed by the owner").
rem It was left Visible, top-level and with no window: form_visible
rem answered 1 and app_run counted it as a window on screen. Expected
rem now (gui-control.md, control_free): it is hidden.
rem ---------------------------------------------------------------

raised = 0
ran = 0
inerr = -1
modalans = -1
modalerr = -1
cycleerr = -1
firsterr = -1
landed_d = -1
landed_m = -1
mode$ = ""

main@ = form@("walks", 400, 300)

function sibling(a@, b@)
  rem 1 when a@ and b@ share a parent: checking b@ unchecks a@.
  radio_checked@(a@, 1)
  radio_checked@(b@, 1)
  if radio_checked(a@) = 0 then
    return 1
  end if
  return 0
end function

function zbefore(x@, w@, c@)
  rem 1 when x@ comes before w@ in their parent's list (see above);
  rem x@, w@ and c@ are sibling radios.
  zx@ = x@
  radio_checked@(x@, 0)
  radio_checked@(w@, 1)
  radio_onchange@(w@, "z_watch")
  radio_checked@(c@, 1)
  radio_onchange@(w@, "")
  return radio_checked(x@)
end function

function z_watch(s@)
  radio_checked@(zx@, 1)
  return 0
end function

rem --- the walk, crossed with each door ----------------------------
function walk_case(m$) local rp@, other@, r1@, r2@, r3@, label$
  mode$ = m$
  raised = 0
  ran = 0
  inerr = -1
  rp@ = panel@(main@)
  other@ = panel@(main@)
  r1@ = radiobutton@(rp@)
  r2@ = radiobutton@(rp@)
  r3@ = radiobutton@(rp@)
  o1@ = radiobutton@(other@)
  o2@ = radiobutton@(other@)
  wr3@ = r3@
  wother@ = other@
  wrp@ = rp@
  radio_checked@(r2@, 1)
  radio_onchange@(r2@, "on_r2")
  gui_clearerror()
  on error goto trapped
  radio_checked@(r1@, 1)
  on error goto 0
  label$ = "walk/" + m$
  assert_eq(raised, 0, label$ + ": nothing was raised at the radio_checked@ that walked")
  assert_eq(ran, 1, label$ + ": r2's onchange ran once")
  assert_eq(inerr, 0, label$ + ": the door was not refused inside the handler")
  assert_eq(radio_checked(r2@), 0, label$ + ": the walk finished: r2 is unchecked")
  assert_eq(radio_checked(r1@), 1, label$ + ": and r1 is checked")
  if m$ = "move" then
    assert_eq(sibling(r1@, r3@), 0, label$ + ": r3 landed in the other panel once the handler returned")
  end if
  if m$ = "make" then
    assert_eq(sibling(r1@, newr@), 1, label$ + ": the radio made under the walk is r1's sibling")
  end if
  if m$ = "back" then
    assert_eq(radio_checked(r3@), 0, label$ + ": r3 was never checked")
    assert_eq(zbefore(r3@, r2@, r1@), 1, label$ + ": r3 went to the back of the walked list at once")
    assert_eq(sibling(r1@, r3@), 1, label$ + ": and is still r1's sibling")
  end if
  if m$ = "moveback" then
    assert_eq(sibling(r1@, r3@), 0, label$ + ": r3 landed in the other panel")
    assert_eq(zbefore(r3@, o2@, o1@), 1, label$ + ": at the back of it, as asked")
  end if
  if m$ = "free" then
    gui_clearerror()
    assert_eq(control_free(r3@), 0, label$ + ": the freed sibling stays freed")
    assert_eq(gui_error(), 1, label$ + ": and says so")
  end if
  return 0
end function

function on_r2(s@)
  ran = ran + 1
  gui_clearerror()
  if mode$ = "move" then
    control_parent@(wr3@, wother@)
  end if
  if mode$ = "make" then
    newr@ = radiobutton@(wrp@)
  end if
  if mode$ = "back" then
    control_sendtoback@(wr3@)
  end if
  if mode$ = "moveback" then
    control_parent@(wr3@, wother@)
    control_sendtoback@(wr3@)
  end if
  if mode$ = "free" then
    x = control_free(wr3@)
  end if
  inerr = gui_error()
  return 0
end function

test_case("walk/a sibling moved out of the panel under the walk")
walk_case("move")
test_case("walk/a sibling made under the walk")
walk_case("make")
test_case("walk/a sibling sent to the back under the walk")
walk_case("back")
test_case("walk/a sibling moved out and sent to the back under the walk")
walk_case("moveback")
test_case("walk/a sibling freed under the walk")
walk_case("free")

rem --- a move inside a handler: judged with the moves still pending ---
test_case("move/two moves in one handler are judged together for a cycle")
rem Alone, each is fine; together pa@ would be its own ancestor. Both
rem leave MAIN's list, and the clicked button is on main, so both wait.
rem The second is refused while the first is still pending; after the
rem handler, pa@ lives in pb@ -- so placing pb@ in pa@ is refused at
rem top level too, by the chain that now exists.
pa@ = panel@(main@)
pb@ = panel@(main@)
mb@ = button@(main@)
button_onclick@(mb@, "on_cycle")
button_click@(mb@)
assert_eq(firsterr, 0, "the first move was accepted")
assert_eq(cycleerr, 1, "the second, a cycle with the first, was refused")
gui_clearerror()
control_parent@(pb@, pa@)
assert_eq(gui_error(), 1, "after the handler, pa@ is in pb@: pb@ into pa@ is a cycle")

function on_cycle(s@)
  gui_clearerror()
  control_parent@(pa@, pb@)
  firsterr = gui_error()
  gui_clearerror()
  control_parent@(pb@, pa@)
  cycleerr = gui_error()
  return 0
end function

test_case("move/a form moved in a handler is not shown modally after it")
rem form_showmodal refuses a form parented inside another
rem (gui-form.md); one whose move has not landed yet is judged where it
rem was asked to go -- otherwise the session opens and the move lands
rem on a modal form, which control_parent@ refuses.
mf@ = form@("moved", 100, 60)
mc@ = button@(main@)
button_onclick@(mc@, "on_move_modal")
button_click@(mc@)
assert_eq(modalans, 0, "the moved form's form_showmodal answered 0")
assert_eq(modalerr, 1, "with gui_error 1")

function on_move_modal(s@)
  control_parent@(mf@, main@)
  gui_clearerror()
  modalans = form_showmodal(mf@)
  modalerr = gui_error()
  return 0
end function

test_case("move/a move into a panel freed in the same handler does not land")
rem The panel is dead to the program the moment it is freed; a move into
rem it would land a control in something already gone. Freed control
rem handles stay dead; the radio stays where it was. The clicked button
rem is in keep@, the panel k2 leaves, so the move waits (a walk of
rem keep@'s list may be under the click) -- and a move that waits for a
rem parent freed meanwhile does not land.
fp@ = panel@(main@)
keep@ = panel@(main@)
k1@ = radiobutton@(keep@)
k2@ = radiobutton@(keep@)
mfree@ = button@(keep@)
button_onclick@(mfree@, "on_move_then_free")
raised = 0
on error goto trapped
button_click@(mfree@)
on error goto 0
assert_eq(raised, 0, "nothing was raised")
assert_eq(sibling(k1@, k2@), 1, "k2 never left k1's panel")

function on_move_then_free(s@)
  control_parent@(k2@, fp@)
  x = control_free(fp@)
  return 0
end function

rem --- inside a modal session --------------------------------------
test_case("modal/the dialog's own move lands between its rounds")
rem The session is opened from a click on a button of MAIN, so that
rem click's frames are under it -- and a walk under them can only be of
rem the list of the button or of one of its ancestors: main's own list.
rem A move inside the dialog's own window lands at once; so does a move
rem out of a panel of main's the button is not in (round 9: round 8 held
rem every move touching main's window until the click returned). A move
rem out of MAIN's own list waits until the click handler has returned
rem (gui-control.md, control_parent@).
dlg@ = form@("dialog", 300, 200)
dp@ = panel@(dlg@)
dother@ = panel@(dlg@)
d1@ = radiobutton@(dp@)
d3@ = radiobutton@(dp@)
ok@ = button@(dlg@)
button_modalresult@(ok@, 1)
mp@ = panel@(main@)
mother@ = panel@(main@)
m1@ = radiobutton@(mp@)
m3@ = radiobutton@(mp@)
mr1@ = radiobutton@(main@)
mr3@ = radiobutton@(main@)
landed_r = -1
opener@ = button@(main@)
button_onclick@(opener@, "open_dialog")
gui_test_modal("round_move")
gui_test_modal("round_read")
button_click@(opener@)
assert_eq(modalans, 1, "the dialog was answered OK")
assert_eq(landed_d, 1, "the dialog's move had landed at the next round")
assert_eq(landed_m, 1, "so had the move out of a panel of main's the opener is not in")
assert_eq(landed_r, 0, "the move out of main's own list had not: the opener's click is under the session")
assert_eq(sibling(mr1@, mr3@), 0, "and it lands once the click has returned")

function open_dialog(s@)
  modalans = form_showmodal(dlg@)
  return 0
end function

function round_move(f@)
  control_parent@(d3@, dother@)
  control_parent@(m3@, mother@)
  control_parent@(mr3@, mother@)
  return 0
end function

function round_read(f@)
  landed_d = 1 - sibling(d1@, d3@)
  landed_m = 1 - sibling(m1@, m3@)
  landed_r = 1 - sibling(mr1@, mr3@)
  button_click@(ok@)
  return 0
end function

test_case("modal/a move under a walk below the session waits for it")
rem Checking w1 walks wp's radios and unchecks w2, whose onchange opens
rem the dialog; inside it w3 is moved out of wp. Landed between rounds,
rem the walk below would read past the end of wp's list when the dialog
rem is answered. Expected, from the loop: nothing raised, w2 unchecked,
rem and w3 elsewhere once everything has returned.
wp@ = panel@(main@)
wo@ = panel@(main@)
w1@ = radiobutton@(wp@)
w2@ = radiobutton@(wp@)
w3@ = radiobutton@(wp@)
radio_checked@(w2@, 1)
radio_onchange@(w2@, "w2_opens")
gui_test_modal("round_move_w3")
gui_test_modal("round_ok")
modalans = -1
raised = 0
on error goto trapped
radio_checked@(w1@, 1)
on error goto 0
assert_eq(raised, 0, "nothing was raised at the radio_checked@ under the session")
assert_eq(modalans, 1, "the dialog was answered OK")
assert_eq(radio_checked(w2@), 0, "the walk finished: w2 is unchecked")
assert_eq(sibling(w1@, w3@), 0, "and w3 landed in the other panel")

function w2_opens(s@)
  modalans = form_showmodal(dlg@)
  return 0
end function

function round_move_w3(f@)
  control_parent@(w3@, wo@)
  return 0
end function

function round_ok(f@)
  button_click@(ok@)
  return 0
end function

rem --- the forms a free leaves without a host ------------------------
test_case("orphan/a form embedded in a freed form is hidden")
host@ = form@("host", 300, 200)
inner@ = form@("inner", 100, 60)
control_parent@(inner@, host@)
control_visible@(inner@, 1)
assert_eq(form_visible(inner@), 1, "the embedded form is visible to begin with")
assert_eq(control_free(host@), 1, "its host was freed")
assert_eq(form_visible(inner@), 0, "and the form it held is hidden: it has no window")
gui_clearerror()
assert_eq(control_free(inner@), 1, "the form itself is alive -- it owns itself")

test_case("orphan/a form embedded in a freed panel is hidden")
host@ = form@("host", 300, 200)
hp@ = panel@(host@)
inner@ = form@("inner", 100, 60)
control_parent@(inner@, hp@)
control_visible@(inner@, 1)
assert_eq(control_free(hp@), 1, "the panel was freed")
assert_eq(form_visible(inner@), 0, "and the form it held is hidden")
assert_eq(control_free(inner@), 1, "the form itself is alive")
assert_eq(control_free(host@), 1, "and so is the host form")

test_case("orphan/a form still embedded in a survivor stays as it was")
rem inner2 lives in inner, which outlives host: freeing host unparents
rem inner only (TWinControl.Destroy removes its OWN children), so inner2
rem keeps its parent and its Visible.
host@ = form@("host", 300, 200)
inner@ = form@("inner", 100, 60)
inner2@ = form@("inner2", 50, 30)
control_parent@(inner@, host@)
control_parent@(inner2@, inner@)
control_visible@(inner@, 1)
control_visible@(inner2@, 1)
assert_eq(control_free(host@), 1, "the host was freed")
assert_eq(form_visible(inner@), 0, "the form it held is hidden")
assert_eq(form_visible(inner2@), 1, "the form held by THAT one is untouched")
assert_eq(control_free(inner@), 1, "inner is alive")
assert_eq(control_free(inner2@), 1, "inner2 is alive")

test_case("orphan/a form whose host is freed inside a handler is hidden at once")
rem The free is deferred (gui-control.md), but for the program it has
rem happened: the form is hidden before the handler returns.
host@ = form@("host", 300, 200)
inner@ = form@("inner", 100, 60)
control_parent@(inner@, host@)
control_visible@(inner@, 1)
hb@ = button@(main@)
button_onclick@(hb@, "free_host")
inneris = -1
button_click@(hb@)
assert_eq(inneris, 0, "hidden inside the handler that freed its host")
assert_eq(form_visible(inner@), 0, "and still hidden after it")
assert_eq(control_free(inner@), 1, "the form itself is alive")

function free_host(s@)
  x = control_free(host@)
  inneris = form_visible(inner@)
  return 0
end function

test_case("orphan/a form moved into a host freed in the same handler is hidden")
rem The clicked button is on main, so nothing a walk may stand on is
rem touched: the move lands at once (round 9), and the free of the host
rem then leaves the form without one -- hidden, and a top-level form.
host@ = form@("host", 300, 200)
inner@ = form@("inner", 100, 60)
control_visible@(inner@, 1)
hm@ = button@(main@)
button_onclick@(hm@, "move_then_free_host")
inneris = -1
button_click@(hm@)
assert_eq(inneris, 0, "hidden inside the handler")
assert_eq(form_visible(inner@), 0, "and still hidden after it")
assert_eq(control_free(inner@), 1, "the form itself is alive")

function move_then_free_host(s@)
  control_parent@(inner@, host@)
  x = control_free(host@)
  inneris = form_visible(inner@)
  return 0
end function

end

trapped:
raised = 1
resume next
