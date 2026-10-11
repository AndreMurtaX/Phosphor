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
rem the walk. A move asked for inside a handler now lands when the
rem handler has returned (docs/libraries/gui-control.md,
rem control_parent@).
rem
rem The doors into the walked list, each crossed here: a MOVE out of it
rem (the defect), a FREE (deferred since round 7), a control MADE under
rem it (TWinControl.Insert appends at ControlCount, past the bound the
rem loop already read), and a REORDER (control_bringtofront@ keeps the
rem count). Expected for each, from the loop above: nothing is raised,
rem and the walk unchecks r2.
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
  if m$ = "front" then
    assert_eq(radio_checked(r3@), 0, label$ + ": r3 was never checked")
    assert_eq(sibling(r1@, r3@), 1, label$ + ": and r3 is still r1's sibling")
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
  if mode$ = "front" then
    control_bringtofront@(wr3@)
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
test_case("walk/a sibling brought to the front under the walk")
walk_case("front")
test_case("walk/a sibling freed under the walk")
walk_case("free")

rem --- a move inside a handler: judged with the moves still pending ---
test_case("move/two moves in one handler are judged together for a cycle")
rem Alone, each is fine; together pa@ would be its own ancestor. The
rem second is refused while the first is still pending; after the
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
rem handles stay dead; the radio stays where it was.
fp@ = panel@(main@)
keep@ = panel@(main@)
k1@ = radiobutton@(keep@)
k2@ = radiobutton@(keep@)
mfree@ = button@(main@)
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
rem click's frames are under it. A move inside the dialog's own window
rem cannot be under any walk of MAIN's and lands at the next round; a
rem move of MAIN's controls waits until the click handler has returned
rem (gui-control.md, control_parent@). Moves land in the order asked, so
rem the dialog's is asked first.
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
opener@ = button@(main@)
button_onclick@(opener@, "open_dialog")
gui_test_modal("round_move")
gui_test_modal("round_read")
button_click@(opener@)
assert_eq(modalans, 1, "the dialog was answered OK")
assert_eq(landed_d, 1, "the dialog's move had landed at the next round")
assert_eq(landed_m, 0, "main's move had not: a handler of main's is under the session")
assert_eq(sibling(m1@, m3@), 0, "and main's lands once the click has returned")

function open_dialog(s@)
  modalans = form_showmodal(dlg@)
  return 0
end function

function round_move(f@)
  control_parent@(d3@, dother@)
  control_parent@(m3@, mother@)
  return 0
end function

function round_read(f@)
  landed_d = 1 - sibling(d1@, d3@)
  landed_m = 1 - sibling(m1@, m3@)
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
rem Its move has not landed when the host is freed, and then never will
rem (the host is dead). Done at once, the move and the free would have
rem left it without a parent and without a window -- hidden, which is
rem what the form it was asked to go into decides, not where it is now.
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
