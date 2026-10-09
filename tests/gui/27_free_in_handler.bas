rem ---------------------------------------------------------------
rem FREEING WHAT AN EVENT IS STANDING ON, FROM INSIDE THE EVENT.
rem
rem A handler may free its own control, the form that owns it, or any
rem other control -- and the LCL is usually NOT finished with them when
rem the handler returns. TButtonControl.Click is DoOnChange and THEN
rem `inherited Click` on the same object; TCustomCheckBox.SetState goes
rem on reading its own fields after the change event; a list box's Click
rem calls Changed on itself. Until 2026-10-09 (round 3) control_free
rem destroyed the object at once, the LCL walked on into freed memory,
rem and the release heap -- which leaves a freed block's bytes alone --
rem made that a silent pass: checkbox_checked@, radio_checked@,
rem togglebox_checked@, edit_text@, spinedit_value@,
rem radiogroup_itemindex@ and a list's click all "survived". Only a
rem heap that poisons freed memory showed the access violation, and
rem phosphorguitest is now such a heap.
rem
rem THE RULE NOW: a free asked for while ANY handler is running takes
rem effect for the program at once -- the handle is dead, and so is
rem every handle into what dies with it -- and for the memory when the
rem dispatch has unwound. docs/libraries/gui-control.md says so.
rem
rem Every case is one event kind crossed with one victim: 1 the control
rem the event belongs to, 2 the form that owns it, 3 another control on
rem the same form. Each asserts that nothing raised, that the handler
rem ran, that the free answered 1 (it was granted, not refused), that
rem the handle was dead INSIDE the handler, and that it is still dead
rem after -- then that what was not freed is still alive.
rem The expected values are the documented contract of control_free
rem (gui-control.md): 1 for a free, 0 with gui_error() 1 for a handle
rem already freed. None of them was read off a run.
rem
rem The form-close events are not here: a free of the CLOSING form is
rem refused (18_faults pins that); case "close" frees a third control.
rem ---------------------------------------------------------------

raised = 0
ran = 0
mode = 0
freeans = -1
again = -1
childagain = -1
onform = 0

function run_case(kind$, m) local c@, label$
  raised = 0
  ran = 0
  freeans = -1
  again = -1
  childagain = -1
  mode = m
  onform = 1
  cf@ = form@("victim " + kind$, 300, 200)
  co@ = button@(cf@)
  c@ = make@(kind$, cf@)
  bindit(kind$, c@)
  gui_clearerror()
  on error goto trapped
  fireit(kind$, c@)
  on error goto 0
  label$ = kind$ + "/" + str$(m)
  assert_eq(raised, 0, label$ + ": nothing raised")
  assert_eq(ran, 1, label$ + ": the handler ran once")
  assert_eq(freeans, 1, label$ + ": the free inside the handler was granted")
  assert_eq(again, 0, label$ + ": and the handle was dead inside the handler")
  if mode = 2 and onform = 1 then
    assert_eq(childagain, 0, label$ + ": and so was the sender, which the form owned")
  endif
  rem After the event: what was freed stays freed, and what was not
  rem is still there to free.
  gui_clearerror()
  if mode = 1 then
    assert_eq(control_free(c@), 0, label$ + ": the freed sender stays freed")
    assert_eq(gui_error(), 1, label$ + ": and says so")
    assert_eq(control_free(co@), 1, label$ + ": the other control is alive")
    assert_eq(control_free(cf@), 1, label$ + ": and so is the form")
  endif
  if mode = 2 then
    assert_eq(control_free(cf@), 0, label$ + ": the freed form stays freed")
    assert_eq(gui_error(), 1, label$ + ": and says so")
    gui_clearerror()
    assert_eq(control_free(co@), 0, label$ + ": its other child died with it")
    if onform = 0 then
      assert_eq(control_free(c@), 1, label$ + ": a sender it did not own is alive")
    endif
  endif
  if mode = 3 then
    assert_eq(control_free(co@), 0, label$ + ": the other control stays freed")
    assert_eq(gui_error(), 1, label$ + ": and says so")
    assert_eq(control_free(c@), 1, label$ + ": the sender is alive")
    rem A close event's sender IS the form, freed on the line above.
    if kind$ <> "close" then
      assert_eq(control_free(cf@), 1, label$ + ": and so is the form")
    endif
  endif
  return 0
endfunction

function make@(kind$, f@) local g@, x
  if kind$ = "button" or kind$ = "keydown" or kind$ = "keyup" or kind$ = "keypress" then
    return button@(f@)
  endif
  if kind$ = "mousedown" or kind$ = "mouseup" or kind$ = "mousemove" or kind$ = "mousewheel" then
    return button@(f@)
  endif
  if kind$ = "bitbtn" then
    return bitbtn@(f@)
  endif
  if kind$ = "speedbutton" then
    return speedbutton@(f@)
  endif
  if kind$ = "menuitem" then
    return menuitem@(mainmenu@(f@), "item")
  endif
  if kind$ = "checkbox" then
    return checkbox@(f@)
  endif
  if kind$ = "radio" then
    return radiobutton@(f@)
  endif
  if kind$ = "togglebox" then
    return togglebox@(f@)
  endif
  if kind$ = "radiogroup" then
    g@ = radiogroup@(f@)
    g@ = radiogroup_add@(g@, "one")
    return radiogroup_add@(g@, "two")
  endif
  if kind$ = "combo" then
    g@ = combobox@(f@)
    return combo_add@(g@, "one")
  endif
  if kind$ = "list" then
    g@ = listbox@(f@)
    return list_add@(g@, "one")
  endif
  if kind$ = "tabcontrol" then
    g@ = tabcontrol@(f@)
    return tabcontrol_add@(g@, "one")
  endif
  if kind$ = "edit" then
    return edit@(f@)
  endif
  if kind$ = "memo" then
    g@ = memo@(f@)
    f@ = form_show@(f@)
    x = app_processmessages()
    return g@
  endif
  if kind$ = "spinedit" then
    return spinedit@(f@)
  endif
  if kind$ = "trackbar" then
    return trackbar@(f@)
  endif
  if kind$ = "paintbox" then
    return paintbox@(f@)
  endif
  if kind$ = "drawgrid" then
    return drawgrid@(f@)
  endif
  if kind$ = "trayicon" then
    onform = 0
    return trayicon@()
  endif
  if kind$ = "timer" then
    onform = 0
    return timer@()
  endif
  if kind$ = "close" then
    return f@
  endif
  return 0
endfunction

function bindit(kind$, c@) local x@
  if kind$ = "button" then
    x@ = button_onclick@(c@, "h_notify")
  endif
  if kind$ = "bitbtn" then
    x@ = bitbtn_onclick@(c@, "h_notify")
  endif
  if kind$ = "speedbutton" then
    x@ = speedbutton_onclick@(c@, "h_notify")
  endif
  if kind$ = "menuitem" then
    x@ = menuitem_onclick@(c@, "h_notify")
  endif
  if kind$ = "checkbox" then
    x@ = checkbox_onchange@(c@, "h_notify")
  endif
  if kind$ = "radio" then
    x@ = radio_onchange@(c@, "h_notify")
  endif
  if kind$ = "togglebox" then
    x@ = togglebox_onchange@(c@, "h_notify")
  endif
  if kind$ = "radiogroup" then
    x@ = radiogroup_onchange@(c@, "h_notify")
  endif
  if kind$ = "combo" then
    x@ = combo_onchange@(c@, "h_notify")
  endif
  if kind$ = "list" then
    x@ = list_onclick@(c@, "h_notify")
  endif
  if kind$ = "tabcontrol" then
    x@ = tabcontrol_onchange@(c@, "h_notify")
  endif
  if kind$ = "edit" then
    x@ = edit_onchange@(c@, "h_notify")
  endif
  if kind$ = "memo" then
    x@ = memo_onchange@(c@, "h_notify")
  endif
  if kind$ = "spinedit" then
    x@ = spinedit_onchange@(c@, "h_notify")
  endif
  if kind$ = "trackbar" then
    x@ = trackbar_onchange@(c@, "h_notify")
  endif
  if kind$ = "paintbox" then
    x@ = paintbox_onpaint@(c@, "h_notify")
  endif
  if kind$ = "drawgrid" then
    x@ = drawgrid_ondrawcell@(c@, "h_cell")
  endif
  if kind$ = "trayicon" then
    x@ = trayicon_onclick@(c@, "h_notify")
  endif
  if kind$ = "timer" then
    x@ = timer_interval@(c@, 10)
    x@ = timer_ontimer@(c@, "h_notify")
  endif
  if kind$ = "close" then
    x@ = form_onclose@(c@, "h_notify")
  endif
  if kind$ = "keydown" then
    x@ = control_onkeydown@(c@, "h_key")
  endif
  if kind$ = "keyup" then
    x@ = control_onkeyup@(c@, "h_key")
  endif
  if kind$ = "keypress" then
    x@ = control_onkeypress@(c@, "h_press")
  endif
  if kind$ = "mousedown" then
    x@ = control_onmousedown@(c@, "h_mouse")
  endif
  if kind$ = "mouseup" then
    x@ = control_onmouseup@(c@, "h_mouse")
  endif
  if kind$ = "mousemove" then
    x@ = control_onmousemove@(c@, "h_move")
  endif
  if kind$ = "mousewheel" then
    x@ = control_onmousewheel@(c@, "h_wheel")
  endif
  return 0
endfunction

function fireit(kind$, c@) local x@, x, t0
  if kind$ = "button" then
    x@ = button_click@(c@)
  endif
  if kind$ = "bitbtn" then
    x@ = bitbtn_click@(c@)
  endif
  if kind$ = "speedbutton" then
    x@ = speedbutton_click@(c@)
  endif
  if kind$ = "menuitem" then
    x@ = menuitem_click@(c@)
  endif
  if kind$ = "checkbox" then
    x@ = checkbox_checked@(c@, 1)
  endif
  if kind$ = "radio" then
    x@ = radio_checked@(c@, 1)
  endif
  if kind$ = "togglebox" then
    x@ = togglebox_checked@(c@, 1)
  endif
  if kind$ = "radiogroup" then
    x@ = radiogroup_itemindex@(c@, 2)
  endif
  if kind$ = "combo" or kind$ = "tabcontrol" then
    x = gui_test_fire(c@, "change")
  endif
  if kind$ = "list" or kind$ = "trayicon" then
    x = gui_test_fire(c@, "click")
  endif
  if kind$ = "edit" then
    x@ = edit_text@(c@, "typed")
  endif
  if kind$ = "memo" then
    x@ = memo_text@(c@, "typed")
  endif
  if kind$ = "spinedit" then
    x@ = spinedit_value@(c@, 5)
  endif
  if kind$ = "trackbar" then
    x@ = trackbar_position@(c@, 3)
  endif
  if kind$ = "paintbox" then
    x = gui_test_fire(c@, "paint")
  endif
  if kind$ = "drawgrid" then
    x@ = drawgrid_drawcell@(c@, 1, 1)
  endif
  if kind$ = "timer" then
    rem The tick arrives through the message queue: pump it, bounded by
    rem the clock, until the handler has run.
    x@ = timer_start@(c@)
    t0 = now()
    while ran = 0 and millisecondsbetween(now(), t0) < 5000
      x = app_processmessages()
    wend
  endif
  if kind$ = "close" then
    x@ = form_close@(c@)
  endif
  if kind$ = "keydown" then
    x@ = control_keydown@(c@, 65, "")
  endif
  if kind$ = "keyup" then
    x@ = control_keyup@(c@, 65, "")
  endif
  if kind$ = "keypress" then
    x@ = control_keypress@(c@, "a")
  endif
  if kind$ = "mousedown" then
    x@ = control_mousedown@(c@, 0, 1, 1, "")
  endif
  if kind$ = "mouseup" then
    x@ = control_mouseup@(c@, 0, 1, 1, "")
  endif
  if kind$ = "mousemove" then
    x@ = control_mousemove@(c@, 2, 2, "")
  endif
  if kind$ = "mousewheel" then
    x = control_mousewheel(c@, 120, 1, 1, "")
  endif
  return 0
endfunction

test_case("freeinhandler/the control the event belongs to")
run_case("button", 1)
run_case("bitbtn", 1)
run_case("speedbutton", 1)
run_case("menuitem", 1)
run_case("checkbox", 1)
run_case("radio", 1)
run_case("togglebox", 1)
run_case("radiogroup", 1)
run_case("combo", 1)
run_case("list", 1)
run_case("tabcontrol", 1)
run_case("edit", 1)
run_case("memo", 1)
run_case("spinedit", 1)
run_case("trackbar", 1)
run_case("paintbox", 1)
run_case("drawgrid", 1)
run_case("trayicon", 1)
run_case("timer", 1)
run_case("keydown", 1)
run_case("keyup", 1)
run_case("keypress", 1)
run_case("mousedown", 1)
run_case("mouseup", 1)
run_case("mousemove", 1)
run_case("mousewheel", 1)

test_case("freeinhandler/the form that owns it")
run_case("button", 2)
run_case("bitbtn", 2)
run_case("speedbutton", 2)
run_case("menuitem", 2)
run_case("checkbox", 2)
run_case("radio", 2)
run_case("togglebox", 2)
run_case("radiogroup", 2)
run_case("combo", 2)
run_case("list", 2)
run_case("tabcontrol", 2)
run_case("edit", 2)
run_case("memo", 2)
run_case("spinedit", 2)
run_case("trackbar", 2)
run_case("paintbox", 2)
run_case("drawgrid", 2)
run_case("trayicon", 2)
run_case("timer", 2)
run_case("keydown", 2)
run_case("keyup", 2)
run_case("keypress", 2)
run_case("mousedown", 2)
run_case("mouseup", 2)
run_case("mousemove", 2)
run_case("mousewheel", 2)

test_case("freeinhandler/another control on the same form")
run_case("button", 3)
run_case("bitbtn", 3)
run_case("speedbutton", 3)
run_case("menuitem", 3)
run_case("checkbox", 3)
run_case("radio", 3)
run_case("togglebox", 3)
run_case("radiogroup", 3)
run_case("combo", 3)
run_case("list", 3)
run_case("tabcontrol", 3)
run_case("edit", 3)
run_case("memo", 3)
run_case("spinedit", 3)
run_case("trackbar", 3)
run_case("paintbox", 3)
run_case("drawgrid", 3)
run_case("trayicon", 3)
run_case("timer", 3)
run_case("close", 3)
run_case("keydown", 3)
run_case("keyup", 3)
run_case("keypress", 3)
run_case("mousedown", 3)
run_case("mouseup", 3)
run_case("mousemove", 3)
run_case("mousewheel", 3)

test_case("freeinhandler/a radio group cannot be emptied from inside its own change")
rem The change is raised from inside one of the group's radio buttons,
rem and clearing the items frees every button at once -- the one the
rem LCL is standing on included. That cannot be deferred (the list must
rem read empty the moment it is cleared), so it is refused: gui_error 1
rem and the items unchanged, the answer a closing form's free gets. The
rem window is shown because only then does the group raise the change
rem from a real button (with no handle the LCL sets the index directly).
rf@ = form@("radio clear", 300, 200)
rg@ = radiogroup@(rf@)
x@ = radiogroup_add@(rg@, "one")
x@ = radiogroup_add@(rg@, "two")
x@ = radiogroup_onchange@(rg@, "h_clear")
rf@ = form_show@(rf@)
x = app_processmessages()
raised = 0
ran = 0
clearerr = -1
countinside = -1
on error goto trapped
x@ = radiogroup_itemindex@(rg@, 2)
on error goto 0
assert_eq(raised, 0, "selecting an item did not raise")
assert_eq(ran, 1, "the change handler ran once")
assert_eq(clearerr, 1, "the clear was refused with gui_error 1")
assert_eq(countinside, 2, "and left both items in place")
assert_eq(radiogroup_count(rg@), 2, "they are still there after the event")
assert_eq(radiogroup_itemindex(rg@), 2, "and the second is the one chosen")
gui_clearerror()
x@ = radiogroup_clear@(rg@)
assert_eq(gui_error(), 0, "outside the event the same clear is granted")
assert_eq(radiogroup_count(rg@), 0, "and empties the group")
assert_eq(control_free(rf@), 1, "the form is freed")

end

trapped:
raised = 1
resume next

rem The one body every handler shape runs. A timer is stopped first, so
rem a victim other than the timer does not leave it ticking into the
rem next case.
function victim(sender@) local x@
  ran = ran + 1
  if timer_enabled(sender@) = 1 then
    x@ = timer_stop@(sender@)
  endif
  gui_clearerror()
  if mode = 1 then
    freeans = control_free(sender@)
    again = control_free(sender@)
  endif
  if mode = 2 then
    freeans = control_free(cf@)
    again = control_free(cf@)
    if onform = 1 then
      childagain = control_free(sender@)
    endif
  endif
  if mode = 3 then
    freeans = control_free(co@)
    again = control_free(co@)
  endif
  gui_clearerror()
  return 0
endfunction

function h_clear(sender@) local x@
  ran = ran + 1
  gui_clearerror()
  x@ = radiogroup_clear@(sender@)
  clearerr = gui_error()
  countinside = radiogroup_count(sender@)
  gui_clearerror()
  return 0
endfunction

function h_notify(sender@)
  victim(sender@)
  return 0
endfunction

function h_key(sender@, key, mods$)
  victim(sender@)
  return 0
endfunction

function h_press(sender@, ch$)
  victim(sender@)
  return 0
endfunction

function h_mouse(sender@, btn, x, y, mods$)
  victim(sender@)
  return 0
endfunction

function h_move(sender@, x, y, mods$)
  victim(sender@)
  return 0
endfunction

function h_wheel(sender@, delta, x, y, mods$)
  victim(sender@)
  return 0
endfunction

function h_cell(sender@, col, row, x, y, w, h, state$)
  victim(sender@)
  return 0
endfunction
