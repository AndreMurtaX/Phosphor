rem ---------------------------------------------------------------
rem WHERE A MOVE LANDS, AND WHAT THE PROGRAM SEES MEANWHILE (round 9,
rem 2026-10-11; docs/libraries/gui-control.md, control_parent@ and
rem control_free).
rem
rem Round 8 deferred EVERY control_parent@ asked inside a handler, and
rem the program's view (what it asked) and the LCL's (what had landed)
rem then disagreed for the rest of the handler. Round 9 decides it:
rem
rem   - a move waits only when a walk may stand on the list it leaves:
rem     the control, or its parent, is a running handler's sender or an
rem     ancestor of one (the LCL's walks that run BASIC -- a radio's
rem     sibling walk, a parent painting its graphic children -- reach
rem     it through an event of a control IN the walked list). Any other
rem     move lands at once, as at depth 0;
rem   - while one waits, every reader answers what the program asked;
rem   - a move into a parent freed before it lands does not happen, and
rem     the one asked before it counts again;
rem   - a form whose host is freed is hidden and made a top-level form.
rem
rem WHERE A CONTROL LIVES IS READ BACK THROUGH THE RADIO WALK, as in
rem 32_parent_walk: checking a, then b, unchecks a exactly when b is
rem a's sibling. WHETHER A FORM IS TOP-LEVEL is read back through
rem form_showmodal, which refuses a form placed inside another
rem (gui-form.md) and runs a top-level hidden one.
rem ---------------------------------------------------------------

main@ = form@("view", 400, 300)
ans = -1
inner_tab = -1
inner_vis = -1

function sibling(a@, b@)
  rem 1 when a@ and b@ share a parent: checking b@ unchecks a@. b@ is
  rem unchecked first, so the check is a CHANGE and walks -- two radios
  rem that met already checked would otherwise both stay checked.
  radio_checked@(b@, 0)
  radio_checked@(a@, 1)
  radio_checked@(b@, 1)
  if radio_checked(a@) = 0 then
    return 1
  end if
  return 0
end function

function answer_ok(f@)
  form_modalresult@(f@, 1)
  return 0
end function

function toplevel(f@)
  rem 1 when the hidden form f@ is a window of its own: form_showmodal
  rem runs it (answered 1) instead of refusing it as parented.
  gui_test_modal("answer_ok")
  gui_clearerror()
  r = form_showmodal(f@)
  if r = 1 then
    return 1
  end if
  return 0
end function

function parented(f@)
  rem 1 when the hidden form f@ is placed inside another: form_showmodal
  rem refuses it with gui_error 1, and nothing is queued for it to use.
  gui_clearerror()
  r = form_showmodal(f@)
  if r = 0 and gui_error() = 1 then
    return 1
  end if
  return 0
end function

rem --- two moves of one control, the second target freed ------------
test_case("order/x to p1 then to p2, p2 freed: x lands in p1")
rem Asked in order, x->p1 lands and x->p2 does not (its parent is gone
rem before it can). Round 8 merged two back-to-back moves of one control
rem into the second, so the first was lost and x stayed in p0. The
rem button is in p0, so both moves wait (p0 may be under a walk).
p0@ = panel@(main@)
p1@ = panel@(main@)
p2@ = panel@(main@)
r0@ = radiobutton@(p0@)
bx@ = radiobutton@(p0@)
r1@ = radiobutton@(p1@)
ob@ = button@(p0@)
button_onclick@(ob@, "on_b2b")
button_click@(ob@)
assert_eq(sibling(r1@, bx@), 1, "x is in p1")
assert_eq(sibling(r0@, bx@), 0, "and not in p0")

function on_b2b(s@)
  control_parent@(bx@, p1@)
  control_parent@(bx@, p2@)
  z = control_free(p2@)
  return 0
end function

test_case("order/the same with another control moved between")
q0@ = panel@(main@)
q1@ = panel@(main@)
q2@ = panel@(main@)
qy@ = panel@(main@)
s0@ = radiobutton@(q0@)
qx@ = radiobutton@(q0@)
s1@ = radiobutton@(q1@)
qz@ = radiobutton@(q0@)
qb@ = button@(q0@)
button_onclick@(qb@, "on_spacer")
button_click@(qb@)
assert_eq(sibling(s1@, qx@), 1, "x is in p1 either way")

function on_spacer(s@)
  control_parent@(qx@, q1@)
  control_parent@(qz@, qy@)
  control_parent@(qx@, q2@)
  z = control_free(q2@)
  return 0
end function

test_case("order/a move asked back to an earlier parent counts as the latest")
rem p1, p2, p1 again: the latest is p1. With p1 freed, the latest
rem still alive is p2 -- x->p1, x->p2 land, x->p1 does not.
u0@ = panel@(main@)
u1@ = panel@(main@)
u2@ = panel@(main@)
t0@ = radiobutton@(u0@)
ux@ = radiobutton@(u0@)
t2@ = radiobutton@(u2@)
ub@ = button@(u0@)
button_onclick@(ub@, "on_back")
button_click@(ub@)
assert_eq(sibling(t2@, ux@), 1, "x is in p2")

function on_back(s@)
  control_parent@(ux@, u1@)
  control_parent@(ux@, u2@)
  control_parent@(ux@, u1@)
  z = control_free(u1@)
  return 0
end function

test_case("order/a move asked after one that waits joins it, in order")
rem A click on a button of main checks k1, whose walk unchecks k2; k2's
rem onchange moves kx out of the walked panel, and that move waits. Back
rem in the click, kx is moved again, to kq: nothing walks kp's list any
rem more, but kx's first move has not landed, so this one waits behind
rem it, and the latest asked is where kx ends.
kp@ = panel@(main@)
ko@ = panel@(main@)
kq@ = panel@(main@)
k1@ = radiobutton@(kp@)
k2@ = radiobutton@(kp@)
kx@ = radiobutton@(kp@)
kqr@ = radiobutton@(kq@)
radio_checked@(k2@, 1)
radio_onchange@(k2@, "k2_moves")
kb@ = button@(main@)
button_onclick@(kb@, "k_click")
button_click@(kb@)
assert_eq(sibling(kqr@, kx@), 1, "kx is in kq, the latest asked")

function k2_moves(s@)
  control_parent@(kx@, ko@)
  return 0
end function

function k_click(s@)
  radio_checked@(k1@, 1)
  control_parent@(kx@, kq@)
  return 0
end function

rem --- which moves wait -------------------------------------------
test_case("land/a move out of a panel the sender is not in lands at once")
rem The button is on main; the radio leaves a panel of main's. No walk
rem of that panel can be under the click: the move lands now, and the
rem handler sees it landed.
v0@ = panel@(main@)
v1@ = panel@(main@)
w0@ = radiobutton@(v0@)
vx@ = radiobutton@(v0@)
w1@ = radiobutton@(v1@)
vb@ = button@(main@)
inside = -1
button_onclick@(vb@, "on_land")
button_click@(vb@)
assert_eq(inside, 1, "x was in p1 inside the handler")
assert_eq(sibling(w1@, vx@), 1, "and is after it")

function on_land(s@)
  control_parent@(vx@, v1@)
  inside = sibling(w1@, vx@)
  return 0
end function

test_case("land/a move out of the sender's own panel waits")
y0@ = panel@(main@)
y1@ = panel@(main@)
z0@ = radiobutton@(y0@)
yx@ = radiobutton@(y0@)
z1@ = radiobutton@(y1@)
yb@ = button@(y0@)
inside = -1
button_onclick@(yb@, "on_wait")
button_click@(yb@)
assert_eq(inside, 0, "x was still in p0 inside the handler")
assert_eq(sibling(z1@, yx@), 1, "and is in p1 after it")

function on_wait(s@)
  control_parent@(yx@, y1@)
  inside = sibling(z1@, yx@)
  return 0
end function

rem --- the tab order asked relative to the new parent ---------------
test_case("tab/a tab order set after a waiting move is kept")
rem gui-control.md, control_taborder@: the 0-based position in the
rem parent's tab chain. The program moves e into p2 (which holds a1,
rem a2) and makes it first: 0, inside the handler and after it. Round 8
rem wrote the 0 into the OLD parent's chain; the landing appended e to
rem p2's, and it read back 2.
tp1@ = panel@(main@)
tp2@ = panel@(main@)
a1@ = edit@(tp2@)
a2@ = edit@(tp2@)
te@ = edit@(tp1@)
tb@ = button@(tp1@)
button_onclick@(tb@, "on_tab")
button_click@(tb@)
assert_eq(inner_tab, 0, "e's tab order read inside the handler")
assert_eq(control_taborder(te@), 0, "and after the move landed")
assert_eq(control_taborder(a1@), 1, "a1 is second")

function on_tab(s@)
  control_parent@(te@, tp2@)
  control_taborder@(te@, 0)
  inner_tab = control_taborder(te@)
  return 0
end function

test_case("tab/a waiting move with no tab order set reads as the end of the chain")
rem TWinControl.Insert appends to the new parent's tab chain: p2 holds
rem two edits, so the moved one will be third, 2.
tq1@ = panel@(main@)
tq2@ = panel@(main@)
b1@ = edit@(tq2@)
b2@ = edit@(tq2@)
tf@ = edit@(tq1@)
tc@ = button@(tq1@)
button_onclick@(tc@, "on_tab_end")
button_click@(tc@)
assert_eq(inner_tab, 2, "read inside the handler")
assert_eq(control_taborder(tf@), 2, "and after it")

function on_tab_end(s@)
  control_parent@(tf@, tq2@)
  inner_tab = control_taborder(tf@)
  return 0
end function

rem --- a control moved into a dialog by the click that opens it -----
test_case("modal/a control moved into the dialog by its opener is in it while it is up")
rem The opener is a button of MAIN; the radio leaves a panel of main's
rem the button is not in, so the move lands before the dialog shows.
rem Round 8 held it until the dialog was answered.
dlg@ = form@("dialog", 300, 200)
dp@ = panel@(dlg@)
d1@ = radiobutton@(dp@)
mp@ = panel@(main@)
m1@ = radiobutton@(mp@)
m3@ = radiobutton@(mp@)
opener@ = button@(main@)
in_dialog = -1
button_onclick@(opener@, "open_options")
gui_test_modal("read_options")
button_click@(opener@)
assert_eq(ans, 1, "the dialog was answered")
assert_eq(in_dialog, 1, "the radio was in the dialog while it was up")

function open_options(s@)
  control_parent@(m3@, dp@)
  ans = form_showmodal(dlg@)
  return 0
end function

function read_options(f@)
  in_dialog = sibling(d1@, m3@)
  form_modalresult@(f@, 1)
  return 0
end function

rem --- the forms a free leaves without a host ------------------------
test_case("orphan/a form re-shown in the handler that freed its host is a window")
rem gui-control.md, control_free: the form is hidden at once, and
rem form_show@ makes it a window of its own again. Round 8 hid it and
rem left it INSIDE the dying host until the free, so form_show@ showed
rem it there, and the free then left it Visible with no window.
host@ = form@("host", 300, 200)
hp@ = panel@(host@)
inner@ = form@("inner", 100, 60)
control_parent@(inner@, hp@)
control_visible@(inner@, 1)
fb@ = button@(main@)
button_onclick@(fb@, "free_and_show")
button_click@(fb@)
assert_eq(inner_vis, 0, "hidden by the free, inside the handler")
assert_eq(form_visible(inner@), 1, "shown again by form_show@")
control_visible@(inner@, 0)
assert_eq(toplevel(inner@), 1, "and it is a form of its own, not inside the freed panel")
assert_eq(control_free(host@), 1, "the host form is alive")

function free_and_show(s@)
  x = control_free(hp@)
  inner_vis = form_visible(inner@)
  form_show@(inner@)
  return 0
end function

test_case("orphan/the same when the free is under a walk of the host's own list")
rem The clicked button is IN the panel freed, so the form's move out of
rem it waits; it is a top-level form in the program's view at once, and
rem lands as one -- not inside the panel -- when the click returns.
host2@ = form@("host2", 300, 200)
hp2@ = panel@(host2@)
inner2@ = form@("inner2", 100, 60)
control_parent@(inner2@, hp2@)
control_visible@(inner2@, 1)
fb2@ = button@(hp2@)
button_onclick@(fb2@, "free_and_show2")
button_click@(fb2@)
assert_eq(inner_vis, 0, "hidden by the free, inside the handler")
assert_eq(form_visible(inner2@), 1, "shown again by form_show@")
control_visible@(inner2@, 0)
assert_eq(toplevel(inner2@), 1, "and a form of its own once the click returned")
assert_eq(control_free(host2@), 1, "the host form is alive")

function free_and_show2(s@)
  x = control_free(hp2@)
  inner_vis = form_visible(inner2@)
  form_show@(inner2@)
  return 0
end function

test_case("orphan/a window whose waiting move goes into a host freed meanwhile stays a window")
rem The window's own button is clicked: moving the window waits (its
rem list may be under the click). The panel it was asked into is freed
rem before the move lands, so the move does not happen (gui-control.md)
rem and the window stays as it was -- shown. Round 8 judged it by the
rem parent asked, hid it as orphaned, and asked app_run nothing.
win@ = form@("win", 200, 100)
wbtn@ = button@(win@)
holder@ = form@("holder", 300, 200)
holdp@ = panel@(holder@)
control_visible@(win@, 1)
button_onclick@(wbtn@, "move_win_then_free")
button_click@(wbtn@)
assert_eq(inner_vis, 1, "visible inside the handler")
assert_eq(form_visible(win@), 1, "and after it: the move never happened")
control_visible@(win@, 0)
assert_eq(toplevel(win@), 1, "and it is still a form of its own")

function move_win_then_free(s@)
  control_parent@(win@, holdp@)
  x = control_free(holdp@)
  inner_vis = form_visible(win@)
  return 0
end function

test_case("orphan/a form moved into a host freed in the same handler, both landing at once")
rem The button is on main: the move lands at once, and the free then
rem leaves the form without a host -- hidden, and a form of its own.
win2@ = form@("win2", 200, 100)
holder2@ = form@("holder2", 300, 200)
holdp2@ = panel@(holder2@)
control_visible@(win2@, 1)
mb2@ = button@(main@)
button_onclick@(mb2@, "move_win2_then_free")
button_click@(mb2@)
assert_eq(form_visible(win2@), 0, "hidden")
assert_eq(toplevel(win2@), 1, "and a form of its own")

function move_win2_then_free(s@)
  control_parent@(win2@, holdp2@)
  x = control_free(holdp2@)
  return 0
end function

test_case("orphan/a form whose waiting move takes it out of the freed host lands there")
rem The button is in the panel, so the form's move out of it waits; the
rem panel is freed meanwhile. The move lands BEFORE the free (gui-control.md:
rem moves land first), so the form is not left without a host: it is in q@,
rem still shown.
host4@ = form@("host4", 300, 200)
p4@ = panel@(host4@)
q4@ = panel@(main@)
f4@ = form@("f4", 100, 60)
control_parent@(f4@, p4@)
control_visible@(f4@, 1)
b4@ = button@(p4@)
button_onclick@(b4@, "out_then_free")
button_click@(b4@)
assert_eq(form_visible(f4@), 1, "still shown")
control_visible@(f4@, 0)
assert_eq(parented(f4@), 1, "and placed inside another: q@")
assert_eq(control_free(host4@), 1, "the host form is alive")

function out_then_free(s@)
  control_parent@(f4@, q4@)
  x = control_free(p4@)
  return 0
end function

test_case("orphan/and when the parent it was going to is freed too, it is released at the free")
rem Same, and q@ is freed as well before anything lands: that move does
rem not happen, the form is still in the dying panel when the panel goes,
rem and the rule holds there -- hidden, and a form of its own (not left
rem Visible with no window by the LCL's destroy).
host5@ = form@("host5", 300, 200)
p5@ = panel@(host5@)
q5@ = panel@(main@)
f5@ = form@("f5", 100, 60)
control_parent@(f5@, p5@)
control_visible@(f5@, 1)
b5@ = button@(p5@)
button_onclick@(b5@, "out_then_free_both")
button_click@(b5@)
assert_eq(form_visible(f5@), 0, "hidden")
assert_eq(toplevel(f5@), 1, "and a form of its own")
assert_eq(control_free(host5@), 1, "the host form is alive")

function out_then_free_both(s@)
  control_parent@(f5@, q5@)
  x = control_free(p5@)
  x = control_free(q5@)
  return 0
end function

test_case("orphan/a form held by a panel its freed host owns, placed elsewhere")
rem A control dies with its OWNER, not with the window it sits in: hp6@
rem was made in host6@ and moved into main. Freeing host6@ frees hp6@, and
rem the form inside hp6@ is left without a host -- found by walking what
rem host6@ owns, not what it holds on screen.
host6@ = form@("host6", 300, 200)
hp6@ = panel@(host6@)
control_parent@(hp6@, main@)
f6@ = form@("f6", 100, 60)
control_parent@(f6@, hp6@)
control_visible@(f6@, 1)
assert_eq(control_free(host6@), 1, "the host was freed")
assert_eq(form_visible(f6@), 0, "the form in the panel it owned is hidden")
assert_eq(toplevel(f6@), 1, "and a form of its own")

end
