rem ---------------------------------------------------------------
rem The other seven LCL event signatures.
rem
rem docs/gui-components.md named eight signatures, each to get a
rem TGuiEventBridge variant. Increment 3 built the TNotifyEvent one and
rem nothing was added for four rounds, so a program could not bind a key
rem press, a mouse click with coordinates, a wheel, or a form close --
rem the two handler shapes the page showed described an interface that
rem did not exist.
rem
rem All eight exist now. Events are synthesised the way button_click
rem already synthesised a click (control_keydown@, control_mousedown@,
rem ...), so the whole surface is reachable headless, with no window
rem manager and no message loop.
rem
rem Two of the signatures carry a var parameter whose purpose is to let
rem the handler decide, and those read the handler's ANSWER back. Only an
rem explicit boolean counts: a handler that returns a number, or falls
rem off its end, leaves the default alone. That asymmetry is deliberate
rem and is pinned below -- a forgotten return must not be able to make a
rem window impossible to close.
rem ---------------------------------------------------------------

keys = 0
lastkey = 0
lastmods$ = ""
presses = 0
lastchar$ = ""
mousehits = 0
lastbtn = 0
lastx = 0
lasty = 0
moves = 0
wheels = 0
lastdelta = 0
closes = 0
queries = 0
vetoing? = false

f@ = form@("events", 300, 200)
b@ = button@(f@)

test_case("events/a key reaches its handler with code and modifiers")
control_onkeydown@(b@, "on_key")
assert_eq(gui_error(), 0, "binding a key event records no error")
control_keydown@(b@, 65, "")
assert_eq(keys, 1, "the handler ran")
assert_eq(lastkey, 65, "and was handed the key code")
assert_eq(lastmods$, "", "with no modifiers")

control_keydown@(b@, 66, "S C A")
assert_eq(keys, 2, "again")
assert_eq(lastkey, 66, "the second code")
assert_eq(lastmods$, "S C A", "and all three modifiers, in the documented order")

control_keydown@(b@, 67, "C")
assert_eq(lastmods$, "C", "one modifier alone")

test_case("events/keyup is the same signature on a different event")
control_onkeyup@(b@, "on_key")
control_keyup@(b@, 90, "S")
assert_eq(keys, 4, "keyup ran the same handler")
assert_eq(lastkey, 90, "with its own code")
assert_eq(lastmods$, "S", "and its own modifiers")

test_case("events/a key PRESS carries the character, not the code")
control_onkeypress@(b@, "on_press")
control_keypress@(b@, "x")
assert_eq(presses, 1, "the press handler ran")
assert_eq(lastchar$, "x", "and was handed the character")

test_case("events/a mouse click carries button, position and modifiers")
control_onmousedown@(b@, "on_mouse")
control_mousedown@(b@, 0, 12, 34, "")
assert_eq(mousehits, 1, "the handler ran")
assert_eq(lastbtn, 0, "left is 0")
assert_eq(lastx, 12, "the x it was clicked at")
assert_eq(lasty, 34, "and the y")

control_mousedown@(b@, 1, 5, 6, "S")
assert_eq(lastbtn, 1, "right is 1")
control_mousedown@(b@, 2, 7, 8, "")
assert_eq(lastbtn, 2, "middle is 2")
assert_eq(lastx, 7, "and the position follows")

test_case("events/mouseup binds separately from mousedown")
control_onmouseup@(b@, "on_mouse")
control_mouseup@(b@, 0, 99, 98, "")
assert_eq(mousehits, 4, "the up event ran it too")
assert_eq(lastx, 99, "with the up position")

test_case("events/a move carries position without a button")
control_onmousemove@(b@, "on_move")
control_mousemove@(b@, 40, 50, "A")
assert_eq(moves, 1, "the move handler ran")
assert_eq(lastx, 40, "x")
assert_eq(lasty, 50, "y")
assert_eq(lastmods$, "A", "and the modifier")

test_case("events/the wheel reports whether the handler consumed it")
control_onmousewheel@(b@, "on_wheel_ignore")
consumed = control_mousewheel(b@, 120, 10, 10, "")
assert_eq(wheels, 1, "the wheel handler ran")
assert_eq(lastdelta, 120, "with the delta")
assert_eq(consumed, 0, "a handler that answers nothing does not consume the wheel")

rem the handler answers a bool, so its name carries the "?" -- and the name
rem it is BOUND by carries it too, because the suffix is part of the name
control_onmousewheel@(b@, "on_wheel_consume?")
consumed2 = control_mousewheel(b@, -120, 10, 10, "")
assert_eq(lastdelta, -120, "a negative delta is the other direction")
assert_eq(consumed2, 1, "answering true consumes it")

test_case("events/an empty name unwires any of them")
control_onkeydown@(b@, "")
keys = 0
control_keydown@(b@, 65, "")
assert_eq(keys, 0, "the key event is unwired")
control_onmousedown@(b@, "")
mousehits = 0
control_mousedown@(b@, 0, 1, 1, "")
assert_eq(mousehits, 0, "and so is the mouse event")

test_case("events/closequery can veto, and only an explicit false does")
form_onclosequery@(f@, "on_query?")
form_onclose@(f@, "on_close")
form_show@(f@)
assert_eq(form_visible(f@), 1, "the form is up")

vetoing? = true
form_close@(f@)
assert_eq(queries, 1, "the query handler ran")
assert_eq(closes, 0, "and the close did NOT happen")
assert_eq(form_visible(f@), 1, "the form is still up")

vetoing? = false
form_close@(f@)
assert_eq(queries, 2, "the query ran again")
assert_eq(closes, 1, "and this time the close happened")

test_case("events/a wrong-class handle is rejected by the new binders too")
gui_clearerror()
control_onkeydown@(f@, "on_key")
assert_eq(gui_error(), 0, "a form IS a TWinControl, so this is legal")
gui_clearerror()
form_onclosequery@(b@, "on_query?")
assert_true(gui_error(), "but a button is not a form")

function on_key(sender@, key%, mods$)
  keys = keys + 1
  lastkey = key%
  lastmods$ = mods$
  return 0
endfunction

function on_press(sender@, ch$)
  presses = presses + 1
  lastchar$ = ch$
  return 0
endfunction

function on_mouse(sender@, button%, x%, y%, mods$)
  mousehits = mousehits + 1
  lastbtn = button%
  lastx = x%
  lasty = y%
  return 0
endfunction

function on_move(sender@, x%, y%, mods$)
  moves = moves + 1
  lastx = x%
  lasty = y%
  lastmods$ = mods$
  return 0
endfunction

rem answers a NUMBER, which must not be mistaken for a decision
function on_wheel_ignore(sender@, delta%, x%, y%, mods$)
  wheels = wheels + 1
  lastdelta = delta%
  return 0
endfunction

function on_wheel_consume?(sender@, delta%, x%, y%, mods$)
  wheels = wheels + 1
  lastdelta = delta%
  return true
endfunction

function on_close(sender@)
  closes = closes + 1
  return 0
endfunction

function on_query?(sender@)
  queries = queries + 1
  return not vetoing?
endfunction
